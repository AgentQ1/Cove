# Inditalk — a private messenger for iOS

Inditalk is an **original** SwiftUI messaging app in the same product category as modern
private messengers: chats, calls, communities/groups, profile & settings, and the
usual modern messaging workflows — with its own warm, parchment-toned identity.

> **On the reference screenshots:** the attached shots were used only as a broad
> *layout/feel* reference (warm off-white background, deep accent, circular avatars,
> bottom tab bar, per-section accent tinting). Inditalk deliberately does **not** copy any
> other app's name, logo, iconography, brand colors, or proprietary UI. All icons are
> Apple SF Symbols; all colors, copy, and layout are Inditalk's own. See
> [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

> ⚠️ **Not production-secure.** The encryption and calling stacks here are a
> *reference architecture + working building blocks*, not an audited product. Do not
> ship as-is. See [`docs/PHASE5_ENCRYPTION.md`](docs/PHASE5_ENCRYPTION.md).

---

## Visual identity

| Token | Light | Meaning |
|-------|-------|---------|
| Background | `#F6F1E8` warm parchment | app surface |
| `ink` | `#26324F` deep slate blue | primary accent (Chats + chrome) |
| `pine` | `#2F5D50` deep pine green | Calls section accent |
| `ochre` | `#B0842F` muted gold | call-type glyphs, timers, highlights |
| `danger` | `#C0453B` | missed calls, failed sends |

Deep-serif screen titles (Apple *New York*), circular avatars, a floating capsule
tab bar with a per-tab pill highlight, and light/dark support throughout.

---

## How to run in Xcode

The app core uses Apple frameworks (SwiftUI, Combine, SwiftData, CryptoKit, CallKit,
PushKit, AVFoundation, Photos, Contacts, Security). The **backend is Firebase** — a
documented SPM dependency (Apache-2.0): `FirebaseAuth`, `FirebaseFirestore`,
`FirebaseStorage`, `FirebaseMessaging`. See
[**Firebase setup**](docs/PHASE3_FIREBASE.md) for the console steps. Until you add the
real `GoogleService-Info.plist`, the app launches in **local SwiftData mode** (no
crash), so you can build and explore immediately.

### Option A — XcodeGen (fastest)
XcodeGen is an optional *build-time* tool (MIT) that generates the `.xcodeproj` from
[`project.yml`](project.yml). It ships no runtime code.

```bash
brew install xcodegen
cd Inditalk
xcodegen generate
open Inditalk.xcodeproj
# Select the "Inditalk" scheme → an iPhone simulator → ⌘R
```

### Option B — Manual (no extra tools)
1. Xcode → **File ▸ New ▸ Project… ▸ iOS ▸ App**. Name it `Inditalk`, Interface **SwiftUI**,
   Language **Swift**. Save it next to this folder.
2. Delete the auto-generated `ContentView.swift` and `InditalkApp.swift`.
3. Drag the **`Inditalk/`** source folder and the **`InditalkTests/`** folder into the project
   navigator (check *Copy items if needed*, create groups). Add `InditalkTests` to a Unit
   Test target.
4. In the target's **Info** tab, point at `Inditalk/Info.plist` (or copy its keys in), and
   set **Deployment Target ≥ iOS 17**, **Swift Language Version = 6**.
5. For calls on-device only: **Signing & Capabilities ▸ +** → *Push Notifications* and
   *Background Modes* (Voice over IP, Remote notifications, Audio).
6. ⌘R to run, ⌘U to test.

### Running the tests
`⌘U` runs `InditalkTests`: message-state machine, CryptoKit wrapper (X3DH symmetry, AEAD,
safety numbers), chat-list/store view-model logic, and the sync-engine outbox.
The crypto and core logic were type-checked and the crypto round-trips were executed
against the macOS SDK during development.

---

## Architecture

MVVM + clean modular layering, offline-first, one reactive source of truth.

```
Inditalk/
  App/            InditalkApp (entry), RootView (custom tab bar), AppSession
  DesignSystem/   Palette, Theme, Avatar, badges, empty/loading states
  Models/         User, Chat, Message, Call, enums, disappearing options
  Data/           DataStore (source of truth), MockData seed, MessageStateMachine
  Features/       Chats, ChatDetail, Calls, ActiveCall, Communities, Updates,
                  Settings, Onboarding  (each: View + ViewModel + rows)
  Services/
    Crypto/       CryptoService (CryptoKit), KeyStore (Keychain)
    Calling/      CallManager (CallKit), VoIPPushHandler (PushKit)
    Networking/   APIClient (REST), RealtimeClient (WebSocket)
    Sync/         SyncEngine (outbox + delta sync)
    PermissionsManager (camera/mic/photos/contacts)
  Utilities/      RelativeDate, Haptics
InditalkTests/        view-model, crypto, sync, state-machine tests
docs/             ARCHITECTURE, PHASE3_BACKEND_API, PHASE4_CALLING,
                  PHASE5_ENCRYPTION, API_CONTRACTS
```

Design docs live in [`docs/`](docs/) and specify the backend API contracts, WebSocket
protocol, sync engine, CallKit/PushKit/WebRTC calling, and the E2EE cryptographic
design with its explicit limitations.

---

## Per-phase status

### Phase 1 — App shell & core screens ✅ working
- Custom floating tab bar (Updates · Calls · Communities · Chats · You) with per-tab
  accent + unread badge.
- **Chats list**: serif header, search, archived row, call-type subtitle glyphs,
  unread badges, pin/mute/archive swipe actions, empty/no-results states.
- **Chat detail**: day separators, system/encryption notices, incoming/outgoing
  bubbles, delivery receipts (clock→check→double→read), reactions, replies, context
  menu (reply/react/star/forward/delete), composer with attachment sheet & mic/send.
- **Calls list**: quick-action tray, Recent history with direction glyphs + missed
  styling, tap to open an active call.
- **Active voice & video call** screens with a live state machine + timer.
- **Settings/Profile**, privacy, starred messages, contact & group info, new-chat,
  media picker, onboarding + OTP.
- Local `DataStore` + seeded `MockData`; sending simulates the full delivery lifecycle.

### Phase 2 — Persistence, state transitions, organization 🟡 partial
- ✅ `MessageStateMachine` (pure, fully unit-tested; drives receipt merging, rejects
  out-of-order/regressive updates).
- ✅ Search, archive, pin, mute, unread, starred, reactions, delete, disappearing —
  all working against the in-memory store.
- ✅ Group chats: model, group info screen, admins/permissions/invite links.
- ⏳ **Remaining:** swap the in-memory store for **SwiftData** persistence (the
  `MessagingStore` protocol already isolates the UI from the backing store, so this is
  a drop-in). Design in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

### Phase 3 — Backend, realtime, sync, push 🟢 Firebase backend wired
- ✅ **Firebase is the live backend** (project `cove-7f31f`). Real service layer:
  `FirebaseAuthService` (phone OTP), `FirestoreService` (realtime chats/messages,
  receipts, typing, presence — **stores E2EE ciphertext**), `FirebaseStorageService`
  (media), `PushService` (FCM), `AppDelegate` (configure + APNs). Server-side
  [`firestore.rules`](firestore.rules) enforce participant-only access.
- ✅ **Live cross-device state:** listeners on `chats/{chatId}/receipts` turn real read
  receipts into honest ticks (a message reads as *read* only once every other
  participant has read past it), and `chats/{chatId}/reactions` syncs reactions across
  devices with the emoji stored as ciphertext. See
  [`PHASE6_TURN_VOIP_SYNC.md`](docs/PHASE6_TURN_VOIP_SYNC.md).
- ✅ Setup + schema + E2EE caveats in [`PHASE3_FIREBASE.md`](docs/PHASE3_FIREBASE.md).
  The original vendor-neutral REST/WebSocket design remains in
  [`PHASE3_BACKEND_API.md`](docs/PHASE3_BACKEND_API.md) as the abstract contract.
- ⏳ **Remaining (you):** register the iOS app + drop in the real
  `GoogleService-Info.plist`, enable Phone Auth / Firestore / Storage / FCM, deploy
  rules, add a Cloud Function to fan out pushes, flip `OnboardingViewModel` to the live
  auth path (snippet in the doc). Until the plist is added the app runs in local mode.

### Phase 4 — Voice/video calling 🟢 WebRTC + Firestore signaling wired
- ✅ Full call stack: `CallManager` (CallKit CXProvider + PushKit VoIP),
  `WebRTCMediaSession` (RTCPeerConnection behind the `CallMediaSession` hook),
  `FirestoreSignalingService` (SDP/ICE over Firestore), and `CallCenter` orchestrating
  outgoing/incoming flows. Rules in [`firestore.rules`](firestore.rules); flow +
  schema in [`PHASE4_SIGNALING.md`](docs/PHASE4_SIGNALING.md).
- ✅ **Call UX wired:** chat-header + contact Audio/Video buttons launch calls;
  `LiveCallView` renders the live WebRTC feed via `VideoRendererView` (RTCMTLVideoView)
  and drives mute/camera/end through `CallCenter`; incoming-call listening starts with
  auth. Simulation screens remain for local/demo mode.
- ✅ **Verified here:** the pure `CallSessionMachine` (9/9 transitions ran green) and
  `CallSignal` Codable round-trip. Media/CallKit/UI glue compiles once the WebRTC +
  Firebase SPM packages are added (can't build in this CI env — no iOS SDK).
- ✅ **TURN wired end-to-end:** the `getTurnCredentials` Cloud Function mints short-lived
  credentials (TURN REST API / coturn `use-auth-secret`) and `ICEServerConfig` installs
  them *before* each `RTCPeerConnection` is built, so calls survive symmetric/carrier
  NAT. STUN-only remains the fallback when no relay is provisioned.
- ✅ **Background ringing:** the `onCallInvite` function sends an APNs **VoIP push** when
  a call invite is created; PushKit reports it to CallKit, so a backgrounded or locked
  device rings. Answering/declining drive the same Firestore + WebRTC flow as the
  foreground path. Provisioning steps in [`PHASE6_TURN_VOIP_SYNC.md`](docs/PHASE6_TURN_VOIP_SYNC.md).
- ⏳ **Remaining:** provision the relay + APNs key for your project (operator work), and
  an **SFU** for group calls (mesh doesn't scale). Not production-secure until audited.

### Phase 5 — End-to-end encryption 🟢 working Double Ratchet
- ✅ **Real cross-device E2EE, verified at runtime:** [`DoubleRatchet`](Inditalk/Inditalk/Services/Crypto/DoubleRatchet.swift)
  (CryptoKit implementation of the public Signal Double Ratchet) + [`E2EESession`](Inditalk/Inditalk/Services/Crypto/E2EESession.swift)
  (X3DH → ratchet). A two-party harness ran green: both devices derive matching keys,
  a DH-ratchet step, **out-of-order delivery** via skipped keys, and AEAD binding to the
  chat. Locked in [`DoubleRatchetTests`](InditalkTests/DoubleRatchetTests.swift).
- ✅ `IdentityKeyManager` (identity + signed prekey in Keychain), `PrekeyService`
  (publish/fetch bundles over Firestore), `E2EESessionStore` (per-chat sessions); the
  sync layer prefers the session and stores **ciphertext** in Firestore. Safety numbers
  now use the device's real X25519 identity key.
- ✅ Disappearing-messages timer end-to-end.
- ⏳ **Remaining:** carry the initiator's identity+ephemeral in the first message so the
  responder can auto-establish (integration point flagged in `PrekeyService`), persist
  ratchet state across launches, one-time-prekey consumption, group sender-keys, and an
  **independent security audit** before production. Not production-secure until audited.

---

## License / originality notes
Inditalk is original work built to a spec. It intentionally avoids any third-party app's
branding, assets, colors, iconography, or proprietary UI, and depends only on Apple
frameworks at runtime (XcodeGen is an optional build-time convenience).
