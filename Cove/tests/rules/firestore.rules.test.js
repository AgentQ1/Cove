/**
 * Firestore security-rules tests (firestore.rules), run against the local emulator.
 *
 *   npm install          # once
 *   npm run test:rules
 *
 * These rules are the ONLY thing standing between a signed-in user and other people's
 * data — client code cannot enforce anything, and a rule that is subtly wrong fails
 * open, silently, in production. The cases below are the ones Phase 6 depends on:
 * private push tokens, one-reaction-per-user-per-message, receipts, calls and signals.
 */

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require("@firebase/rules-unit-testing");
const {
  doc,
  getDoc,
  setDoc,
  deleteDoc,
  collection,
  getDocs,
  serverTimestamp,
} = require("firebase/firestore");

const ALICE = "uid_alice";
const BOB = "uid_bob";
const MALLORY = "uid_mallory";
const CHAT = "11111111-1111-1111-1111-111111111111";
const MESSAGE = "22222222-2222-2222-2222-222222222222";
const CALL = "33333333-3333-3333-3333-333333333333";

let testEnv;

test.before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "cove-rules-test",
    firestore: {
      rules: fs.readFileSync(path.resolve(__dirname, "../../firestore.rules"), "utf8"),
      host: "127.0.0.1",
      port: 8080,
    },
  });

  // Seed the documents the rules read (chat membership, a call) with rules disabled.
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, "chats", CHAT), {
      kind: "direct",
      title: "Alice & Bob",
      participantIds: [ALICE, BOB],
      adminIds: [],
      disappearingSeconds: 0,
    });
    await setDoc(doc(db, "chats", CHAT, "messages", MESSAGE), {
      senderId: ALICE,
      kind: "text",
      ciphertext: "sealed",
    });
    await setDoc(doc(db, "calls", CALL), { from: ALICE, to: BOB, media: "voice", state: "ringing" });
    await setDoc(doc(db, "users", BOB), { displayName: "Bob", phone: "+100", about: "", isOnline: true });
    await setDoc(doc(db, "users", BOB, "privateDevices", "bob-iphone"), {
      voipToken: "bobsvoiptoken",
      apnsEnvironment: "development",
      platform: "ios",
    });
  });
});

test.after(async () => {
  await testEnv.cleanup();
});

const as = (uid) => testEnv.authenticatedContext(uid).firestore();
const anon = () => testEnv.unauthenticatedContext().firestore();

// ---------------------------------------------------------------- push tokens

test("a VoIP token is unreadable by any other signed-in user", async () => {
  // The whole reason tokens moved off users/{uid}: that document is world-readable to
  // signed-in users for contact discovery, so a token stored there could be harvested
  // by anyone with an account.
  await assertFails(getDoc(doc(as(MALLORY), "users", BOB, "privateDevices", "bob-iphone")));
  await assertFails(getDocs(collection(as(MALLORY), "users", BOB, "privateDevices")));
  await assertFails(getDoc(doc(anon(), "users", BOB, "privateDevices", "bob-iphone")));
});

test("a user reads and writes only their own device documents", async () => {
  await assertSucceeds(getDoc(doc(as(BOB), "users", BOB, "privateDevices", "bob-iphone")));
  await assertSucceeds(
    setDoc(doc(as(BOB), "users", BOB, "privateDevices", "bob-ipad"), {
      voipToken: "another",
      apnsEnvironment: "production",
      platform: "ios",
      updatedAt: serverTimestamp(),
    })
  );
  // Nobody may plant a token on someone else's account and receive their calls.
  await assertFails(
    setDoc(doc(as(MALLORY), "users", BOB, "privateDevices", "attacker"), { voipToken: "evil" })
  );
  await assertSucceeds(deleteDoc(doc(as(BOB), "users", BOB, "privateDevices", "bob-ipad")));
});

test("the profile itself stays readable — contact discovery depends on it", async () => {
  await assertSucceeds(getDoc(doc(as(MALLORY), "users", BOB)));
  await assertFails(setDoc(doc(as(MALLORY), "users", BOB), { displayName: "hacked" }, { merge: true }));
});

// ------------------------------------------------------------------- blocking

test("a block list is private to its owner", async () => {
  // Read server-side by onCallInvite (Admin SDK, which bypasses rules) — no client but
  // the owner may see or change who they blocked.
  await assertSucceeds(setDoc(doc(as(BOB), "users", BOB, "blocked", MALLORY), { blockedAt: serverTimestamp() }));
  await assertFails(getDoc(doc(as(MALLORY), "users", BOB, "blocked", MALLORY)));
  await assertFails(setDoc(doc(as(MALLORY), "users", BOB, "blocked", MALLORY), { blockedAt: null }));
  await assertSucceeds(deleteDoc(doc(as(BOB), "users", BOB, "blocked", MALLORY)));
});

// ------------------------------------------------------------------ reactions

const reaction = (messageId, uid) => ({
  messageId,
  uid,
  ciphertext: "sealed-emoji",
  updatedAt: serverTimestamp(),
});

test("a participant may react to a message in their chat", async () => {
  await assertSucceeds(
    setDoc(doc(as(BOB), "chats", CHAT, "reactions", `${MESSAGE}_${BOB}`), reaction(MESSAGE, BOB))
  );
  await assertSucceeds(getDocs(collection(as(ALICE), "chats", CHAT, "reactions")));
});

