# Phase 6 — operator setup (TURN, VoIP ringing, live sync)

**Project:** `cove-7f31f`  ·  **Bundle id:** `chat.cove.app`  ·  **APNs Key ID:** `S4F7MB6BTM`
**Team ID:** `JR6W8P6Z8N`  ·  **TURN host:** `35-239-187-69.sslip.io` (`35.239.187.69`)

Phase 6 is **deployed and verified end to end from the server side**. The credentials and
infrastructure that were previously blocked now exist. What genuinely remains is the part
that cannot be done without hardware: ringing and relaying between two physical iPhones.

Run every command from the directory holding `firebase.json` (this one).

| Item | Status |
|---|---|
| TURN credential minting (`getTurnCredentials`), client refresh + STUN fallback | **Deployed** |
| VoIP push (`onCallInvite`), PushKit → CallKit, per-device APNs environment | **Deployed** |
| Live read receipts, live reactions | **Deployed** |
| Push tokens in an owner-private subcollection + rules | **Deployed** |
| Server-side blocked-caller check | **Deployed** |
| TURN relay reachable (host, DNS, TLS, firewall, coturn secret) | **Done — allocating on UDP/TCP/TLS, 0% loss** |
| `TURN_SECRET` in Secret Manager | **Done — version 2** |
| `APNS_TEAM_ID` | **Done — `JR6W8P6Z8N`, verified against Apple** |
| `APNS_AUTH_KEY` (.p8) in Secret Manager | **Done — version 1** |
| Deployment to `cove-7f31f` | **Done — rules, indexes, 4 functions** |
| Physical-device ring / relay tests | **REMAINING — needs two real iPhones** |

---

## What was verified, and how

Two things in this system fail *silently* — a wrong Team ID and an unreachable relay both
look exactly like "it just doesn't ring" / "it just doesn't connect". Both were verified
against the real services rather than assumed.

**APNs Team ID.** A provider-token JWT signed with `AuthKey_S4F7MB6BTM.p8` and
`iss=JR6W8P6Z8N` was POSTed to both `api.sandbox.push.apple.com` and `api.push.apple.com`
for topic `chat.cove.app.voip`. Apple answered **`400 BadDeviceToken`** on both. APNs
validates the provider token and topic *before* the device token, so reaching
`BadDeviceToken` proves team + key + topic are accepted — a wrong team would have returned
`403 InvalidProviderToken`.

**The deployed `onCallInvite`.** A synthetic ringing call was written to `calls/{callId}`
with a callee holding one well-formed but fake VoIP token. Production logs:

```
onCallInvite(...): APNs rejected device ... (400 BadDeviceToken, sandbox)
onCallInvite(...): VoIP push delivered to 0/1 device(s), pruned 1 dead token(s)
```

Those two lines prove the trigger fires, the secrets resolve in the deployed runtime, the
blocked-caller and `privateDevices` lookups run, APNs **authenticates**, and dead-token
pruning works. Only a real device token is missing. The synthetic documents were deleted.

**The relay.** `scripts/verify-turn-relay.sh` mints a credential with the same HMAC
construction as `functions/turn.js` and allocates through the relay on all three transports
— UDP 3478, TCP 3478, TLS 5349 — with 0% packet loss. Because coturn independently
recomputes the HMAC from its own copy of the secret, a successful allocation also proves
`TURN_SECRET` matches `static-auth-secret` byte for byte.

---

## 1. The TURN relay

A GCE instance `cove-turn` (`us-central1-a`, `e2-small`, static IP `35.239.187.69`) running
coturn, provisioned by [`scripts/provision-turn.sh`](scripts/provision-turn.sh). The script
is idempotent — re-run it after a partial failure.

The hostname is **sslip.io wildcard DNS**: `35-239-187-69.sslip.io` resolves to
`35.239.187.69`. No domain is registered for this project, and `turns:` on 5349 needs a real
DNS name for Let's Encrypt to certify. If you later register a domain, point a record at the
same IP, re-run certbot for it, and update `TURN_URLS`.

