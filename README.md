# Inditalk

A private messenger for iOS — SwiftUI + SwiftData, with a Firebase backend, WebRTC
voice/video calling, and end-to-end encrypted messaging (Double Ratchet over CryptoKit).

> ⚠️ **Not production-secure.** The encryption and calling stacks are a reference
> architecture plus working building blocks, not an audited product. Don't ship as-is —
> see [`Cove/docs/PHASE5_ENCRYPTION.md`](Cove/docs/PHASE5_ENCRYPTION.md).

## Repository layout

Everything lives under [`Cove/`](Cove/); the repository root holds only tooling config.

```
Cove/
  Inditalk/          app source — App, DesignSystem, Models, Data, Features, Services, Utilities
  InditalkTests/     unit tests (crypto, sync, call + message state machines)
  functions/         Firebase Cloud Functions (CommonJS: TURN credentials, VoIP push, devices)
  docs/              architecture, backend/API contracts, calling, signaling, encryption
  compliance/        BIS encryption self-classification report
  site/              static site
  scripts/           TURN provisioning + relay verification
  project.yml        XcodeGen manifest — the source of truth for the Xcode project
  firestore.rules    participant-only access rules
```

## Getting started

**The `.xcodeproj` is not checked in** — it's generated from `project.yml`, so a fresh
clone has no project to open until you generate one:

```bash
brew install xcodegen
cd Cove
xcodegen generate
open Inditalk.xcodeproj      # scheme "Inditalk" → iPhone simulator → ⌘R
```

Re-run `xcodegen generate` after adding or removing source files — the manifest uses
explicit file references, so new files are invisible to the build until you do.

Requires Xcode with iOS 17+ SDK, Swift 6. Firebase and WebRTC resolve automatically as
Swift Package Manager dependencies.

### Local configuration you must supply

No credentials are stored in this repository. Each of these is gitignored, and the app
launches in **local SwiftData mode** (no crash) until you add the Firebase plist:

| File | Purpose | Template |
|---|---|---|
| `Cove/Inditalk/Resources/GoogleService-Info.plist` | Firebase iOS app config | [`GoogleService-Info.SAMPLE.plist`](Cove/Inditalk/Resources/GoogleService-Info.SAMPLE.plist) |
| `Cove/.xcodegen.env` | your Apple `DEVELOPMENT_TEAM`, kept out of source | [`.xcodegen.env.sample`](Cove/.xcodegen.env.sample) |
| `Cove/functions/.env` | non-secret function config (TURN URLs, APNs key/team IDs) | [`functions/.env.sample`](Cove/functions/.env.sample) |

Real secrets — the TURN shared secret and the APNs `.p8` auth key — live in Google Secret
Manager, never on disk. Setup steps are in
[`PHASE6_OPERATOR_SETUP.md`](Cove/PHASE6_OPERATOR_SETUP.md).

## Build and test

```bash
# Build
xcodebuild -project Cove/Inditalk.xcodeproj -scheme Inditalk \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath Cove/.derivedData build

# Unit tests (skip the opt-in live suites that hit the real Firebase project)
xcodebuild -project Cove/Inditalk.xcodeproj -scheme Inditalk \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath Cove/.derivedData test \
  -skip-testing:InditalkTests/LiveFirebaseAuthTests \
  -skip-testing:InditalkTests/LiveFirebaseMessagingTests

# Cloud Functions (Node's built-in test runner, no build step)
npm --prefix Cove/functions test

# Firestore security rules, against the emulator
npm --prefix Cove run test:rules
```

The two live suites are gated behind the `INDITALK_LIVE_TESTS` environment variable and
talk to the real Firebase project, so they stay opt-in.

## Architecture at a glance

MVVM with clean modular layering, offline-first, one reactive source of truth. The seams
worth knowing before changing anything:

- **`FirebaseSyncCoordinator`** — the only bridge between Firestore and the local
  `DataStore`.
- **`MessageCrypto` / `ChatPairKey`** — the message crypto boundary (ECDH pair key per
  direct chat); Firestore only ever stores ciphertext.
- **`CallCenter`** — orchestrates calls across CallKit, Firestore signaling, and WebRTC;
  presented globally from `RootView` off `CallCenter.state`.

## Documentation

- [`Cove/README.md`](Cove/README.md) — full project README: visual identity, per-phase
  status, and what remains in each area
- [`Cove/docs/ARCHITECTURE.md`](Cove/docs/ARCHITECTURE.md) — layering and data flow
- [`Cove/docs/PHASE3_FIREBASE.md`](Cove/docs/PHASE3_FIREBASE.md) — backend setup and schema
- [`Cove/docs/PHASE4_CALLING.md`](Cove/docs/PHASE4_CALLING.md),
  [`PHASE4_SIGNALING.md`](Cove/docs/PHASE4_SIGNALING.md) — calling and signaling
- [`Cove/docs/PHASE5_ENCRYPTION.md`](Cove/docs/PHASE5_ENCRYPTION.md) — E2EE design and its
  explicit limitations
- [`Cove/SETUP.md`](Cove/SETUP.md), [`Cove/RELEASE_CHECKLIST.md`](Cove/RELEASE_CHECKLIST.md)
  — environment setup and release process

## Originality

Inditalk is original work built to a spec. It deliberately avoids any third-party app's
name, logo, branding, assets, colors, iconography, or proprietary UI. All icons are Apple
SF Symbols; all colors, copy, and layout are its own.