test("a reaction cannot be attributed to someone else", async () => {
  // Authorizing on the uid FIELD is what stops a crafted doc id from impersonating.
  await assertFails(
    setDoc(doc(as(MALLORY), "chats", CHAT, "reactions", `${MESSAGE}_${BOB}`), reaction(MESSAGE, BOB))
  );
});

test("a non-participant cannot read or write reactions", async () => {
  await assertFails(getDocs(collection(as(MALLORY), "chats", CHAT, "reactions")));
  await assertFails(
    setDoc(doc(as(MALLORY), "chats", CHAT, "reactions", `${MESSAGE}_${MALLORY}`), reaction(MESSAGE, MALLORY))
  );
});

test("the doc id must be messageId_uid, so one user gets one reaction per message", async () => {
  // Otherwise Bob could hold several reactions on the same message under different ids,
  // and "one reaction per user per message" — enforced through the id, not a query —
  // would quietly stop being true.
  await assertFails(
    setDoc(doc(as(BOB), "chats", CHAT, "reactions", `${MESSAGE}_extra_${BOB}`), reaction(MESSAGE, BOB))
  );
  await assertFails(
    setDoc(doc(as(BOB), "chats", CHAT, "reactions", `other-message_${BOB}`), reaction(MESSAGE, BOB))
  );
});

test("unknown fields are rejected from a document every participant reads", async () => {
  await assertFails(
    setDoc(doc(as(BOB), "chats", CHAT, "reactions", `${MESSAGE}_${BOB}`), {
      ...reaction(MESSAGE, BOB),
      plaintextEmoji: "❤️",
    })
  );
});

test("only the reactor can remove their reaction", async () => {
  await assertFails(deleteDoc(doc(as(ALICE), "chats", CHAT, "reactions", `${MESSAGE}_${BOB}`)));
  await assertSucceeds(deleteDoc(doc(as(BOB), "chats", CHAT, "reactions", `${MESSAGE}_${BOB}`)));
});

// ------------------------------------------------------------------- receipts

test("receipts are readable by participants and writable only by their owner", async () => {
  await assertSucceeds(
    setDoc(doc(as(BOB), "chats", CHAT, "receipts", BOB), {
      lastReadMessageId: MESSAGE,
      lastReadAt: serverTimestamp(),
    })
  );
  await assertSucceeds(getDoc(doc(as(ALICE), "chats", CHAT, "receipts", BOB)));
  // Faking someone else's read position would turn another user's ticks blue.
  await assertFails(
    setDoc(doc(as(ALICE), "chats", CHAT, "receipts", BOB), { lastReadMessageId: MESSAGE })
  );
  await assertFails(getDoc(doc(as(MALLORY), "chats", CHAT, "receipts", BOB)));
});

// ---------------------------------------------------------------------- calls

test("both parties can read the call document, nobody else can", async () => {
  await assertSucceeds(getDoc(doc(as(ALICE), "calls", CALL)));
  await assertSucceeds(getDoc(doc(as(BOB), "calls", CALL)));
  await assertFails(getDoc(doc(as(MALLORY), "calls", CALL)));
});

test("a caller can create their own call document", async () => {
  const id = "44444444-4444-4444-4444-444444444444";
  await assertSucceeds(
    setDoc(doc(as(ALICE), "calls", id), { from: ALICE, to: BOB, media: "voice", state: "ringing" })
  );
  // …but not one between two other people, which would ring a stranger's phone.
  await assertFails(
    setDoc(doc(as(MALLORY), "calls", "55555555-5555-5555-5555-555555555555"), {
      from: ALICE,
      to: BOB,
      media: "voice",
      state: "ringing",
    })
  );
});

test("call signals (SDP/ICE) are limited to the two parties", async () => {
  await assertSucceeds(
    setDoc(doc(as(ALICE), "calls", CALL, "signals", "s1"), {
      callId: CALL,
      from: ALICE,
      to: BOB,
      kind: "offer",
      media: "voice",
    })
  );
  await assertSucceeds(getDocs(collection(as(BOB), "calls", CALL, "signals")));
  await assertFails(getDocs(collection(as(MALLORY), "calls", CALL, "signals")));
  // A signal must be authored by its sender — spoofing `from` is how you'd inject an
  // answer or a hangup into someone else's call.
  await assertFails(
    setDoc(doc(as(BOB), "calls", CALL, "signals", "s2"), {
      callId: CALL,
      from: ALICE,
      to: BOB,
      kind: "hangup",
      media: "voice",
    })
  );
});

// ------------------------------------------------------------------- messages

test("messages stay inside the chat and must be authored by their sender", async () => {
  await assertSucceeds(getDoc(doc(as(BOB), "chats", CHAT, "messages", MESSAGE)));
  await assertFails(getDoc(doc(as(MALLORY), "chats", CHAT, "messages", MESSAGE)));
  await assertFails(
    setDoc(doc(as(BOB), "chats", CHAT, "messages", "66666666-6666-6666-6666-666666666666"), {
      senderId: ALICE,
      kind: "text",
      ciphertext: "forged",
    })
  );
});