```bash
# Health check
gcloud compute ssh cove-turn --zone us-central1-a --project cove-7f31f \
  --command 'systemctl is-active coturn; sudo ss -lntup | grep -E "3478|5349"'

# Full allocation test (needs coturn's client tools: brew install coturn)
TURN_HOST=35-239-187-69.sslip.io TURN_SECRET_FILE=/path/to/secret \
  ./scripts/verify-turn-relay.sh
```

### Two permission traps that cost real debugging time

Both were hit during provisioning and are now handled by the script. Both fail **silently**:
coturn starts, reports itself `active`, and serves a degraded or non-functional relay.

1. **`/etc/turnserver.conf` must be `0640 root:turnserver`.** coturn drops to the
   unprivileged `turnserver` user. A root-only `0600` config is one it cannot read, so it
   falls back to *package defaults* with no error at all: it auto-discovers listener
   addresses, starts **no TLS listener**, and ignores `static-auth-secret` entirely.

2. **Let's Encrypt directories must be group-readable by `turnserver`.** certbot creates
   `/etc/letsencrypt/{live,archive}` as `0700 root`. Without a group grant, coturn logs
   `cannot start TLS and DTLS listeners` and 5349 is simply absent while 3478 works — so
   calls fail only on the restrictive networks that need `turns:` most. The script adds an
   `ssl-cert` group and re-applies it from a certbot **deploy hook**, because each renewal
   writes a fresh root-only `privkeyN.pem`.

### Secret hygiene

`TURN_SECRET` must be stored with **no trailing newline**. `openssl rand -hex 32 > file`
leaves one, and the function would then HMAC with `"<hex>\n"` while coturn uses `<hex>` —
every credential rejected, with no error anywhere. Version 1 of the secret has this defect
and was superseded by version 2; destroy it when convenient:

```bash
gcloud secrets versions destroy 1 --secret=TURN_SECRET --project cove-7f31f
gcloud secrets versions access latest --secret=TURN_SECRET --project cove-7f31f | wc -c  # expect 64
```

### Cost

`e2-small` is roughly $13/month, plus egress on relayed media (~$0.12/GB). Only calls that
cannot connect peer-to-peer consume relay bandwidth. To retire the relay, clear `TURN_URLS`
and redeploy — the client falls back to STUN with no code change.

---

## 2. Configuration

`functions/.env` is gitignored and fully populated:

```env
TURN_URLS=turn:35-239-187-69.sslip.io:3478?transport=udp,turn:35-239-187-69.sslip.io:3478?transport=tcp,turns:35-239-187-69.sslip.io:5349?transport=tcp
TURN_TTL_SECONDS=3600
APNS_KEY_ID=S4F7MB6BTM
APNS_TEAM_ID=JR6W8P6Z8N
APNS_BUNDLE_ID=chat.cove.app
APNS_USE_SANDBOX=true
```

`APNS_USE_SANDBOX` is only a *fallback*. Each install records its own `aps-environment` in
`users/{uid}/privateDevices/{deviceId}.apnsEnvironment` and every push goes to the host that
build was signed for, so a Debug install and a TestFlight install of the same account can be
tested at the same time.

Secrets live in Secret Manager, never in `.env`:

```bash
firebase functions:secrets:set TURN_SECRET   --project cove-7f31f --data-file /path/to/secret
firebase functions:secrets:set APNS_AUTH_KEY --project cove-7f31f --data-file /path/AuthKey_S4F7MB6BTM.p8
```

Re-deploy after **any** `functions:secrets:set` — a running function keeps the secret
version it was deployed with.

---

## 3. Deploy

```bash
firebase deploy --project cove-7f31f --only firestore:rules
firebase deploy --project cove-7f31f --only firestore:indexes
firebase deploy --project cove-7f31f --only functions
```

Currently deployed: `getTurnCredentials`, `onCallInvite`, `onNewMessage`, `onUserDeleted`.

```bash
firebase functions:log --project cove-7f31f --only getTurnCredentials
firebase functions:log --project cove-7f31f --only onCallInvite
```

Expected:

```
getTurnCredentials: issued 3 relay URL(s) to <uid>, expires in 3600s
onCallInvite(<callId>): VoIP push delivered to 1/1 device(s) of <uid>
```

Failure signatures worth recognising:

