/**
 * Inditalk Cloud Functions — VoIP push for incoming calls.
 *
 * Without this, a callee only rings while the app is in the FOREGROUND: the incoming
 * call is discovered by a Firestore snapshot listener, and iOS suspends those the
 * moment the app is backgrounded or the phone locks. The fix is an APNs **VoIP push**
 * (PushKit): it wakes a suspended or terminated app, and the app must immediately
 * report the call to CallKit — which is what makes the phone ring on the lock screen.
 *
 * Why raw APNs instead of FCM: FCM cannot address a PushKit token. VoIP pushes need
 * the `<bundle-id>.voip` APNs topic and the `apns-push-type: voip` header, sent over
 * APNs' HTTP/2 API with a provider token. So this speaks to APNs directly.
 *
 * Configuration (all server-side; the .p8 key must never reach a client):
 *   APNS_AUTH_KEY     secret   contents of the APNs auth key .p8 file, newlines intact
 *                              (firebase functions:secrets:set APNS_AUTH_KEY < AuthKey_XXX.p8)
 *   APNS_KEY_ID       env      the key's 10-character Key ID
 *   APNS_TEAM_ID      env      Apple Developer Team ID
 *   APNS_BUNDLE_ID    env      app bundle id (topic is this + ".voip")
 *   APNS_USE_SANDBOX  env      FALLBACK environment for tokens registered before the
 *                              client recorded its own (see below)
 *
 * APNs is environment-split: a token minted by a build entitled
 * `aps-environment=development` is only valid against the sandbox host, and a
 * TestFlight/App Store token only against the production host. A mismatch returns
 * BadDeviceToken and the callee simply never rings, with no client-side symptom.
 *
 * The environment is therefore recorded PER DEVICE at registration time
 * (users/{uid}/privateDevices/{deviceId}.apnsEnvironment) and each push goes to the host
 * that device's build was signed for. That is what lets a Debug install and a TestFlight
 * install of the same account both ring at the same time; APNS_USE_SANDBOX only decides
 * the fallback for devices that registered before the field existed.
 */

const http2 = require("http2");
const crypto = require("crypto");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { defineSecret, defineString, defineBoolean } = require("firebase-functions/params");
const { getFirestore } = require("firebase-admin/firestore");
const { loadPushTargets, dropPushToken } = require("./devices");

const APNS_AUTH_KEY = defineSecret("APNS_AUTH_KEY");
const APNS_KEY_ID = defineString("APNS_KEY_ID", { default: "" });
const APNS_TEAM_ID = defineString("APNS_TEAM_ID", { default: "" });
const APNS_BUNDLE_ID = defineString("APNS_BUNDLE_ID", { default: "chat.cove.app" });
const APNS_USE_SANDBOX = defineBoolean("APNS_USE_SANDBOX", { default: true });

const PRODUCTION_HOST = "https://api.push.apple.com";
const SANDBOX_HOST = "https://api.sandbox.push.apple.com";

/**
 * APNs rejects provider tokens older than 1 hour and throttles re-issuing more often
 * than every 20 minutes, so cache one per warm instance and refresh in between.
 */
const TOKEN_REFRESH_SECONDS = 45 * 60;
let cachedToken = null; // { jwt, issuedAt }

