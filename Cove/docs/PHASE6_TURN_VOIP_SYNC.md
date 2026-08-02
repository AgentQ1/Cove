# Inditalk — Phase 6: TURN, background ringing, and live receipt/reaction sync

**Status:** Implemented (client + Cloud Functions); provisioning is operator work —
see [`PHASE6_OPERATOR_SETUP.md`](../PHASE6_OPERATOR_SETUP.md) for the exact commands and
what is still blocked on credentials.
**Last updated:** 2026-07-26

Closes the four gaps that made calling and chat state work in a demo but not in the
real world:

| Gap | Symptom before | Fix |
|---|---|---|
| STUN-only ICE | Calls connected on Wi-Fi, stalled on carrier/symmetric NAT | `getTurnCredentials` callable + `ICEServerConfig.refreshIfNeeded()` |
| Foreground-only ring | Callee rang only with the app open; locked phone stayed silent | `onCallInvite` APNs VoIP push + PushKit → CallKit |
| Receipts written, never read | Ticks never became "read" | `chats/{chatId}/receipts` listener → `DataStore.markOutgoingRead` |
| Local-only reactions | A reaction was invisible to everyone else | `chats/{chatId}/reactions` subcollection + listener |

…and four defects found while hardening it, each of which failed silently:

| Defect | Symptom | Fix |
|---|---|---|
| Push tokens on the world-readable profile, one per user | Any account could enumerate a user's devices; a second device never rang | `users/{uid}/privateDevices/{deviceId}`, owner-only, one per install |
| One global `APNS_USE_SANDBOX` | Debug and TestFlight could not both ring; the mismatched one got `BadDeviceToken` | `apnsEnvironment` recorded per device, host chosen per push |
| Block list never published | A blocked caller still rang a locked phone (the server-side check read a collection nothing wrote) | `DataStore.blockSink` → `users/{uid}/blocked/{peerUid}` + backfill |
| Sign-out left tokens behind | Calls kept waking a phone nobody was signed in on | device document deleted before `Auth.signOut()` |

---

## 1. TURN

### Flow

```
sign-in ─▶ FirebaseSyncCoordinator.start
             └─ ICEServerConfig.credentialProvider = TurnCredentialsService.fetch
             └─ refreshIfNeeded()          ← warms the grant off the critical path

place/answer call ─▶ WebRTCMediaSession.buildPeerConnection()
                       └─ await ICEServerConfig.refreshIfNeeded()   ← cache hit, ~0ms
                       └─ RTCConfiguration.iceServers = [STUN] + [TURN…]
```

`refreshIfNeeded()` is awaited **before** `RTCPeerConnection` is constructed, because
WebRTC snapshots `iceServers` at construction — a relay installed a moment later is
never used by that call.

### Credential scheme

The standard TURN REST API (`draft-uberti-behave-turn-rest-00`), which coturn implements
as `use-auth-secret`:

```
username   = "<unix-expiry>:<firebase uid>"
credential = base64(HMAC-SHA1(static-auth-secret, username))
```

The relay recomputes the HMAC from its own copy of the secret — no credential database,
no callback to us at connect time. The secret never leaves Secret Manager.

### Configuration

```bash
# functions/.env  (copy from functions/.env.sample — gitignored)
TURN_URLS=turn:turn.example.net:3478?transport=udp,turn:turn.example.net:3478?transport=tcp,turns:turn.example.net:5349?transport=tcp
TURN_TTL_SECONDS=3600

firebase functions:secrets:set TURN_SECRET --project cove-7f31f
firebase deploy --project cove-7f31f --only functions:getTurnCredentials
```

Offer UDP **and** TCP, plus `turns:` on 5349 — TLS on a common port is what gets through
networks that only permit HTTPS-shaped traffic, and those are exactly the networks that
need a relay.

### Fallback behaviour (deliberate)

| Situation | Result |
|---|---|
| `TURN_URLS`/`TURN_SECRET` unset | Function returns `iceServers: []`; client stays on STUN and re-asks at most every 10 min |
| Function errors / device offline | Logged, STUN-only, retried on the next call |
| Grant expires mid-session | Dropped 60s early and re-minted on the next call |