| Log | Cause |
|---|---|
| `TURN not configured (TURN_URLS/TURN_SECRET) — returning STUN-only` | `TURN_URLS` empty or `TURN_SECRET` unset |
| `ignoring malformed TURN URL in TURN_URLS: "…"` | typo in `TURN_URLS` |
| `APNs not configured — skipping VoIP push` | `APNS_TEAM_ID`, `APNS_KEY_ID` or the `.p8` secret missing |
| `APNs rejected device … (403 InvalidProviderToken…)` | wrong Team ID, or the key doesn't belong to that team |
| `APNs rejected device … (400 BadDeviceToken…)` | token/host environment mismatch — check the device's `apnsEnvironment` |
| `… is blocked by … — no push` | working as intended |

---

## 4. Build and run the app

```bash
set -a; source .xcodegen.env; set +a     # INDITALK_DEVELOPMENT_TEAM=JR6W8P6Z8N
xcodegen generate
open Inditalk.xcodeproj
```

Debug builds sign with `Inditalk/Inditalk.entitlements` (`aps-environment=development`); Release and
TestFlight with `Inditalk/Inditalk.Release.entitlements` (`production`). Both are pinned per
configuration in `project.yml`, so archiving cannot silently ship a sandbox entitlement.

Current state: `xcodebuild … build` succeeds and the test suite passes (178 tests, 7 skipped,
0 failures).

---

## 5. Physical-device test checklist — THE REMAINING WORK

VoIP pushes are **never** delivered to the Simulator, and a relay is only exercised when two
peers genuinely cannot reach each other directly. Two physical iPhones, two accounts.

**Setup**

- [ ] Device A on Wi-Fi; Device B on **cellular** (Wi-Fi off) — this is what forces a relay
      candidate on most carriers.
- [ ] `users/{B}/privateDevices/{deviceId}` holds `voipToken` and the expected
      `apnsEnvironment` for the build installed on B.
- [ ] `users/{B}` itself has **no** `voipToken`/`fcmToken` field (migration cleared it).

**TURN**

- [ ] Call A → B. Xcode console on both shows `[Inditalk call] TURN configured: 3 relay URL(s)`
      then `[Inditalk call] building peer connection with STUN + TURN`.
- [ ] Confirm the selected candidate pair is type **`relay`** (WebRTC stats on device, or an
      `allocation` line for the minted username in coturn's log:
      `gcloud compute ssh cove-turn --zone us-central1-a --command 'sudo grep allocation /var/log/syslog | tail'`).
- [ ] Negative: clear `TURN_URLS`, redeploy, call again → log reads
      `TURN unavailable; continuing with STUN only` and the call still connects on a
      permissive network. Restore `TURN_URLS` afterwards.

**Ringing**

- [ ] App **open** on B → incoming call UI appears.
- [ ] App **backgrounded** on B → CallKit rings.
- [ ] Phone **locked** on B → lock-screen call UI with the caller's name.
- [ ] App **terminated** (swiped away) on B → still rings (push-launched).
- [ ] **Answer** → two-way audio; repeat with video for two-way video.
- [ ] **Decline** → A sees the call end; `calls/{callId}.state == "ended"`.
- [ ] **Blocked caller**: block A on B, call → functions log shows `is blocked … — no push`,
      and B stays silent even locked.
- [ ] **Invalid token cleanup**: uninstall on B, call from A → the function logs an APNs
      rejection and `pruned 1 dead token(s)`; the device document loses its `voipToken`.
      *(Already proven server-side with a synthetic token — this confirms it on real hardware.)*
- [ ] **Sign-out cleanup**: sign out on B → `users/{B}/privateDevices/{deviceId}` is gone, and
      a call from A no longer wakes B.

**Live sync**

- [ ] **Read receipts**: A sends three messages; B opens the chat → A's ticks turn read for
      every message up to the one B read and none after it. Turn *Read Receipts* off on B → A
      stops seeing them, and B stops seeing A's.
- [ ] **Reactions**: react on A → appears on B within a snapshot; react with a different emoji
      on A → replaces (never two from one person); tap the same emoji again → the reaction
      disappears on **both** devices.

Only when every box above is ticked is Phase 6 fully proven. Everything reachable without
hardware is already done and verified.
