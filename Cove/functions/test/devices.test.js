/**
 * Unit tests for device push-token lookup (functions/devices.js).
 *
 * Run:  npm --prefix functions test
 *
 * Two failure modes are covered here because both are invisible from the app:
 *   1. A token sent to the WRONG APNs host comes back BadDeviceToken and the phone
 *      simply never rings — so the per-device `apnsEnvironment` must decide the host,
 *      never a single global flag (that flag makes Debug and TestFlight mutually
 *      exclusive).
 *   2. An install that hasn't migrated still has its token on the profile document; if
 *      the fallback were dropped, every existing user would stop receiving calls the
 *      moment this deployed.
 */

const test = require("node:test");
const assert = require("node:assert/strict");

const { toTarget, dedupe, loadPushTargets, DEVICES } = require("../devices");

/** APNs device tokens are hex; the loader rejects anything else (see below). */
const TOKEN_A = "a1".repeat(32);
const TOKEN_B = "b2".repeat(32);

/** Minimal Firestore stand-in: only the shapes devices.js actually touches. */
function fakeDb({ devices = {}, profile = {} }) {
  return {
    collection(path) {
      assert.match(path, new RegExp(`/${DEVICES}$`));
      return {
        async get() {
          return {
            docs: Object.entries(devices).map(([id, data]) => ({ id, data: () => data })),
          };
        },
      };
    },
    doc() {
      return {
        async get() {
          return { get: (field) => profile[field] };
        },
      };
    },
  };
}

test("a device's own aps-environment decides the APNs host, not the global flag", () => {
  const dev = toTarget(
    { id: "d1", data: { voipToken: TOKEN_A, apnsEnvironment: "development" } },
    "voipToken",
    false // global flag says production...
  );
  assert.equal(dev.sandbox, true, "...but a development build's token is sandbox-only");

  const prod = toTarget(
    { id: "d2", data: { voipToken: TOKEN_B, apnsEnvironment: "production" } },
    "voipToken",
    true // ...and a TestFlight token stays production even when the flag says sandbox
  );
  assert.equal(prod.sandbox, false);
});

test("a device registered before apnsEnvironment existed falls back to the flag", () => {
  const target = toTarget({ id: "old", data: { voipToken: TOKEN_A } }, "voipToken", true);
  assert.equal(target.sandbox, true);
  assert.equal(toTarget({ id: "old", data: { voipToken: TOKEN_A } }, "voipToken", false).sandbox, false);
});

test("documents without the requested token are skipped, not sent to as empty", () => {
  // A device with only an FCM token must not be treated as a VoIP target: posting to an
  // empty device path is a 400 from APNs on every single call.
  assert.equal(toTarget({ id: "d", data: { fcmToken: "f" } }, "voipToken", true), null);
  assert.equal(toTarget({ id: "d", data: { voipToken: "" } }, "voipToken", true), null);
  assert.equal(toTarget({ id: "d", data: {} }, "fcmToken", true), null);
});

test("a VoIP token that isn't hex is refused before it reaches the request path", () => {
  // The token is interpolated into `/3/device/<token>`. A slash or a space would build a
  // malformed HTTP/2 request instead of producing an honest APNs rejection.
  const hex = "a".repeat(64);
  assert.equal(toTarget({ id: "d", data: { voipToken: hex } }, "voipToken", true).token, hex);
  for (const bad of ["../../evil", "abc def", "not-hex-at-all", "aa", "zz".repeat(32)]) {
    assert.equal(toTarget({ id: "d", data: { voipToken: bad } }, "voipToken", true), null, bad);
  }
  // FCM tokens use a wider alphabet and never touch a URL, so they are not shape-checked.
  assert.ok(toTarget({ id: "d", data: { fcmToken: "cX-y_z:APA91b..." } }, "fcmToken", true));
});

test("the same token registered under two device ids is only pushed once", () => {
  const deduped = dedupe([
    { deviceId: "a", token: "same" },
    { deviceId: "b", token: "same" },
    { deviceId: "c", token: "other" },
  ]);
  assert.deepEqual(deduped.map((t) => t.token), ["same", "other"]);
});

test("every signed-in device of a user is returned, so both phones ring", async () => {
  const db = fakeDb({
    devices: {
      iphone: { voipToken: TOKEN_A, apnsEnvironment: "development" },
      ipad: { voipToken: TOKEN_B, apnsEnvironment: "production" },
    },
  });
  const targets = await loadPushTargets(db, "u1", "voipToken", true);
  assert.equal(targets.length, 2);
  assert.deepEqual(
    targets.map((t) => [t.deviceId, t.sandbox]).sort(),
    [
      ["ipad", false],
      ["iphone", true],
    ]
  );
});

test("an unmigrated install still rings via the legacy profile token", async () => {
  const db = fakeDb({ devices: {}, profile: { voipToken: TOKEN_A } });
  const targets = await loadPushTargets(db, "u1", "voipToken", true);
  assert.deepEqual(targets, [
    { deviceId: "(profile)", token: TOKEN_A, sandbox: true, legacy: true },
  ]);
});

test("the legacy profile field is ignored once the device subcollection exists", async () => {
  // Otherwise a migrated device would be pushed twice — once privately, once from the
  // stale public copy the client is in the middle of deleting.
  const db = fakeDb({
    devices: { iphone: { voipToken: TOKEN_A, apnsEnvironment: "production" } },
    profile: { voipToken: TOKEN_B },
  });
  const targets = await loadPushTargets(db, "u1", "voipToken", true);
  assert.deepEqual(targets.map((t) => t.token), [TOKEN_A]);
});

test("a user with no registered device is not an error, just no push", async () => {
  const db = fakeDb({ devices: {}, profile: {} });
  assert.deepEqual(await loadPushTargets(db, "u1", "voipToken", true), []);
});
