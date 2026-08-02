# Inditalk — end-to-end setup guide

Everything needed to take Inditalk from source to a running app on `cove-7f31f`, in
order. Steps marked **[you]** need the Firebase console or an Apple account; steps
marked **[cli]** are terminal commands; **[xcode]** are in Xcode.

- Project: **cove** · ID **cove-7f31f** · number **493828629214**
- Bundle ID: **`chat.cove.app`**
- Min iOS: **17** · Swift **6**

> ⚠️ Inditalk is a reference build. The encryption and calling stacks are **not
> production-secure until independently audited** — do not ship as-is.

---

## 0. Prerequisites
- [ ] Xcode 16+ with an iOS 17 simulator.
- [ ] `firebase` CLI (`14.x` confirmed) logged into the account that **owns
      cove-7f31f**: `firebase login`.
- [ ] (Optional) `brew install xcodegen` to generate the project from `project.yml`.

---

## 1. Get the code into Xcode **[xcode]**
**Option A — XcodeGen (fastest):**
```bash
cd /Users/agentq/italk/Inditalk
xcodegen generate      # reads project.yml (targets, SPM packages, Info.plist)
open Inditalk.xcodeproj
```
**Option B — manual:** New iOS App named `Inditalk` (SwiftUI), delete the template
`ContentView`/`InditalkApp`, drag in `Inditalk/` and `InditalkTests/`, set Info.plist to
`Inditalk/Info.plist`, deployment target ≥ 17, Swift language version 6.

---

## 2. Add the SPM packages **[xcode]**
XcodeGen wires these automatically. If manual, add both:
- `https://github.com/firebase/firebase-ios-sdk` → **FirebaseAuth, FirebaseFirestore,
  FirebaseStorage, FirebaseMessaging, FirebaseFunctions**
- `https://github.com/stasel/WebRTC` → **WebRTC**

Until these are added, the Firebase/WebRTC files won't compile (the pure logic +
crypto + SwiftData layers do).

---

## 3. Firebase console setup **[you]**
1. **Register the iOS app:** console → project *cove* → Add app → iOS →
   bundle ID `chat.cove.app`. Download **`GoogleService-Info.plist`** → drop it in
   `Inditalk/Resources/`. XcodeGen bundles it automatically on the next `xcodegen generate`;
   it is **gitignored** so it is never committed. Do **not** delete or edit
   `GoogleService-Info.SAMPLE.plist` — it is documentation only and is **no longer
   bundled into the app** (excluded in `project.yml`). Without the real plist the app
   still launches, but in **local SwiftData mode** (no backend).
2. **Authentication** → Sign-in method → enable **Phone**. Add a test number under
   "Phone numbers for testing" for the simulator. For real devices, upload an **APNs
   auth key** (Project settings → Cloud Messaging).
3. **Firestore Database** → Create (production mode).
4. **Storage** → Get started.
5. **Cloud Messaging** → enabled by default; the APNs key from step 2 covers it.

---

## 4. Deploy security rules + indexes **[cli]**
Config files are already in the repo (`firebase.json`, `.firebaserc`,
`firestore.rules`, `firestore.indexes.json`, `storage.rules`). The active project for
this folder is already set to `cove-7f31f`.

> ⚠️ **Always pin `--project cove-7f31f`.** A home-dir active-project override exists
> (`/Users/agentq` → `fitcheck-d3091`); pinning guarantees you don't deploy to the
> wrong project.

```bash
cd /Users/agentq/italk/Inditalk
firebase deploy --project cove-7f31f --only firestore:rules,firestore:indexes,storage
```
This publishes: participant-only chat/message rules, call-signaling rules, the two
composite indexes (chats + calls), and Storage rules.

---

## 5. Signing & capabilities **[xcode][you]**
- [ ] Set your **Development Team** — it's read from an env var so it stays out of
      source and survives regeneration:
      `INDITALK_DEVELOPMENT_TEAM=YOURTEAM xcodegen generate` (or copy `.xcodegen.env.sample`
      → `.xcodegen.env` and `source` it first).
- [ ] Target → Signing & Capabilities → **+** (these are account-side, not just source):
  - **Push Notifications** — backs the `aps-environment` key already in
    `Inditalk/Inditalk.entitlements` (wired via `CODE_SIGN_ENTITLEMENTS`).
  - **Background Modes** → Remote notifications, Voice over IP, Audio.

