# Inditalk App Store Deployment Readiness Report

Generated: 2026-07-24

Scope: local checkout at `/Users/agentq/italk/Inditalk`, target `Inditalk`, bundle ID
`chat.cove.app`, iOS App Store deployment.

## Executive Summary

Inditalk is not ready for App Store deployment yet.

The good news: the generated Xcode project resolves packages, builds for testing,
and the existing unit tests pass. The current blockers are not basic compilation.
They are production deployment items: signing/capabilities, real Firebase
configuration, App Store privacy requirements, app icon/assets, account deletion,
review-ready user-generated-content controls, removal of placeholder/reference-build
copy, and security hardening before making private-messenger/E2EE claims.

Recommended release posture:

- TestFlight/internal: possible after real signing, Firebase config, app icon, and
  privacy manifest are added.
- App Store/public launch: do not submit until all P0 items below are complete.
- Public "secure/private messenger" positioning: do not ship until the crypto,
  calling, push, and backend surfaces have had independent security review.

## Local Fixes Applied (update — 2026-07-24)

This section records the App-Store-readiness work that was fixable **in the repo**. It
was implemented and verified after the original analysis below. Anything needing an
Apple/Firebase account, a hosted legal page, real credentials, or a human decision was
**not** faked — those are tracked in `RELEASE_CHECKLIST.md`.

Source of truth for project settings is `project.yml`; the `.xcodeproj` was regenerated
with `xcodegen` and the app was built + tested (results under "Verification Run").

