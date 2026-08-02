/**
 * Inditalk Cloud Functions.
 *
 * Message pushes (below): on every new message document, send an FCM push to the other
 * chat participants. The payload carries ONLY a generic nudge + the chatId — never the
 * message body, which is end-to-end encrypted ciphertext the server can't read. The app
 * fetches and decrypts the actual content locally (a Notification Service Extension can
 * decrypt a preview on-device if desired).
 *
 * Also exported from this codebase:
 *   getTurnCredentials  (./turn.js)  short-lived TURN credentials for WebRTC calls
 *   onCallInvite        (./voip.js)  APNs VoIP push so incoming calls ring in the
 *                                    background / on the lock screen
 *
 * Requires the Blaze (pay-as-you-go) plan. Deploy:
 *   firebase deploy --project cove-7f31f --only functions
 */

const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { setGlobalOptions } = require("firebase-functions/v2");
const functionsV1 = require("firebase-functions/v1"); // auth triggers are v1-only
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const { loadPushTargets, dropPushToken } = require("./devices");

initializeApp();
setGlobalOptions({ region: "us-central1", maxInstances: 10 });

const db = getFirestore();

// Calling infrastructure. Both modules read their config from env/secrets and no-op
// (logging a warning) when it isn't provisioned, so this codebase deploys unchanged
// on a project that hasn't set up TURN or APNs yet.
exports.getTurnCredentials = require("./turn").getTurnCredentials;
exports.onCallInvite = require("./voip").onCallInvite;

exports.onNewMessage = onDocumentCreated(
  "chats/{chatId}/messages/{messageId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;

    const message = snap.data();
    const chatId = event.params.chatId;

    // Load the parent chat to find participants + a display title.
    const chatSnap = await db.doc(`chats/${chatId}`).get();
    const chat = chatSnap.data();
    if (!chat) return;

    const recipients = (chat.participantIds || []).filter(
      (uid) => uid !== message.senderId
    );
    if (recipients.length === 0) return;

    // Collect each recipient's FCM tokens (skip those who haven't registered one).
    // Tokens live in the owner-private users/{uid}/privateDevices subcollection — one
    // document per install, so a user signed in on two devices gets both. The legacy
    // profile field is still read as a fallback (see functions/devices.js).
    const tokenOwners = []; // { uid, token, target }
    await Promise.all(
      recipients.map(async (uid) => {
        const targets = await loadPushTargets(db, uid, "fcmToken");
        for (const target of targets) tokenOwners.push({ uid, token: target.token, target });
      })
    );
    if (tokenOwners.length === 0) return;

    const response = await getMessaging().sendEachForMulticast({
      tokens: tokenOwners.map((t) => t.token),
      notification: {
        title: chat.title || "New message",
        body: "You have a new message",
      },
      data: { chatId, type: "message" },
      apns: {
        payload: { aps: { sound: "default", "mutable-content": 1, badge: 1 } },
      },
    });

    // Prune tokens the FCM service reports as unregistered/invalid.
    const stale = [];
    response.responses.forEach((r, i) => {
      const code = r.error && r.error.code;
      if (
        code === "messaging/registration-token-not-registered" ||
        code === "messaging/invalid-registration-token"
      ) {
        stale.push(tokenOwners[i]);
      }
    });
    await Promise.all(
      stale.map((owner) => dropPushToken(db, owner.uid, owner.target, "fcmToken"))
    );

    console.log(
      `chat ${chatId}: sent ${response.successCount}/${tokenOwners.length}, pruned ${stale.length}`
    );
  }
);

/**
 * Server-side account deletion cleanup.
 *
 * Fires when a Firebase Auth user is deleted (the app deletes the Auth user from the
 * in-app "Delete Account" flow — see AccountDeletionService). Performs the admin-only
 * cleanup the client can't do under the security rules:
 *   - recursively deletes the user profile doc + its keys/blocked subcollections,
 *   - removes the user from every chat (deleting chats that drop to <= 1 member),
 *   - deletes the user's receipts/typing docs in the chats they were in,
 *   - deletes the user's Storage objects (avatar + their chat-attachment folders).
 *
 * Auth triggers are only available in the 1st-gen API (firebase-functions/v1).
 */
exports.onUserDeleted = functionsV1.auth.user().onDelete(async (user) => {
  const uid = user.uid;

  // 1. Recursively delete the user document tree (profile + keys + blocked).
  try {
    await db.recursiveDelete(db.collection("users").doc(uid));
  } catch (e) {
    console.error(`onUserDeleted: users/${uid} delete failed`, e);
  }

  // 2. Detach from chats + delete per-chat owned docs and attachments.
  const chats = await db
    .collection("chats")
    .where("participantIds", "array-contains", uid)
    .get();

  for (const doc of chats.docs) {
    const chatId = doc.id;
    const remaining = (doc.get("participantIds") || []).filter((p) => p !== uid);
    try {
      if (remaining.length <= 1) {
        // 1:1 (or now-empty) chat: remove the whole thing, messages included.
        await db.recursiveDelete(doc.ref);
      } else {
        await doc.ref.update({ participantIds: FieldValue.arrayRemove(uid) });
        await Promise.all([
          doc.ref.collection("receipts").doc(uid).delete(),
          doc.ref.collection("typing").doc(uid).delete(),
        ]);
      }
      // Delete the user's encrypted attachments for this chat.
      await getStorage()
        .bucket()
        .deleteFiles({ prefix: `chats/${chatId}/${uid}/` });
    } catch (e) {
      console.error(`onUserDeleted: chat ${chatId} cleanup failed`, e);
    }
  }

  // 3. Delete the user's avatar objects.
  try {
    await getStorage().bucket().deleteFiles({ prefix: `avatars/${uid}/` });
  } catch (e) {
    console.error(`onUserDeleted: avatars/${uid} delete failed`, e);
  }

  console.log(`onUserDeleted: cleaned up ${uid} across ${chats.size} chat(s)`);
});