`Info.plist` already contains the camera/mic/photos/contacts usage strings and the VoIP
background mode; `PrivacyInfo.xcprivacy` declares Inditalk's required-reason API use
(UserDefaults, CA92.1); `Inditalk/Assets.xcassets` carries the AppIcon. See
`RELEASE_CHECKLIST.md` for the full account-side list (APNs key, App Privacy, etc.).

---

## 6. Turn on the live backend **[xcode]**
- `AppConfig.backend` is already `.firebase`; it activates automatically once the real
  plist is present (`AppConfig.usesFirebase`).
- **Live phone auth** switches on automatically too: `OnboardingView` injects
  `FirebaseAuthService` when Firebase is configured (else the mock `424242` flow).
- On sign-in the app publishes your prekey bundle and starts Firestore sync +
  incoming-call listening.

---

## 7. Calls: TURN + background ringing **[you]** (for real devices)
The client side is wired; both need **operator provisioning**. Full detail and
verification steps: [docs/PHASE6_TURN_VOIP_SYNC.md](docs/PHASE6_TURN_VOIP_SYNC.md).

**TURN** — STUN alone is fine for simulator/LAN but stalls on carrier/symmetric NAT.
The app fetches short-lived credentials from the `getTurnCredentials` Cloud Function
before every peer connection; TURN secrets are never in the app binary. Point it at your
relay (coturn with `use-auth-secret`, or any provider accepting the TURN REST API):
```bash
cp functions/.env.sample functions/.env   # set TURN_URLS, TURN_TTL_SECONDS
firebase functions:secrets:set TURN_SECRET --project cove-7f31f
```
Unset, the function answers "no TURN" and calls stay on STUN — degraded, never broken.

**Background ringing** — without a VoIP push the callee only rings with the app open.
The `onCallInvite` function pushes to APNs (PushKit → CallKit) when a call invite is
created. Needs an APNs auth key (.p8) from the Apple Developer portal:
```bash
# functions/.env: APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID, APNS_USE_SANDBOX
firebase functions:secrets:set APNS_AUTH_KEY --project cove-7f31f < AuthKey_XXXXXXXXXX.p8
firebase deploy --project cove-7f31f --only functions
```
`APNS_USE_SANDBOX=true` for Debug builds (`aps-environment=development`), `false` for
TestFlight/App Store. A mismatch returns `BadDeviceToken` and the phone silently never
rings. VoIP pushes are **not** delivered to the Simulator — test on a real device.

Group calls need an SFU (mesh doesn't scale past ~4).

---

## 8. Run & verify
- **⌘U** runs the tests (all pass without Firebase): message-state machine, CryptoKit
  wrapper, **Double Ratchet** (X3DH + out-of-order), chat-list/store, sync outbox,
  call state machine.
- **⌘R** on a simulator. Local mode works with no backend; with the plist + rules
  deployed, sign in with a test number and messages/calls go through Firebase.

---

## 9. Before anyone relies on it
- [ ] Carry the initiator's identity+ephemeral in the first message so the responder
      auto-establishes its ratchet (seam flagged in `PrekeyService`).
- [ ] Persist ratchet state across launches; one-time-prekey consumption.
- [ ] Provision the TURN relay + APNs auth key (§7); call-quality hardening; SFU for
      group calls.
- [x] ~~Narrow the `users/{uid}` read rule~~ — push tokens moved to
      `users/{uid}/privateDevices/{deviceId}`, owner-only under the rules (the profile
      itself stays readable for contact discovery). See `PHASE6_OPERATOR_SETUP.md`.
- [ ] **Independent security audit** of the crypto + calling stacks.
- [ ] Verify `signedPreKeySignature` on fetched bundles.

---

## Reference docs
| Doc | Covers |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | App architecture, modules, data flow |
| [docs/PHASE3_BACKEND_API.md](docs/PHASE3_BACKEND_API.md) · [API_CONTRACTS.md](docs/API_CONTRACTS.md) | Vendor-neutral API/realtime design |
| [docs/PHASE3_FIREBASE.md](docs/PHASE3_FIREBASE.md) | Firebase schema, rules, E2EE caveats |
| [docs/PHASE4_CALLING.md](docs/PHASE4_CALLING.md) · [PHASE4_SIGNALING.md](docs/PHASE4_SIGNALING.md) | CallKit/PushKit/WebRTC + Firestore signaling |
| [docs/PHASE6_TURN_VOIP_SYNC.md](docs/PHASE6_TURN_VOIP_SYNC.md) | TURN credentials, VoIP push ringing, live receipts/reactions |
| [docs/PHASE5_ENCRYPTION.md](docs/PHASE5_ENCRYPTION.md) | E2EE design, threat model, limitations |
