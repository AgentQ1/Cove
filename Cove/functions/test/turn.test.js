/**
 * Unit tests for the TURN credential minting (functions/turn.js).
 *
 * Run:  npm --prefix functions test
 *
 * These cover the pure parts — the parts a deploy can't tell you are wrong. A bad
 * HMAC or an off-by-one expiry produces a TURN server that silently rejects every
 * allocation, which on the client looks identical to "TURN isn't configured".
 */

const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");

const { mintCredentials, parseTurnUrls, MAX_TTL_SECONDS } = require("../turn");

test("username is <expiry>:<uid> and credential is the HMAC-SHA1 of it", () => {
  const secret = "s3cr3t";
  const now = 1_700_000_000;
  const { username, credential, expiresAtUnix } = mintCredentials({
    secret,
    uid: "user-abc",
    ttlSeconds: 3600,
    nowSeconds: now,
  });

  assert.equal(expiresAtUnix, now + 3600);
  assert.equal(username, `${now + 3600}:user-abc`);

  // This is exactly what coturn recomputes with its static-auth-secret; if the two
  // disagree the relay answers 401 and every restrictive-NAT call fails.
  const expected = crypto.createHmac("sha1", secret).update(username).digest("base64");
  assert.equal(credential, expected);
});

test("credentials are short-lived and clamped to sane bounds", () => {
  const now = 1_700_000_000;
  const args = { secret: "s", uid: "u", nowSeconds: now };

  // Too short is rounded up to a minute (a credential that expires mid-handshake is
  // worse than useless).
  assert.equal(mintCredentials({ ...args, ttlSeconds: 5 }).ttlSeconds, 60);
  // Absurdly long is clamped: a leaked credential must stop working the same day.
  assert.equal(mintCredentials({ ...args, ttlSeconds: 999999 }).ttlSeconds, MAX_TTL_SECONDS);
  // Garbage config never yields a permanent credential.
  assert.equal(mintCredentials({ ...args, ttlSeconds: undefined }).ttlSeconds, 60);
});

test("each user gets a distinct username so relay abuse is traceable", () => {
  const args = { secret: "s", ttlSeconds: 600, nowSeconds: 1_700_000_000 };
  const a = mintCredentials({ ...args, uid: "alice" });
  const b = mintCredentials({ ...args, uid: "bob" });
  assert.notEqual(a.username, b.username);
  assert.notEqual(a.credential, b.credential);
});

test("minting without a secret throws instead of issuing a forgeable credential", () => {
  assert.throws(() =>
    mintCredentials({ secret: "", uid: "u", ttlSeconds: 600, nowSeconds: 1 })
  );
});

test("URL list parsing tolerates whitespace, newlines and empty config", () => {
  assert.deepEqual(
    parseTurnUrls("turn:a.example:3478?transport=udp, turn:a.example:3478?transport=tcp"),
    ["turn:a.example:3478?transport=udp", "turn:a.example:3478?transport=tcp"]
  );
  assert.deepEqual(parseTurnUrls("turns:a.example:5349 ,\n , "), ["turns:a.example:5349"]);
  // Unset config must yield an empty list — that is what makes the client fall back
  // to STUN-only rather than handing WebRTC a malformed server entry.
  assert.deepEqual(parseTurnUrls(""), []);
  assert.deepEqual(parseTurnUrls(undefined), []);
});

test("malformed relay URLs are dropped instead of being handed to WebRTC", () => {
  // libwebrtc rejects the ENTIRE RTCIceServer entry when one of its URLs is unparseable,
  // so a single typo in TURN_URLS would cost every relay in the grant — and the only
  // symptom would be calls quietly falling back to STUN.
  assert.deepEqual(
    parseTurnUrls("turn:good.example:3478?transport=udp,not a url,turns:good.example:5349"),
    ["turn:good.example:3478?transport=udp", "turns:good.example:5349"]
  );
  // Wrong scheme (a relay is not an HTTP endpoint), missing host, unsupported transport,
  // and an embedded credential (which belongs in `username`/`credential`, never the URL).
  assert.deepEqual(parseTurnUrls("https://relay.example"), []);
  assert.deepEqual(parseTurnUrls("turn:"), []);
  assert.deepEqual(parseTurnUrls("turn:a.example:3478?transport=sctp"), []);
  // Credentials belong in the `username`/`credential` fields. Rejected — and the warning
  // this produces redacts the userinfo rather than echoing it into Cloud Logging.
  assert.deepEqual(parseTurnUrls("turn:user:pass@a.example:3478"), []);
  assert.deepEqual(parseTurnUrls("turn://user:pass@a.example:3478"), []);
  // Everything malformed is indistinguishable from unconfigured, which is the safe
  // answer: an empty list keeps the client on STUN rather than failing the call.
  assert.deepEqual(parseTurnUrls("nonsense,,also-nonsense"), []);
});

test("valid relay URL shapes are all accepted", () => {
  const valid = [
    "turn:relay.example",
    "turn:relay.example:3478",
    "turn:relay.example:3478?transport=udp",
    "turn:relay.example:3478?transport=tcp",
    "turns:relay.example:5349?transport=tcp",
    "stun:stun.l.google.com:19302",
    "turn:127.0.0.1:3478",
  ];
  assert.deepEqual(parseTurnUrls(valid.join(",")), valid);
});