function base64url(input) {
  return Buffer.from(input)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/**
 * Build the ES256 JWT APNs uses instead of a certificate.
 *
 * Exported for unit tests — keep pure (clock passed in), so a test can verify the
 * header/claims and that the signature validates against the public key.
 *
 * @param {{key: string, keyId: string, teamId: string, nowSeconds: number}} args
 * @returns {string} signed JWT
 */
function providerToken({ key, keyId, teamId, nowSeconds }) {
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = base64url(JSON.stringify({ iss: teamId, iat: nowSeconds }));
  const signingInput = `${header}.${claims}`;
  // JOSE wants the raw R||S pair, not the ASN.1/DER encoding Node produces by default.
  const signature = crypto.sign("sha256", Buffer.from(signingInput), {
    key,
    dsaEncoding: "ieee-p1363",
  });
  return `${signingInput}.${base64url(signature)}`;
}

function cachedProviderToken({ key, keyId, teamId }) {
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (cachedToken && nowSeconds - cachedToken.issuedAt < TOKEN_REFRESH_SECONDS) {
    return cachedToken.jwt;
  }
  const jwt = providerToken({ key, keyId, teamId, nowSeconds });
  cachedToken = { jwt, issuedAt: nowSeconds };
  return jwt;
}

/** Give up on an unresponsive APNs connection rather than holding the function open. */
const APNS_REQUEST_TIMEOUT_MS = 10_000;

/** A ring is only useful right now, so it expires quickly rather than arriving late. */
const APNS_EXPIRATION_SECONDS = 30;

/**
 * The HTTP/2 headers that make this a VoIP push rather than an ordinary notification.
 *
 * Exported and pure so a test can pin them: `apns-push-type: voip`, the `.voip` topic
 * suffix and priority 10 are what PushKit requires. Get any of them wrong and APNs
 * accepts or rejects the request without the app ever being woken — the callee simply
 * never rings, with nothing to see on either device.
 *
 * @returns {object} headers for `ClientHttp2Session.request`
 */
function voipRequestHeaders({ deviceToken, topic, jwt, contentLength, nowSeconds }) {
  return {
    ":method": "POST",
    ":path": `/3/device/${deviceToken}`,
    authorization: `bearer ${jwt}`,
    "apns-topic": `${topic}.voip`,
    "apns-push-type": "voip",
    // Highest priority, and let it die rather than ring minutes after the caller gave up.
    "apns-priority": "10",
    "apns-expiration": String(nowSeconds + APNS_EXPIRATION_SECONDS),
    "content-type": "application/json",
    "content-length": contentLength,
  };
}

/**
 * POST one VoIP push to APNs.
 *
 * @returns {Promise<{status: number, reason: string|null}>} APNs status (200 = accepted)
 */
function postToAPNs({ host, deviceToken, topic, jwt, payload }) {
  return new Promise((resolve, reject) => {
    const client = http2.connect(host);
    client.on("error", reject);

    const body = Buffer.from(JSON.stringify(payload));
    const request = client.request(
      voipRequestHeaders({
        deviceToken,
        topic,
        jwt,
        contentLength: body.length,
        nowSeconds: Math.floor(Date.now() / 1000),
      })
    );

    let status = 0;
    let responseBody = "";
    request.on("response", (headers) => {
      status = headers[":status"];
    });
    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      responseBody += chunk;
    });
    request.on("error", (error) => {
      client.close();
      reject(error);
    });
    // Without this a stalled connection holds the whole function open until its own
    // timeout — long after the ring stopped being useful to anyone.
    request.setTimeout(APNS_REQUEST_TIMEOUT_MS, () => {
      request.close();
      client.close();
      reject(new Error(`APNs request timed out after ${APNS_REQUEST_TIMEOUT_MS}ms`));
    });
    request.on("end", () => {
      client.close();
      let reason = null;
      if (responseBody) {
        try {
          reason = JSON.parse(responseBody).reason || null;
        } catch (e) {
          reason = responseBody;
        }
      }
      resolve({ status, reason });
    });

    request.end(body);
  });
}

/** APNs reasons that mean this token is dead and should be dropped from the profile. */
const DEAD_TOKEN_REASONS = new Set(["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"]);

/**
 * Ring the callee's device when a call invite lands.
 *
 * Fires on creation of calls/{callId} — the same document CallCenter.placeCall writes
 * before it starts signaling, so the push and the WebRTC offer race in the right order:
 * the callee wakes, reports to CallKit, attaches its signals listener, and the buffered
 * offer is answered only once the user actually accepts.
 */