A missing relay degrades reachability. It never fails a call that STUN could have
carried.

### Verification

- **Unit — server:** `npm --prefix functions test` → `functions/test/turn.test.js`
  recomputes the HMAC independently, and pins TTL clamping (60s … 12h) and URL parsing.
- **Unit — client:** `TurnCredentialsTests` covers response parsing (absolute expiry
  beats TTL, bare-string `urls`, incomplete entries dropped), expiry/skew handling,
  refresh coalescing, and that a failing or unconfigured backend leaves exactly one
  (STUN) server installed.
- **Manual, on device:** place a call with the callee on cellular and the caller on
  Wi‑Fi with a restrictive NAT. Console shows
  `[Inditalk call] TURN configured: N relay URL(s)` then
  `[Inditalk call] building peer connection for … (STUN + TURN)`. Confirm relay use in the
  TURN server's own log (coturn: `allocation` lines for the minted username), or check
  the selected candidate pair type is `relay` via `RTCPeerConnection.statistics`.
- **Negative:** unset `TURN_URLS`, redeploy, place a call → log reads
  `backend reports no TURN relay configured — STUN only` and the call still connects on
  a permissive network.

---

## 2. Background incoming calls (VoIP push + CallKit)

### Flow

```
caller: CallCenter.placeCall
          └─ upsertCallDoc(state:"ringing")  ──▶ Firestore
                                                   │  onDocumentCreated
                                                   ▼
                                            onCallInvite (functions/voip.js)
                                              ├─ blocked?  → no push
                                              ├─ users/{to}/privateDevices/*  (every device)
                                              └─ APNs HTTP/2, topic <bundle>.voip
                                                 to each device's own environment
                                                   │
callee (backgrounded / locked / not running) ◀─────┘
  PKPushRegistry.didReceiveIncomingPush
    └─ VoIPCallPayload(...)                              (synchronous — see below)
    └─ CallCenter.receiveIncomingFromPush
         ├─ FirestoreSignalingService.connect   ← offer/ICE now flow as usual
         ├─ WebRTCMediaSession (offer buffered until accept)
         └─ CallManager.reportIncoming → CallKit rings
```

Answering and declining go through the **existing** paths, not a parallel one:

- **Answer** → `CXAnswerCallAction` → `WebRTCMediaSession.accept()` → the buffered SDP
  offer is answered over Firestore → ICE → `.connected`.
- **Decline** → `CXEndCallAction` → `CallCenter.systemEnded()` →
  `media.end(kind: .decline)` (signaled to the caller) + call doc marked `ended`.

### Two rules that will terminate the app if broken

1. **Every VoIP push must produce a `reportNewIncomingCall` before the delegate
   returns.** The handler therefore runs under `MainActor.assumeIsolated` (PushKit
   delivers on the main queue) rather than hopping through a `Task`, which would return
   first and report a turn later. Every refusal path — busy, blocked, signed out,
   malformed payload — goes through `reportIncomingThenEnd`, which reports and then
   immediately retires the call.
2. **The push's `completion` must be called.** Every branch invokes it.

### Token lifecycle

PushKit issues the VoIP token at launch, usually *before* sign-in, so `PushService`
caches it and publishes it once a uid exists (`setVoIPToken`, and again from `InditalkApp`
via `publishAllTokens()` after sign-in).

Tokens live at **`users/{uid}/privateDevices/{deviceId}`**, not on the profile:

```
users/{uid}/privateDevices/{deviceId}
  voipToken?  fcmToken?  apnsEnvironment  platform  bundleId  updatedAt
```

Three reasons, each of which was a real defect while they sat on `users/{uid}`:

1. **Privacy.** `users/{uid}` is readable by every signed-in user (contact discovery). A
   push token isn't a credential — sending needs Inditalk's APNs key — but it *is* a stable
   per-install identifier, so any account could enumerate another user's devices. The
   subcollection is owner-only; Cloud Functions read it with the Admin SDK, which
   bypasses rules.
2. **Multi-device.** One field per user meant the second device to sign in overwrote the
   first, and only one phone ever rang. One document per install fans out to all of them.