| Area | What changed (in repo) | Still external/manual |
|---|---|---|
| **Privacy manifest** | Added `Inditalk/Inditalk/PrivacyInfo.xcprivacy` declaring `NSPrivacyAccessedAPICategoryUserDefaults` reason **CA92.1** (Inditalk's only first-party required-reason API). Auto-bundled; verified present in the built `.app`. | App Privacy "nutrition label" answers in App Store Connect. |
| **Firebase config safety** | `project.yml` now `excludes` + `buildPhase: none` for `GoogleService-Info.SAMPLE.plist` — it is kept as docs but **no longer bundled** (verified absent from the built `.app`). Real `GoogleService-Info.plist` stays gitignored. | Register the iOS app + drop in the real plist; deploy backend. |
| **App icon / assets** | Added app-owned `Inditalk/Inditalk/Assets.xcassets` with `AppIcon.appiconset` + an original 1024² opaque (no-alpha) Inditalk placeholder icon. `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon` wired; verified `AppIcon` compiled into `Assets.car`. | Optional: replace placeholder with final brand icon. |
| **Signing / entitlements** | Added `Inditalk/Inditalk.entitlements` (`aps-environment`) wired via `CODE_SIGN_ENTITLEMENTS`. `DEVELOPMENT_TEAM` is now configurable via `${INDITALK_DEVELOPMENT_TEAM}` (no hardcoded team in source; the local team is preserved when set). | Enable Push/Background-Modes capabilities on the App ID; APNs key; `production` aps-environment for release. |
| **Account deletion** | Real `AccountSettingsView` with a typed-confirmation **Delete Account** flow → `AccountDeletionService`: clears push token, deletes caller-owned Firestore docs, deletes the Firebase Auth user, and wipes **all** local state (SwiftData, media, Keychain identity/prekeys, E2EE sessions, report outbox, privacy). Server-side deep cleanup via new `onUserDeleted` Cloud Function. | Verify end-to-end against live Firebase; moderation for retained data. |
| **UGC — report** | Replaced the toast-only stub with `ReportContactView` → `ReportService` + durable `ReportStore` outbox; delivers to a new Firestore `reports` collection (rules added). | Stand up moderation tooling/queue. |
| **UGC — block** | Block is now **enforced** locally: composer replaced by an "Unblock" bar, call buttons hidden, incoming calls from blocked peers suppressed (`CallCenter.isPeerBlocked`), and a store-level send backstop. | Server-side block enforcement (rule/Function) — see checklist. |
| **Placeholder / release copy** | Removed the "Not production-secure — reference build" banner from the UI (now a neutral version line; a `— debug build` suffix only under `#if DEBUG`). Placeholder settings screens replaced with real ones (Account, Help & Support with support/policy links, Storage, Notifications) or removed. Onboarding E2EE marketing softened to conservative wording pending audit. | Publish the linked legal/help pages. |
| **Backend hardening** | `firestore.rules`: call-signal reads restricted to the two call parties; added explicit `users/{uid}/keys` (fixes a pre-existing gap where prekey publish was denied), `users/{uid}/blocked`, and `reports` rules. `storage.rules`: chat-attachment writes made attributable (uid-in-path). TURN via `ICEServerConfig` (short-lived creds, never hardcoded). | Deploy rules; TURN server + ephemeral-cred endpoint; audit. |

### Files added
- `Inditalk/Inditalk/PrivacyInfo.xcprivacy`, `Inditalk/Inditalk/Inditalk.entitlements`
- `Inditalk/Inditalk/Assets.xcassets/` (+ `AppIcon.appiconset/AppIcon-1024.png`)
- `Inditalk/Inditalk/Features/Settings/AccountSettingsView.swift`, `ReportContactView.swift`, `SupportScreens.swift`
- `Inditalk/Inditalk/Services/Account/AccountDeletionService.swift`
- `Inditalk/Inditalk/Services/Safety/Report.swift`, `ReportStore.swift`, `ReportService.swift`
- `Inditalk/Inditalk/Services/Calling/ICEServerConfig.swift`
- `Inditalk/InditalkTests/AccountAndSafetyTests.swift` (6 new tests)
- `RELEASE_CHECKLIST.md`, `.xcodegen.env.sample`

### Files edited
- `project.yml`, `.gitignore`, `firestore.rules`, `storage.rules`, `functions/index.js`
- `Inditalk/Inditalk/Data/DataStore.swift` (block helpers, `wipeAllLocalData`), `Data/MediaStore.swift`
- `Inditalk/Inditalk/Services/Crypto/IdentityKeyManager.swift` (`deleteIdentity`), `E2EESessionStore.swift` (`clearAll`)
- `Inditalk/Inditalk/Services/Firebase/FirebaseSyncCoordinator.swift` (block resolver), `FirebaseStorageService.swift`
- `Inditalk/Inditalk/Services/Calling/CallCenter.swift`, `WebRTCMediaSession.swift`
- `Inditalk/Inditalk/Features/Settings/SettingsView.swift`, `ContactDetailView.swift`
- `Inditalk/Inditalk/Features/ChatDetail/ChatDetailView.swift`, `ChatDetailViewModel.swift`
- `Inditalk/Inditalk/Features/Onboarding/OnboardingView.swift`
- `SETUP.md`

## Verification Run

Original analysis commands (targets/scheme) still hold. After the local fixes above, the
project was regenerated and re-verified:

- `INDITALK_DEVELOPMENT_TEAM=… xcodegen generate`: regenerated `Inditalk.xcodeproj` from the
  updated `project.yml` (all new files included; SAMPLE plist excluded from Resources;
  `CODE_SIGN_ENTITLEMENTS`, `ASSETCATALOG_COMPILER_APPICON_NAME`, and the substituted
  team all present).
- `xcodebuild build-for-testing -project Inditalk/Inditalk.xcodeproj -scheme Inditalk -destination 'generic/platform=iOS Simulator' -derivedDataPath Inditalk/.derivedData`:
  **`** TEST BUILD SUCCEEDED **`**.
- `xcodebuild test-without-building -project Inditalk/Inditalk.xcodeproj -scheme Inditalk -destination 'id=92512AB1-6663-44DD-BE33-7173F03C8912' -derivedDataPath Inditalk/.derivedData`:
  **passed; 42 tests, 0 failures** (was 36; +6 in `AccountAndSafetyTests`).
- Built `.app` inspection: `PrivacyInfo.xcprivacy` bundled ✓, `AppIcon` in `Assets.car`
  ✓, `GoogleService-Info.SAMPLE.plist` absent ✓, `Inditalk.entitlements` not bundled ✓,
  VoIP/audio/remote-notification background modes intact ✓.
- `node --check functions/index.js`: syntax OK.

Current package pins resolved by Xcode include Firebase `11.15.0` and WebRTC
`150.0.0`.

### Risky assumptions / notes
- **Signing team.** The local generated project had team `JR6W8P6Z8N`. It is treated as
  the user's intentional local value and preserved via `INDITALK_DEVELOPMENT_TEAM` during
  regeneration; it is **not** written into any committed file. Simulator builds don't
  sign, so this doesn't affect the verification above.
- **`aps-environment`.** Set to `development` in source. Simulator ad-hoc signing omits
  it (expected); it applies on device/distribution and must be `production` for release.
- **Block/report mapping.** Local block state is keyed by the app's domain UUIDs. Full
  server-side enforcement needs the peer's Firebase uid mapping — enforced locally now,
  documented as a backend item.
- **`onUserDeleted`** uses the v1 auth trigger (`firebase-functions/v1`); it must be
  deployed for server-side deletion cleanup and requires the Blaze plan. Client-side
  deletion + local wipe work regardless.
- The placeholder **app icon** is original Inditalk artwork but intended as a stand-in.

## What Is Already In Good Shape

- Native SwiftUI iOS app with an Xcode project and a documented XcodeGen manifest.
- Bundle ID is consistent: `chat.cove.app` in `project.yml` and built app metadata.
- Minimum iOS target is `17.0`.
- App builds and unit tests pass in local mode.
- Firebase, Firestore, Storage, FCM, WebRTC, CallKit, PushKit, and E2EE design docs
  are already present.
- Permission usage strings exist for camera, microphone, photos, contacts, Face ID,
  and location in `Inditalk/Info.plist`.
- Background modes for VoIP, audio, and remote notifications exist in
  `Inditalk/Info.plist`.

## P0 Blockers Before App Store Submission

> **Update (2026-07-24):** the in-repo portions of items 4, 5, 7, 8, and 9 below, plus
> the entitlements wiring in item 2 and the sample-plist bundling in item 3, are now
> **fixed** — see "Local Fixes Applied" above. The residual work in each item is the
> external/account-side part (registration, credentials, deploy, hosted pages, audit).

### 1. Create final App Store Connect record and confirm bundle ownership

Needed:

- Apple Developer Program membership.
- App Store Connect app record for `Inditalk`.
- Bundle ID `chat.cove.app` registered in Certificates, Identifiers and Profiles.
- SKU, primary language, category, age rating, copyright, support URL, privacy
  policy URL, review contact, and review notes.
- Confirm iPhone-only is intentional. `TARGETED_DEVICE_FAMILY` is `1`.

Evidence:

- Bundle ID is set in `project.yml:59`.
- App Store Connect requires the bundle ID in the app record to match the Xcode
  project bundle ID.

### 2. Finalize signing and entitlements

Needed:

- Set the correct Apple development team in the source-of-truth project config.
  `project.yml` still has `DEVELOPMENT_TEAM: ""`, while the generated project has a
  local team value. Regenerating the project can erase that local value.
- Create and commit a production-safe entitlements file, for example
  `Inditalk/Inditalk.entitlements`, then wire it with `CODE_SIGN_ENTITLEMENTS`.
- Enable capabilities in the Apple Developer portal and Xcode:
  Push Notifications, Background Modes, and any required keychain access group.
- For VoIP calls, make sure PushKit usage is approved by function: incoming calls
  must report to CallKit immediately.

Evidence:

- `project.yml:36` has an empty `DEVELOPMENT_TEAM`.
- `project.yml:64-66` says entitlements still need to be created.
- No `*.entitlements` file exists in the source tree.

### 3. Replace Firebase sample config with the real production app config

Needed:

- Register the iOS app in Firebase for bundle ID `chat.cove.app`.
- Add the real `GoogleService-Info.plist` to `Inditalk/Resources/` and the app target.
- Remove `GoogleService-Info.SAMPLE.plist` from the app target before release.
- Enable Firebase Phone Auth, Firestore, Storage, FCM, and upload APNs auth key.
- Deploy Firestore rules, indexes, Storage rules, and Functions.
- Add call/VoIP push fanout, not only message push fanout.

Evidence:

- The real `GoogleService-Info.plist` is absent.
- The app switches to Firebase only when the real file exists:
  `Inditalk/Inditalk/App/AppConfig.swift:19-25`.
- The sample plist explicitly says it is not real config:
  `Inditalk/Inditalk/Resources/GoogleService-Info.SAMPLE.plist:17-18`.
- The built simulator app currently includes `GoogleService-Info.SAMPLE.plist`.

### 4. Add production AppIcon and source asset catalog

Needed:

- Add an app-owned `Assets.xcassets` with `AppIcon`.
- Include all required app icon sizes through Xcode's asset catalog workflow.
- Verify archive validation after adding the icon.

Evidence:

- The project references `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.
- No app-source `*.xcassets` directory exists under `Inditalk/Inditalk`.
- Build success did not prove App Store icon readiness.

### 5. Add app target privacy manifest

Needed:

- Add `PrivacyInfo.xcprivacy` to the app target.
- Declare Inditalk's own required-reason API usage. At minimum, the app uses
  `UserDefaults.standard`, so declare:
  `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1` if usage remains
  app-local.
- Keep third-party SDK manifests from Firebase/WebRTC, but do not rely on them to
  cover Inditalk's own code.

Evidence:

- No app-source `PrivacyInfo.xcprivacy` exists.
- Inditalk writes and reads privacy settings through `UserDefaults.standard` in
  `Inditalk/Inditalk/Data/DataStore.swift:489-495`.
- Apple rejects submissions that use required-reason APIs without valid privacy
  manifest declarations.

### 6. Complete App Privacy responses and privacy policy

Needed:

- Publish a privacy policy URL.
- Complete App Store Connect App Privacy answers for Inditalk and third-party SDKs.
- Likely data categories to review with counsel/product:
  phone number, contacts/contact hashes, user ID, device/push token identifiers,
  user-generated messages/media/calls metadata, audio/photos/videos when uploaded,
  diagnostics if added, and any support data.
- Be precise that Firebase stores E2EE ciphertext where true, but avoid claiming
  the server cannot access all metadata.

Apple-specific note:

- Apple's App Privacy guidance explicitly says private in-app messaging should
  declare non-SMS messages/text messages where applicable.

### 7. Implement account deletion inside the app

Needed:

- Add a visible `Delete Account` flow under Settings > Account.
- Delete Firebase Auth account, Firestore user profile, device tokens, prekeys,
  storage objects where applicable, and server-side references not legally retained.
- Explain retention and timing to the user.
- Add backend support if deletion cannot be completed entirely client-side.

Evidence:

- Settings has an `Account` row, but it routes to placeholder content:
  `Inditalk/Inditalk/Features/Settings/SettingsView.swift:30` and
  `Inditalk/Inditalk/Features/Settings/SettingsView.swift:120-127`.
- Apple requires apps that support account creation to let users initiate account
  deletion in the app.

### 8. Finish user-generated-content safety controls

Needed:

- Real server-backed report flow.
- Real server-backed block enforcement for messages, calls, invites, and group
  interactions.
- Published support/contact information.
- Terms/community standards and moderation response process.
- Filtering or abuse prevention appropriate to a private messaging app.

Evidence:

- Contact report currently only shows a toast:
  `Inditalk/Inditalk/Features/Settings/ContactDetailView.swift:102-108`.
- Block state is local privacy state only:
  `Inditalk/Inditalk/Data/DataStore.swift:376-377` and
  `Inditalk/Inditalk/Models/User.swift:65-70`.
- Firestore/Storage rules do not currently model a block/report abuse workflow.

### 9. Remove placeholder and reference-build content

Needed:

- Replace or hide placeholder Settings screens before review.
- Remove "coming soon" controls from production paths unless the unavailable feature
  is explicitly not marketed.
- Remove "Not production-secure - reference build" from the public app, but only
  after the security work is actually complete.
- Align onboarding and metadata claims with the true security posture.

Evidence:

- Multiple Settings rows route to `PlaceholderSettingDetail`.
- Footer copy says `Not production-secure - reference build`:
  `Inditalk/Inditalk/Features/Settings/SettingsView.swift:57`.
- README and setup docs also say not to ship as-is:
  `README.md:14-16`, `SETUP.md:11-12`.
- Onboarding currently markets "end-to-end encryption":
  `Inditalk/Inditalk/Features/Onboarding/OnboardingView.swift:49`.

### 10. Resolve production security and privacy gaps before public launch

Needed:

- Independent security review of the crypto, key lifecycle, Firebase rules, storage
  authorization, push/call signaling, and deletion flows.
- Persist ratchet state across launches; implement one-time-prekey consumption and
  responder auto-establishment.
- Verify signed prekey signatures.
- Review Storage authorization and call signaling rules.

Evidence:

- `SETUP.md:122-128` lists crypto/calling items still required before anyone relies
  on the app.
- Storage allows any signed-in user to read encrypted chat blobs:
  `storage.rules:22-25`.
- Firestore call signals allow any signed-in user to read signal docs:
  `firestore.rules:71-74`.
- WebRTC currently uses public STUN only and has a TURN placeholder:
  `Inditalk/Inditalk/Services/Calling/WebRTCMediaSession.swift:143-148`.

## P1 Needed For A Reliable Launch

- Add TURN service for real-world voice/video reliability.
- Add VoIP push flow for incoming calls, separate from generic FCM message pushes.
- Test on real devices with production APNs, Firebase Phone Auth, background calls,
  push permissions, cold start, and denied permissions.
- Archive a Release build and validate/upload through Xcode Organizer or
  `xcodebuild archive` plus App Store upload tooling.
- Add App Store screenshots. For iPhone apps, App Store Connect accepts one to ten
  screenshots per localization and has current 6.9-inch requirements.
- Prepare App Review notes with:
  demo phone number/test OTP or reviewer instructions,
  backend availability,
  moderation/contact process,
  encryption/export notes,
  any feature limitations.
- Add Support URL, Terms URL, and Privacy Policy URL.
- Decide age rating and content moderation posture.
- Decide monetization. If any paid digital features are added, use In-App Purchase
  unless a guideline exception applies.
- Add release monitoring: crash reporting, server logs, alerting, Firebase budget
  controls, abuse/rate-limit monitoring.
- Clean release repo hygiene: do not commit build artifacts, local derived data,
  secrets, provisioning profiles, or sample Firebase config in the app target.

## P2 Recommended Before Scale

- Add CI for build, unit tests, privacy-manifest validation, and Firebase rules tests.
- Add UI tests for onboarding, send/receive, account deletion, report/block, and
  permission-denied flows.
- Add accessibility audit for dynamic type, VoiceOver labels, contrast, and reduced
  motion.
- Add localization plan if launching outside English.
- Add legal review for export compliance and privacy policy claims.
- Consider App Attest/App Check hardening for OTP abuse and backend abuse.
- Add data retention policy and administrative deletion tooling.

## Suggested Deployment Sequence

1. Create App Store Connect app and register `chat.cove.app`.
2. Add real signing team, entitlements, and capabilities to the source project config.
3. Add `Assets.xcassets` with `AppIcon`.
4. Add `PrivacyInfo.xcprivacy` for Inditalk's own API use.
5. Add real Firebase config, remove sample plist from the target, and deploy backend.
6. Implement account deletion, real report flow, and server-enforced blocking.
7. Remove placeholders and align in-app copy with production truth.
8. Add TURN/VoIP push and test calls/messages on real devices.
9. Run Release archive validation and upload to TestFlight.
10. Run internal TestFlight, then external TestFlight/App Review beta with review
    notes and test credentials.
11. Complete App Privacy, screenshots, metadata, age rating, export compliance, and
    submit for App Review.

## Official Apple References Checked

- App Store Connect submission flow:
  https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/
- Xcode SDK and upload/deployment target matrix:
  https://developer.apple.com/xcode/system-requirements
- Privacy manifests:
  https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk
- Required-reason APIs:
  https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- Required-reason values, including `CA92.1` for app-local UserDefaults:
  https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons
- App Privacy details:
  https://developer.apple.com/app-store/app-privacy-details/
- Manage App Privacy in App Store Connect:
  https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy
- App Review Guidelines:
  https://developer.apple.com/app-store/review/guidelines/
- Account deletion:
  https://developer.apple.com/support/offering-account-deletion-in-your-app
- Screenshot specifications:
  https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/

## Bottom Line

Inditalk is technically alive: it builds and its current tests pass. It is not yet an
App Store-ready product. The shortest path to TestFlight is signing + icon + privacy
manifest + real Firebase config. The shortest responsible path to App Store public
release adds account deletion, UGC moderation, complete backend/push/calling flows,
truthful metadata, and security review.