const onCallInvite = onDocumentCreated(
  { document: "calls/{callId}", secrets: [APNS_AUTH_KEY] },
  async (event) => {
    const snap = event.data;
    if (!snap) return;

    const call = snap.data();
    const callId = event.params.callId;
    // Only a fresh ring warrants waking a device; ignore docs created in any other state.
    if (call.state !== "ringing") return;
    if (!call.to || !call.from) return;

    const key = APNS_AUTH_KEY.value();
    const keyId = APNS_KEY_ID.value();
    const teamId = APNS_TEAM_ID.value();
    if (!key || !keyId || !teamId) {
      console.warn(`onCallInvite(${callId}): APNs not configured — skipping VoIP push`);
      return;
    }

    const db = getFirestore();

    // Blocked callers must not ring a locked phone. The client enforces this too, but
    // only on the foreground path — a VoIP push bypasses that listener entirely, so the
    // check has to happen here or blocking is unenforced exactly when it matters most.
    const blocked = await db.doc(`users/${call.to}/blocked/${call.from}`).get();
    if (blocked.exists) {
      console.log(`onCallInvite(${callId}): ${call.from} is blocked by ${call.to} — no push`);
      return;
    }

    // Every device the callee is signed in on, each with the APNs environment its build
    // was signed for. Tokens live in the owner-private privateDevices subcollection; the
    // profile field is read only as a fallback for installs that predate that.
    const [targets, callerSnap] = await Promise.all([
      loadPushTargets(db, call.to, "voipToken", APNS_USE_SANDBOX.value()),
      db.doc(`users/${call.from}`).get(),
    ]);

    if (targets.length === 0) {
      // Not fatal: an app in the foreground still rings via its Firestore listener.
      console.log(`onCallInvite(${callId}): ${call.to} has no VoIP token — foreground only`);
      return;
    }

    // The caller's name travels in the payload because a push-launched app may not have
    // finished restoring its local contact list before CallKit needs a name to display.
    // The client prefers its own locally resolved name when it has one.
    const payload = {
      callId,
      from: call.from,
      caller: callerSnap.get("displayName") || "Inditalk user",
      video: call.media === "video",
    };

    const jwt = cachedProviderToken({ key, keyId, teamId });
    const topic = APNS_BUNDLE_ID.value();

    // Ring every signed-in device in parallel; the first one answered ends the call for
    // the rest through the existing Firestore call-state path. Never log the token —
    // the device id is enough to correlate with the client's own log line.
    const results = await Promise.all(
      targets.map(async (target) => {
        try {
          const result = await postToAPNs({
            host: target.sandbox ? SANDBOX_HOST : PRODUCTION_HOST,
            deviceToken: target.token,
            topic,
            jwt,
            payload,
          });
          return { target, result };
        } catch (error) {
          console.error(
            `onCallInvite(${callId}): APNs request failed for device ${target.deviceId}`,
            error
          );
          return { target, result: null };
        }
      })
    );

    let delivered = 0;
    let pruned = 0;
    let unauthorized = false;
    for (const { target, result } of results) {
      if (!result) continue;
      if (result.status === 200) {
        delivered += 1;
        continue;
      }
      console.error(
        `onCallInvite(${callId}): APNs rejected device ${target.deviceId} ` +
          `(${result.status} ${result.reason}, ${target.sandbox ? "sandbox" : "production"})`
      );
      // A token APNs calls dead will never work again — drop it so we stop paying for
      // failed sends and so the client's next registration can replace it cleanly.
      if (result.status === 410 || DEAD_TOKEN_REASONS.has(result.reason)) {
        await dropPushToken(db, call.to, target, "voipToken");
        pruned += 1;
      }
      // A 403 is almost always a stale/incorrect provider token or a key that doesn't
      // match APNS_TEAM_ID — surface it loudly and re-mint on the next attempt.
      if (result.status === 403) unauthorized = true;
    }
    if (unauthorized) cachedToken = null;

    console.log(
      `onCallInvite(${callId}): VoIP push delivered to ${delivered}/${targets.length} ` +
        `device(s) of ${call.to}${pruned ? `, pruned ${pruned} dead token(s)` : ""}`
    );
  }
);

module.exports = {
  onCallInvite,
  providerToken,
  base64url,
  voipRequestHeaders,
  DEAD_TOKEN_REASONS,
  SANDBOX_HOST,
  PRODUCTION_HOST,
};