3. **APNs environment.** Each device records the `aps-environment` from its own embedded
   provisioning profile, and `onCallInvite` pushes it to the matching host. A single
   global `APNS_USE_SANDBOX` made Debug and TestFlight mutually exclusive: whichever
   didn't match the flag got `BadDeviceToken` and silently stopped ringing. The flag
   survives only as the fallback for tokens registered before this field existed.

The first publish from an updated app also deletes the legacy profile fields, so the
migration happens on sign-in with no backfill job; `loadPushTargets` reads the profile
only when a user has no device documents at all.

Sign-out (`AppSession.tearDownSession`, which deletes the device document *before*
`Auth.signOut()` — afterwards the rules reject the write) and account deletion remove it;
`onCallInvite` prunes it when APNs reports `BadDeviceToken` / `Unregistered` /
`DeviceTokenNotForTopic`.

### Blocked callers

`onCallInvite` checks `users/{to}/blocked/{from}` before pushing, and that check is the
*only* block enforcement that exists when the callee's app is backgrounded or not running
— the in-app check needs a live sync coordinator, which a push-launched app has not
started. That list is now actually written: `DataStore.blockSink` →
`FirestoreService.setBlocked`, plus a one-way backfill at sync start for blocks made
before publication existed. Until that was wired, blocking was silently unenforced for
exactly the case it matters most.

### Configuration

```bash
# functions/.env
APNS_KEY_ID=ABCDE12345
APNS_TEAM_ID=1234567890
APNS_BUNDLE_ID=chat.cove.app
APNS_USE_SANDBOX=true          # false for TestFlight/App Store builds

firebase functions:secrets:set APNS_AUTH_KEY --project cove-7f31f < AuthKey_ABCDE12345.p8
firebase deploy --project cove-7f31f --only functions:onCallInvite
```

`APNS_USE_SANDBOX` **must** match the build's `aps-environment` entitlement
(`Inditalk.entitlements` = development, `Inditalk.Release.entitlements` = production). A
mismatch returns `BadDeviceToken` and the callee simply never rings — with no client-side
symptom at all. `Info.plist` already declares the `voip` background mode; CallKit and
PushKit need no additional entitlement key beyond Push Notifications.

### Why raw APNs rather than FCM

FCM cannot address a PushKit token: VoIP pushes require the `<bundle-id>.voip` topic and
the `apns-push-type: voip` header. `functions/voip.js` therefore speaks APNs' HTTP/2 API
directly with an ES256 provider token.

### Verification

- **Unit — server:** `functions/test/voip.test.js` verifies the JWT header/claims, that
  the signature is 64-byte raw R‖S (Node's default DER encoding is rejected by APNs) and
  verifiable against the key's public half, URL-safe encoding, and the dead-token set.
- **Unit — client:** `VoIPPushPayloadTests` pins the payload contract, including
  NSNumber-bridged booleans and rejection of a `callId` that isn't a UUID (Inditalk uses one
  id for both the signaling doc and the CallKit call, so a non-UUID call could never be
  answered or ended).
- **Manual, on device** (VoIP pushes are not delivered to the Simulator):
  1. Sign in on device B, confirm `users/{uid}/privateDevices/{deviceId}` appears in
     Firestore with a `voipToken` and the `apnsEnvironment` matching that build.
  2. Background the app, lock the phone.
  3. Call from device A → B's lock screen rings with the caller's name.
  4. Answer → audio both ways; check `Console.app` for
     `[Inditalk call] VoIP push for … call` then `ICE connected`.
  5. Decline instead → A sees the call end; `calls/{callId}.state == "ended"`.
  6. Functions log shows `onCallInvite(…): VoIP push delivered to …`.
- **Negative:** block the caller on B, then call → function logs
  `is blocked … — no push` and B stays silent even locked. (The client keeps its own
  block check for the foreground path, but that hook is unset in a push-launched app,
  which is why the check also exists server-side.)

---

## 3. Live read receipts

`markRead` has always written `chats/{chatId}/receipts/{uid}`; nothing read it, so an
outgoing message's ticks were a guess. `FirestoreService.listenReceipts` +
`FirebaseSyncCoordinator.applyReceipts` close the loop.

