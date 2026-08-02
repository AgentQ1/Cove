/**
 * Inditalk Cloud Functions — device push-token lookup.
 *
 * Push tokens used to live on the profile document (`users/{uid}.voipToken` /
 * `.fcmToken`), which every signed-in user can read. A token is not a credential on its
 * own — sending to it needs Inditalk's APNs key — but it is a stable per-install identifier
 * that lets any account track another user's devices, so it does not belong in a
 * world-readable document. Tokens now live at:
 *
 *   users/{uid}/privateDevices/{deviceId}
 *     voipToken       string?   PushKit token (hex), absent until PushKit issues one
 *     fcmToken        string?   FCM registration token for ordinary message pushes
 *     apnsEnvironment "development" | "production"
 *     platform        "ios"
 *     bundleId        string
 *     updatedAt       timestamp
 *
 * Rules make that subcollection owner-only; the Admin SDK used here bypasses rules.
 *
 * `apnsEnvironment` is recorded PER DEVICE because APNs is environment-split: a token
 * minted by a Debug build (aps-environment=development) is only valid against
 * api.sandbox.push.apple.com, and a TestFlight token only against api.push.apple.com.
 * A single global APNS_USE_SANDBOX flag makes it impossible to test both builds at once
 * — whichever one doesn't match the flag silently stops ringing. The flag is still read,
 * but only as the fallback for tokens registered before this field existed.
 *
 * Every function that pushes to a user goes through here so the legacy fallback and the
 * pruning rules stay in one place.
 */

const { FieldValue } = require("firebase-admin/firestore");

/** Subcollection holding one document per installed device. */
const DEVICES = "privateDevices";

/**
 * An APNs device token is hex, and it is interpolated straight into the request path
 * (`/3/device/<token>`). Clients write their own token, so this is not a privilege
 * boundary — but a token containing a slash or whitespace would produce a malformed
 * HTTP/2 request rather than an honest APNs rejection, and that is worth refusing here
 * instead of debugging later.
 */
const APNS_TOKEN_PATTERN = /^[0-9a-fA-F]{32,200}$/;

/**
 * Normalize one device document into a push target.
 *
 * Exported for unit tests — pure, no Firestore access.
 *
 * @param {{id: string, data: object}} doc
 * @param {"voipToken"|"fcmToken"} field
 * @param {boolean} defaultSandbox fallback when the doc predates apnsEnvironment
 * @returns {{deviceId: string, token: string, sandbox: boolean, legacy: boolean}|null}
 */
function toTarget(doc, field, defaultSandbox) {
  const token = doc.data && doc.data[field];
  if (typeof token !== "string" || token.length === 0) return null;
  // FCM tokens go through the Admin SDK (not a URL) and use a wider alphabet, so only
  // the APNs one is shape-checked.
  if (field === "voipToken" && !APNS_TOKEN_PATTERN.test(token)) {
    console.warn(`devices: ignoring malformed VoIP token on device ${doc.id}`);
    return null;
  }
  const environment = doc.data.apnsEnvironment;
  const sandbox =
    environment === "development" ? true : environment === "production" ? false : defaultSandbox;
  return { deviceId: doc.id, token, sandbox, legacy: false };
}

/**
 * De-duplicate targets by token. The same device can appear twice when an install is
 * restored onto a new device id, and APNs charges per send.
 * @param {Array<{token: string}>} targets
 */
function dedupe(targets) {
  const seen = new Set();
  return targets.filter((t) => {
    if (seen.has(t.token)) return false;
    seen.add(t.token);
    return true;
  });
}

/**
 * Every device of `uid` that can receive `field` pushes.
 *
 * Falls back to the legacy profile field when the user has no device documents yet, so
 * an install that hasn't been updated still rings. Legacy targets are marked so the
 * pruning path knows to clear the profile field rather than a device document.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} uid
 * @param {"voipToken"|"fcmToken"} field
 * @param {boolean} defaultSandbox
 * @returns {Promise<Array<{deviceId: string, token: string, sandbox: boolean, legacy: boolean}>>}
 */
async function loadPushTargets(db, uid, field, defaultSandbox = true) {
  const snapshot = await db.collection(`users/${uid}/${DEVICES}`).get();
  const targets = snapshot.docs
    .map((d) => toTarget({ id: d.id, data: d.data() || {} }, field, defaultSandbox))
    .filter(Boolean);
  if (targets.length > 0) return dedupe(targets);

  // Backward compatibility: a client that hasn't migrated still publishes to the
  // profile. Remove this branch once no installs write there (see PushService.swift).
  const profile = await db.doc(`users/${uid}`).get();
  // Reuse toTarget so the legacy path gets the same shape validation as a device
  // document — a bad token is no more acceptable for coming from an older client.
  const legacy = toTarget({ id: "(profile)", data: { [field]: profile.get(field) } },
                          field, defaultSandbox);
  return legacy ? [{ ...legacy, legacy: true }] : [];
}

/**
 * Drop a token APNs/FCM reports as permanently dead.
 *
 * Deletes only the offending FIELD, not the whole device document: a device can hold
 * both a VoIP and an FCM token and only one of them may have gone stale.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} uid
 * @param {{deviceId: string, legacy: boolean}} target
 * @param {"voipToken"|"fcmToken"} field
 */
async function dropPushToken(db, uid, target, field) {
  const ref = target.legacy
    ? db.doc(`users/${uid}`)
    : db.doc(`users/${uid}/${DEVICES}/${target.deviceId}`);
  await ref.update({ [field]: FieldValue.delete() }).catch((error) => {
    // A device document deleted by a concurrent sign-out is not an error worth failing on.
    console.warn(`dropPushToken: ${uid}/${target.deviceId} ${field} not removed`, error.message);
  });
}

module.exports = {
  loadPushTargets,
  dropPushToken,
  toTarget,
  dedupe,
  DEVICES,
  APNS_TOKEN_PATTERN,
};
