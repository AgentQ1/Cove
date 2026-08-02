/**
 * Inditalk Cloud Functions — short-lived TURN credentials.
 *
 * STUN alone cannot connect a call between two symmetric NATs (common on mobile
 * carriers and corporate Wi-Fi); those calls need a TURN relay. TURN requires
 * credentials, and a long-lived TURN username/password must NEVER ship inside the app
 * binary — anyone can extract it and use the relay for free. So the app asks this
 * function for credentials that expire within the hour, and the shared secret stays
 * server-side in Secret Manager.
 *
 * Protocol: the standard TURN REST API (draft-uberti-behave-turn-rest-00), which is
 * what coturn's `use-auth-secret` / `static-auth-secret` mode implements and what most
 * hosted TURN providers accept:
 *
 *   username   = "<unix-expiry>:<user id>"
 *   credential = base64( HMAC-SHA1( shared secret, username ) )
 *
 * The TURN server derives the same HMAC from its copy of the secret, so no credential
 * database and no round trip to us is involved at connect time.
 *
 * Configuration (never hardcode any of this):
 *   TURN_SECRET       secret   the TURN server's static-auth-secret
 *                              (firebase functions:secrets:set TURN_SECRET)
 *   TURN_URLS         env      comma-separated relay URLs, e.g.
 *                              "turn:turn.example.net:3478?transport=udp,
 *                               turn:turn.example.net:3478?transport=tcp,
 *                               turns:turn.example.net:5349?transport=tcp"
 *   TURN_TTL_SECONDS  env      credential lifetime (default 3600)
 *
 * Put the non-secret values in functions/.env (see .env.sample). With TURN_URLS or
 * TURN_SECRET unset this returns an empty server list and clients stay on STUN — the
 * documented fallback, not an error.
 */

const crypto = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret, defineString, defineInt } = require("firebase-functions/params");

const TURN_SECRET = defineSecret("TURN_SECRET");
const TURN_URLS = defineString("TURN_URLS", { default: "" });
const TURN_TTL_SECONDS = defineInt("TURN_TTL_SECONDS", { default: 3600 });

/** Longest credential lifetime we will hand out, whatever the config says. */
const MAX_TTL_SECONDS = 12 * 3600;

/**
 * A relay URL WebRTC will accept: scheme, host, optional :port, optional
 * ?transport=udp|tcp. Anything else is a configuration mistake, and handing it to the
 * client is worse than dropping it — libwebrtc rejects the whole RTCIceServer entry, so
 * one typo can cost every relay in the grant.
 *
 *   turn:host:3478?transport=udp   turns:host:5349?transport=tcp   stun:host:3478
 */
const TURN_URL_PATTERN =
  /^(turn|turns|stun|stuns):[A-Za-z0-9._-]+(:\d{1,5})?(\?transport=(udp|tcp))?$/;

/**
 * Split and validate the configured URL list. Tolerates whitespace and trailing commas
 * so a multi-line .env entry works, and drops entries that aren't usable relay URLs
 * (logging each, because a silently missing relay is the hardest kind of call bug).
 *
 * @param {string} raw
 * @returns {string[]}
 */
function parseTurnUrls(raw) {
  const entries = String(raw || "")
    .split(",")
    .map((u) => u.trim())
    .filter((u) => u.length > 0);

  return entries.filter((url) => {
    if (TURN_URL_PATTERN.test(url)) return true;
    // Redact any userinfo before logging: credentials never belong in a relay URL (that
    // is one of the reasons the entry is being rejected), but if someone put them there
    // anyway, echoing them into Cloud Logging would be the worse mistake.
    console.warn(
      `getTurnCredentials: ignoring malformed TURN URL in TURN_URLS: "${url.replace(/\/\/[^@]*@/, "//***@").replace(/^([a-z]+:)[^@/]*@/i, "$1***@")}"`
    );
    return false;
  });
}

/**
 * Mint one ephemeral username/credential pair.
 *
 * Exported for unit tests (functions/test/turn.test.js) — keep it pure: no clock or
 * config reads beyond the arguments, so a test can pin `nowSeconds`.
 *
 * @param {{secret: string, uid: string, ttlSeconds: number, nowSeconds: number}} args
 * @returns {{username: string, credential: string, expiresAtUnix: number, ttlSeconds: number}}
 */
function mintCredentials({ secret, uid, ttlSeconds, nowSeconds }) {
  if (!secret) throw new Error("mintCredentials: missing TURN secret");
  const ttl = Math.min(Math.max(Number(ttlSeconds) || 0, 60), MAX_TTL_SECONDS);
  const expiresAtUnix = nowSeconds + ttl;
  // The uid is opaque to the TURN server; it only makes the username unique per user
  // so abuse can be traced back from the relay's logs.
  const username = `${expiresAtUnix}:${uid}`;
  const credential = crypto
    .createHmac("sha1", secret)
    .update(username)
    .digest("base64");
  return { username, credential, expiresAtUnix, ttlSeconds: ttl };
}

/**
 * Callable: returns the ICE servers this client should use for its next call.
 *
 * Auth is mandatory — these credentials cost relay bandwidth. The response shape
 * matches what RTCIceServer needs, so the client can hand it straight to WebRTC:
 *   { iceServers: [{ urls: [...], username, credential }], ttlSeconds, expiresAt }
 */
const getTurnCredentials = onCall({ secrets: [TURN_SECRET] }, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in before requesting TURN credentials.");
  }

  const urls = parseTurnUrls(TURN_URLS.value());
  const secret = TURN_SECRET.value();

  // Not provisioned yet (or every configured URL was malformed): answer honestly with an
  // empty list instead of failing the call. The client keeps its public STUN server and
  // still connects on most networks.
  if (urls.length === 0 || !secret) {
    console.warn("getTurnCredentials: TURN not configured (TURN_URLS/TURN_SECRET) — returning STUN-only");
    return { iceServers: [], ttlSeconds: 0, expiresAt: 0 };
  }

  const nowSeconds = Math.floor(Date.now() / 1000);
  const { username, credential, expiresAtUnix, ttlSeconds } = mintCredentials({
    secret,
    uid: request.auth.uid,
    ttlSeconds: TURN_TTL_SECONDS.value(),
    nowSeconds,
  });

  console.log(
    `getTurnCredentials: issued ${urls.length} relay URL(s) to ${request.auth.uid}, expires in ${ttlSeconds}s`
  );
  return {
    iceServers: [{ urls, username, credential }],
    ttlSeconds,
    expiresAt: expiresAtUnix,
  };
});

module.exports = {
  getTurnCredentials,
  mintCredentials,
  parseTurnUrls,
  MAX_TTL_SECONDS,
  TURN_URL_PATTERN,
};