**Rule:** a message is read once **every other participant** has read at or past it —
the peer for a direct chat, the whole room for a group. A participant with no placeable
receipt holds the chat back rather than being skipped; claiming "read" while a member
hasn't opened it is precisely the lie receipts exist to prevent.

`DataStore.markOutgoingRead(upTo:in:)` merges through `MessageStateMachine`, so receipts
are monotone: an out-of-order or replayed snapshot can never walk a message back from
read to delivered. Privacy reciprocity is preserved — with **Read Receipts** off you
neither send yours nor see theirs, matching the settings copy.

### Verification

`LiveSyncTests` covers up-to-and-including semantics, monotonicity under out-of-order
receipts, that incoming messages are untouched, and that a receipt naming an unknown
message is ignored rather than treated as "all read".

Manual: open the chat on device B while device A watches — A's ticks go accent-blue for
every message up to the one B read, and nothing after it.

---

## 4. Live reactions

Reactions were a purely local decoration. They now live at
`chats/{chatId}/reactions/{messageId}_{uid}`.

**Why a per-chat subcollection** rather than one under each message: a single listener
covers every reaction in the conversation. Per-message listeners would mean hundreds of
them in an open chat.

**The composite doc id** enforces the domain rule (one reaction per user per message) in
storage: re-reacting overwrites, un-reacting deletes. Rules authorize on the `uid`
*field*, not the id — trusting the id alone would let anyone craft
`someoneElsesMessage_victimUid`.

**Encryption.** The emoji is content, so it is sealed like a message body:
`ChatPairKey` for direct chats (the only key the peer can also derive), the interim
device-local key otherwise — the same limitation group message bodies already have. The
Double Ratchet is deliberately *not* used: that chain is ordered and stateful per
message, and spending message keys on reactions would desynchronize it. `MessageCrypto`
gained a `Purpose` bound into the AAD so a reaction ciphertext cannot be replayed by the
server as a message body; `.body` keeps the original AAD string, so every message already
in Firestore still opens.

**Merge.** The snapshot is the complete truth for the chat: a message absent from it has
had all reactions removed. That absence is how an un-react propagates. Firestore replays
the local pending write in the first snapshot, so an optimistic reaction is never blanked
between the tap and the server ack.

### Verification

`LiveSyncTests` covers sink publication (add → change → remove), ingest from another
device, removal-by-absence, multiple reactors on one message, tombstoned messages staying
bare, the AAD purpose separation, and the `.body` AAD backwards-compatibility check.

Manual: react on device A → the emoji appears on B within a snapshot; tap the same emoji
again on A → it disappears on both.

---

## 5. Deploy checklist

```bash
firebase deploy --project cove-7f31f --only firestore:rules   # adds the reactions rules
firebase functions:secrets:set TURN_SECRET   --project cove-7f31f
firebase functions:secrets:set APNS_AUTH_KEY --project cove-7f31f < AuthKey_XXXXXXXXXX.p8
cp functions/.env.sample functions/.env && $EDITOR functions/.env
firebase deploy --project cove-7f31f --only functions
```

Then in Xcode: `xcodegen generate` (the project now also links **FirebaseFunctions**).

## 6. Known limitations

- **Group calls** still need an SFU; all of the above is 1:1.
- **TURN relay trust:** a relay sees packet *timing and volume* between the two peers
  (never plaintext — DTLS-SRTP is end-to-end). Called out in `PHASE4_CALLING.md` §12 and
  still pending independent audit.
- **`users/{uid}` is still readable by any signed-in user** — that is deliberate (contact
  discovery by phone number and QR needs it), and it no longer exposes push tokens, which
  moved to the owner-only `privateDevices` subcollection. The profile *does* still expose
  `displayName`, `phone`, `about`, `avatarURL` and presence to any account; narrowing that
  needs a contact-graph model and is separate future work.
- **Group reactions** are sealed with the device-local key, so only the author's device
  can read them — identical to the existing group message-body limitation, and fixed by
  the same future work (sender-key distribution).
- **Re-enabling read receipts** applies from the next receipt onwards; already-delivered
  snapshots are not replayed. This matches the settings copy ("takes effect immediately
  for new messages").
