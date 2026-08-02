/**
 * Unit tests for the APNs provider token used by the VoIP push (functions/voip.js).
 *
 * Run:  npm --prefix functions test
 *
 * The JWT is the one part of the VoIP path that fails *silently but totally*: a token
 * APNs won't accept comes back as a 403 InvalidProviderToken and the callee simply
 * never rings. These tests verify the exact encoding Apple requires — ES256 with the
 * raw R||S signature (not Node's default DER), `kid` in the header, `iss`/`iat` in the
 * claims — against a locally generated P-256 key.
 */

const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");

const {
  providerToken,
  base64url,
  voipRequestHeaders,
  DEAD_TOKEN_REASONS,
  SANDBOX_HOST,
  PRODUCTION_HOST,
} = require("../voip");

function p256KeyPair() {
  return crypto.generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
    publicKeyEncoding: { type: "spki", format: "pem" },
  });
}

function decodeSegment(segment) {
  return JSON.parse(Buffer.from(segment, "base64url").toString("utf8"));
}

test("provider token carries the header and claims APNs requires", () => {
  const { privateKey } = p256KeyPair();
  const now = 1_700_000_000;
  const jwt = providerToken({
    key: privateKey,
    keyId: "ABCDE12345",
    teamId: "TEAM123456",
    nowSeconds: now,
  });

  const [header, claims] = jwt.split(".");
  assert.deepEqual(decodeSegment(header), { alg: "ES256", kid: "ABCDE12345" });
  assert.deepEqual(decodeSegment(claims), { iss: "TEAM123456", iat: now });
});

test("signature is raw R||S ES256 and verifies against the public key", () => {
  const { privateKey, publicKey } = p256KeyPair();
  const jwt = providerToken({
    key: privateKey,
    keyId: "K",
    teamId: "T",
    nowSeconds: 1_700_000_000,
  });

  const [header, claims, signature] = jwt.split(".");
  const raw = Buffer.from(signature, "base64url");

  // JOSE ES256 signatures are exactly 64 bytes (two 32-byte integers). Node's default
  // DER encoding is variable-length and ~70 bytes — APNs rejects it outright.
  assert.equal(raw.length, 64);

  const verified = crypto.verify(
    "sha256",
    Buffer.from(`${header}.${claims}`),
    { key: publicKey, dsaEncoding: "ieee-p1363" },
    raw
  );
  assert.ok(verified, "APNs must be able to verify the token with the key's public half");
});

test("token is URL-safe: no +, / or = anywhere in the JWT", () => {
  const { privateKey } = p256KeyPair();
  // Signatures are random per call; run a handful so a byte that encodes to '+' or '/'
  // is actually exercised rather than left to chance.
  for (let i = 0; i < 25; i++) {
    const jwt = providerToken({
      key: privateKey,
      keyId: "K",
      teamId: "T",
      nowSeconds: 1_700_000_000 + i,
    });
    assert.match(jwt, /^[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+$/);
  }
});

test("base64url drops padding and substitutes the URL-unsafe alphabet", () => {
  assert.equal(base64url(Buffer.from([0xfb, 0xff])), "-_8");
  assert.equal(base64url("a"), "YQ");
});

test("the request is addressed as a VoIP push, not an ordinary notification", () => {
  // These three headers ARE the difference between a locked phone ringing and nothing
  // happening. `apns-push-type: voip` and the `.voip` topic are what PushKit delivers on;
  // priority 10 is what makes it immediate. A wrong topic is rejected as
  // DeviceTokenNotForTopic; a wrong push type is accepted and silently never delivered.
  const headers = voipRequestHeaders({
    deviceToken: "a1".repeat(32),
    topic: "chat.cove.app",
    jwt: "signed.jwt.here",
    contentLength: 42,
    nowSeconds: 1_700_000_000,
  });

  assert.equal(headers["apns-push-type"], "voip");
  assert.equal(headers["apns-topic"], "chat.cove.app.voip");
  assert.equal(headers["apns-priority"], "10");
  assert.equal(headers[":method"], "POST");
  assert.equal(headers[":path"], `/3/device/${"a1".repeat(32)}`);
  assert.equal(headers.authorization, "bearer signed.jwt.here");
  // A ring that arrives after the caller hung up is worse than none at all.
  assert.equal(headers["apns-expiration"], String(1_700_000_030));
});

test("the two APNs hosts are the real, distinct gateways", () => {
  // Sending a development token to the production host (or the reverse) returns
  // BadDeviceToken and the callee never rings — which is why the environment is chosen
  // per device rather than from one global flag.
  assert.equal(SANDBOX_HOST, "https://api.sandbox.push.apple.com");
  assert.equal(PRODUCTION_HOST, "https://api.push.apple.com");
  assert.notEqual(SANDBOX_HOST, PRODUCTION_HOST);
});

test("dead-token reasons cover what APNs returns for a stale registration", () => {
  // Each of these means the stored voipToken can never receive a push again, so the
  // trigger prunes it. Missing one leaves a user permanently unreachable for calls.
  assert.ok(DEAD_TOKEN_REASONS.has("BadDeviceToken"));
  assert.ok(DEAD_TOKEN_REASONS.has("Unregistered"));
  assert.ok(DEAD_TOKEN_REASONS.has("DeviceTokenNotForTopic"));
  // Transient/config failures must NOT prune — the token is fine, the send wasn't.
  assert.ok(!DEAD_TOKEN_REASONS.has("InvalidProviderToken"));
  assert.ok(!DEAD_TOKEN_REASONS.has("TooManyRequests"));
});
