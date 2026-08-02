# Inditalk — App Store release checklist (external / manual work)

Everything in this file needs an Apple/Firebase account, a console, a legal page, or a
human decision — it can't be fixed in the repo. The in-code readiness work (privacy
manifest, app icon, entitlements wiring, account deletion, report/block, rules
hardening, copy cleanup) is already done; see `APP_STORE_DEPLOYMENT_REPORT.md` for the
"what's fixed" list and exact build/test results.

Legend: **[apple]** Apple Developer / App Store Connect · **[firebase]** Firebase
console/CLI · **[legal]** counsel/product · **[device]** on real hardware.

---

## 1. Signing & capabilities [apple]
- [ ] Apple Developer Program membership active.
- [ ] Register App ID / bundle id **`chat.cove.app`** in Certificates, Identifiers &
      Profiles.
- [ ] Set your team before generating the project (keeps it out of source):
      `INDITALK_DEVELOPMENT_TEAM=YOURTEAM xcodegen generate` (or `.xcodegen.env`, see sample).
- [ ] Enable capabilities on the App ID **and** in Xcode → Signing & Capabilities:
  - [ ] **Push Notifications** (backs `aps-environment` in `Inditalk/Inditalk.entitlements`;
        also required for VoIP push).
  - [ ] **Background Modes**: Voice over IP, Audio, Remote notifications (already in
        `Info.plist`).
- [ ] For an App Store / production build, ensure the `aps-environment` entitlement is
      `production` (Xcode sets this when archiving with a Distribution profile that has
      Push; or maintain a Release-only entitlements file).
- [ ] CallKit + PushKit need **no** extra entitlement key — do not add one.
- [ ] Add `keychain-access-groups` to `Inditalk/Inditalk.entitlements` **only** if you ship a
      Notification Service Extension that shares Inditalk's Keychain.

## 2. APNs / push [apple][firebase]
- [ ] Create an **APNs Auth Key (.p8)** in the Apple Developer portal. Never commit it
      (already gitignored: `*.p8`, `AuthKey_*.p8`).
- [ ] Upload the .p8 to Firebase → Project settings → Cloud Messaging.
- [ ] Decide/implement a **VoIP push** path for incoming calls (separate from the FCM
      message push in `functions/index.js`). PushKit + a call-specific payload; the app
      must report the incoming call to CallKit immediately on receipt.

## 3. Firebase backend [firebase]
- [ ] Register the iOS app (bundle id `chat.cove.app`) in project **cove-7f31f**.
- [ ] Download the **real `GoogleService-Info.plist`** → drop it in `Inditalk/Resources/`.
      XcodeGen bundles it automatically; it is gitignored so it won't be committed. Do
      **not** edit `GoogleService-Info.SAMPLE.plist` — it is documentation only and is
      no longer bundled into the app.
- [ ] Enable **Phone** auth (add test numbers for the simulator).
- [ ] Create **Firestore** (production mode) and **Storage**.
- [ ] Deploy rules/indexes/functions (always pin the project):
  ```bash
  firebase deploy --project cove-7f31f --only firestore:rules,firestore:indexes,storage,functions
  ```
  This publishes the hardened rules (call-signal reads limited to call parties; keys /
  blocked / reports collections), and the functions: `onNewMessage` (push fanout) and
  `onUserDeleted` (server-side account-deletion cleanup). Functions require the **Blaze**
  plan.

## 4. Account deletion — verify end to end [firebase][device]
- [ ] Confirm the in-app flow (Settings → Account → **Delete Account**) deletes the
      Firebase Auth user and that `onUserDeleted` removes the profile, keys, chat
      membership, and Storage objects.
- [ ] Confirm re-auth handling: if `user.delete()` returns *requires-recent-login*, the
      app tells the user to sign in again (already handled) — test the path.

## 5. UGC safety — moderation operations [firebase][legal]
- [ ] Stand up moderation for the `reports` collection (a console view, a Function that
      alerts moderators, or an admin tool). Rules already block client reads.
- [ ] Decide **server-side block enforcement**. Client-side block (messages + incoming
      calls) is enforced in-app; server-side needs one of:
  - a message-create rule that also checks the recipient's `users/{uid}/blocked/*`
    (adds a `get()` per write; feasible for direct chats), or
  - a Cloud Function that rejects/drops messages & call docs from blocked senders.
- [ ] Publish **support contact** + **Community Guidelines** + **Terms** (the app links
      to `inditalk.com/...` — see `InditalkLinks`). Define a moderation response process.

## 6. Calls / TURN [device][firebase]
- [ ] Stand up a **TURN** server (coturn or a provider). Feed **short-lived** credentials
      to `ICEServerConfig.shared.setTURN(...)` after sign-in — never hardcode TURN
      secrets in the app. Until then, calls are STUN-only (LAN/simulator only).
- [ ] For group calls, add an **SFU** (mesh doesn't scale past ~4).
- [ ] Test on real devices: production APNs, background calls, cold start, denied
      permissions.

## 7. App Store Connect metadata [apple][legal]
- [ ] Create the App Store Connect app record; SKU, primary language, category.
- [ ] **App Privacy** answers (the nutrition label — separate from the bundled
      `PrivacyInfo.xcprivacy`): phone number, contacts/contact hashes, user id, device/
      push tokens, user content (messages/media/calls metadata), etc. Note that E2EE
      bodies are ciphertext but metadata is visible to the server.
- [ ] **Privacy Policy URL**, **Support URL**, **Terms URL** (host the pages).
- [ ] Age rating and content-moderation posture for a UGC messaging app.
- [ ] Screenshots (6.9" + any required sizes), 1–10 per localization.
- [ ] App Review notes: demo phone number / test OTP, backend availability, moderation
      & contact process, encryption/export-compliance notes, known limitations.
- [ ] Export compliance (encryption) declaration.
- [ ] Confirm iPhone-only is intentional (`TARGETED_DEVICE_FAMILY = 1`).

## 8. Security review (before "secure/private messenger" claims) [legal]
- [ ] Independent audit of crypto, key lifecycle, Firestore/Storage rules, call
      signaling, push, and the deletion flow.
- [ ] Crypto hardening still open (see `SETUP.md` §9): persist ratchet state across
      launches, one-time-prekey consumption, responder auto-establishment, verify
      `signedPreKeySignature`.
- [ ] Do not restore any "end-to-end encryption" marketing claim in-app until the audit
      is complete. In-app copy has been made conservative pending the audit.

## 9. Release build validation [apple]
- [ ] `xcodebuild archive` (Release) → validate in Organizer / `xcrun altool` or
      `notarytool`-equivalent App Store upload.
- [ ] Internal TestFlight → external TestFlight → submit for review.
