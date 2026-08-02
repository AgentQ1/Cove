# Inditalk — API Contracts (Quick Reference)

> Standalone cheat-sheet for the Inditalk backend REST surface. Complements `PHASE3_BACKEND_API.md` (which carries the prose, threat model, and rationale). This file is the skimmable contract: endpoints, envelopes, headers, examples.
>
> **Base URL:** `https://api.cove.app/v1`
> **Content type:** `application/json; charset=utf-8` unless noted (media bytes go to object storage directly).
> **All timestamps:** RFC 3339 / ISO 8601 UTC (`2026-07-24T18:32:04.512Z`). Server is source of truth for time.

---

## 1. Versioning

- The major version is pinned in the path: `/v1/...`. Breaking changes (field removal, type change, auth semantics) require `/v2`.
- Additive changes (new optional fields, new endpoints, new error codes) ship within `/v1` and must not break existing clients — clients MUST ignore unknown JSON fields.
- Clients send their build in `X-Inditalk-Client`; the server MAY soft-deprecate a build via the `Inditalk-Deprecation` response header (RFC-3339 sunset date) without breaking the request.
- Inditalk is end-to-end encrypted: **the server never sees plaintext message bodies.** Every `ciphertext` field below is opaque base64 (Signal-Protocol envelope, sealed by the sender). The API contracts here describe *transport of ciphertext*, not access to content.

---

## 2. Endpoint Table

Auth column: `none` = no token; `bearer` = `Authorization: Bearer <access_jwt>`; `refresh` = refresh token in body; `provisional` = short-lived token issued mid-registration.

### Auth & session
| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/auth/otp/request` | none | Start phone registration; trigger SMS/APNs OTP send. |
| POST | `/auth/otp/verify` | provisional | Verify OTP code; issue access + refresh tokens. |
| POST | `/auth/token/refresh` | refresh | Exchange refresh token for a new access token. |
| POST | `/auth/logout` | bearer | Revoke the current refresh token / device session. |
| DELETE | `/auth/account` | bearer | Irreversibly delete account and server-side records. |

### Devices & keys (Signal Protocol material)
| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/devices` | bearer | Register a new device (identity key, signed prekey). |
| GET | `/devices` | bearer | List this account's linked devices. |
| DELETE | `/devices/{deviceId}` | bearer | Unlink/revoke a device. |
| PUT | `/keys/prekeys` | bearer | Upload/replenish one-time prekeys. |
| GET | `/keys/{userId}/{deviceId}` | bearer | Fetch a prekey bundle to start a session. |
| GET | `/keys/count` | bearer | Remaining one-time prekey count (client tops up). |

### Profile & contacts
| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/me` | bearer | Fetch own profile + settings. |
| PATCH | `/me` | bearer | Update display name, avatar ref, about text. |
| POST | `/contacts/discovery` | bearer | Privacy-preserving contact discovery (hashed phone numbers). |
| GET | `/users/{userId}` | bearer | Fetch a user's public profile card. |
| PUT | `/blocks/{userId}` | bearer | Block a user. |
| DELETE | `/blocks/{userId}` | bearer | Unblock a user. |

### Messaging
| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/messages` | bearer | Send an encrypted message to a 1:1 or group conversation. |
| GET | `/conversations` | bearer | List conversations (cursor paginated). |
| GET | `/conversations/{conversationId}/messages` | bearer | Fetch message history for a conversation. |
| POST | `/messages/{messageId}/receipts` | bearer | Post delivery/read receipt. |
| DELETE | `/messages/{messageId}` | bearer | Delete-for-everyone (tombstone) within allowed window. |
| POST | `/conversations/{conversationId}/typing` | bearer | Ephemeral typing indicator (best-effort, not persisted). |

### Groups
| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/groups` | bearer | Create a group conversation. |
| GET | `/groups/{groupId}` | bearer | Fetch group metadata (encrypted title/avatar refs). |
| PATCH | `/groups/{groupId}` | bearer | Update group metadata (admin only). |
| POST | `/groups/{groupId}/members` | bearer | Add members (admin only). |
| DELETE | `/groups/{groupId}/members/{userId}` | bearer | Remove member / leave group. |

### Media
| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/media/uploads` | bearer | Get a pre-signed PUT URL for an encrypted blob. |
| POST | `/media/downloads` | bearer | Get a pre-signed GET URL for a stored blob. |

### Calls (signaling only; media is P2P/SFU WebRTC)
| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/calls` | bearer | Create a call offer; server relays via PushKit. |
| POST | `/calls/{callId}/signal` | bearer | Relay ICE/SDP signaling payload. |
| GET | `/turn/credentials` | bearer | Short-lived TURN/STUN credentials (WebRTC). |

### Push
| Method | Path | Auth | Purpose |
|---|---|---|---|
| PUT | `/push/tokens` | bearer | Register APNs + PushKit VoIP tokens. |
| DELETE | `/push/tokens` | bearer | Deregister a push token. |

---

## 3. Standard Headers

### Request headers
| Header | Required | Example | Notes |
|---|---|---|---|
| `Authorization` | on `bearer` routes | `Bearer eyJhbGciOi...` | Access JWT (short TTL, ~15 min). |
| `X-Inditalk-Client` | always | `cove-ios/1.4.0 (iPhone16,2; iOS 18.5)` | Product/build + platform. Drives soft-deprecation. |
| `Idempotency-Key` | all non-GET | `9f2c7b1e-4a3d-4e9f-8b21-1c0d6a5e77aa` | UUIDv4. Server dedupes retries for 24h; same key + same body ⇒ cached response, same key + different body ⇒ `409 idempotency_conflict`. |
| `Content-Type` | bodied requests | `application/json` | |
| `Accept-Language` | optional | `en-US` | Localizes server-generated strings (errors, SMS copy). |

### Response headers
| Header | Example | Notes |
|---|---|---|
| `X-Inditalk-Request-Id` | `req_01J8Z9K3M4N5P6Q7R8S9T0` | Echo in bug reports; correlates logs. |
| `X-RateLimit-Limit` | `120` | Ceiling for the current window. |
| `X-RateLimit-Remaining` | `118` | Requests left in window. |
| `X-RateLimit-Reset` | `1753382400` | Unix epoch seconds when the window resets. |
| `Retry-After` | `12` | Seconds to wait; present on `429` and `503`. |
| `Inditalk-Deprecation` | `2026-12-01` | Sunset date for the calling build, if deprecated. |

---

## 4. Unified Error Envelope

Every non-2xx response uses the same shape. HTTP status conveys class; `error.code` is the stable machine string clients switch on (never localize logic off `message`).

```json
{
  "error": {
    "code": "otp_invalid",
    "message": "The verification code is incorrect or has expired.",
    "http_status": 401,
    "request_id": "req_01J8Z9K3M4N5P6Q7R8S9T0",
    "retriable": false,
    "details": {
      "attempts_remaining": 2,
      "field": "code"
    }
  }
}
```

| Field | Type | Notes |
|---|---|---|
| `code` | string | Stable, snake_case. See catalog below. |
| `message` | string | Human-readable, localized per `Accept-Language`. Not for branching. |
| `http_status` | int | Mirrors the HTTP status for logging convenience. |
| `request_id` | string | Same value as `X-Inditalk-Request-Id`. |
| `retriable` | bool | If `true`, client MAY retry (respect `Retry-After`). |
| `details` | object? | Optional structured context (validation fields, counters). |

### Error code catalog (representative)
| HTTP | `code` | Meaning |
|---|---|---|
| 400 | `validation_failed` | Body/query failed schema validation (`details.fields`). |
| 401 | `unauthenticated` | Missing/expired access token. |
| 401 | `otp_invalid` | Wrong or expired OTP. |
| 403 | `forbidden` | Authenticated but not allowed (e.g. non-admin group edit). |
| 403 | `user_blocked` | Recipient has blocked the sender. |
| 404 | `not_found` | Resource does not exist or is not visible. |
| 409 | `idempotency_conflict` | Reused `Idempotency-Key` with a different body. |
| 409 | `stale_prekey` | Prekey bundle consumed; refetch and retry. |
| 410 | `message_expired` | Delete-for-everyone window has closed. |
| 413 | `payload_too_large` | Ciphertext/metadata exceeds limit. |
| 422 | `unprocessable` | Well-formed but semantically invalid (e.g. self-message). |
| 429 | `rate_limited` | Throttled; see `Retry-After`. |
| 503 | `service_unavailable` | Transient backend outage; retriable. |

---

## 5. Pagination

Cursor-based, forward and backward. Never offset (rows shift under E2EE writes).

**Request query:** `?limit=50&cursor=<opaque>&direction=older`
- `limit` — 1..100, default 50. Server MAY return fewer.
- `cursor` — opaque, from a prior page's `page.next_cursor` / `page.prev_cursor`. Omit for the first page.
- `direction` — `older` (default, descending time) or `newer`.

**Response envelope** (list endpoints wrap items in `data` + `page`):

```json
{
  "data": [ /* ...items... */ ],
  "page": {
    "next_cursor": "eyJ0IjoiMjAyNi0wNy0yNFQxODozMDowMFoiLCJpZCI6Im1zZ18wMUo4In0",
    "prev_cursor": null,
    "has_more": true,
    "limit": 50
  }
}
```

A `null` cursor means no further page in that direction. Cursors are opaque, tamper-checked (HMAC), and expire after 24h → `410 not_found` on stale cursor.

---

## 6. Rate Limits (summary)

Per-account + per-IP token buckets. Exceeding either returns `429 rate_limited` with `Retry-After`. Representative ceilings (authoritative values live in `PHASE3_BACKEND_API.md`):

| Bucket | Limit |
|---|---|
| `/auth/otp/request` | 5 / hour / phone number |
| `/auth/otp/verify` | 10 / hour / phone number |
| `/messages` (send) | 60 / 10s / account |
| `/contacts/discovery` | 4 / hour / account |
| default authenticated | 120 / 60s / account |

---

## 7. Full Request/Response Examples

### 7.1 — Verify OTP (`POST /auth/otp/verify`)
Second leg of registration. `provisional_token` came from `POST /auth/otp/request`. Client also uploads its fresh identity/prekey material here or immediately after via `/devices`.

**Request**
```http
POST /v1/auth/otp/verify HTTP/1.1
Host: api.cove.app
X-Inditalk-Client: cove-ios/1.4.0 (iPhone16,2; iOS 18.5)
Idempotency-Key: 3b1f0c9a-77de-4c2a-9a1e-0b2f6d4e88c1
Content-Type: application/json
```
```json
{
  "provisional_token": "prov_01J8Z7...",
  "code": "418205",
  "device": {
    "name": "Corin's iPhone",
    "registration_id": 8412,
    "identity_key": "BQ2y9k...base64...",
    "signed_prekey": {
      "key_id": 17,
      "public_key": "BXf0...base64...",
      "signature": "MEUCIQ...base64..."
    }
  }
}
```
**Response `200`**
```json
{
  "account": {
    "id": "usr_01J8Z9AA11BB22CC33",
    "phone_e164_hash": "sha256:9f86d0818...",
    "created_at": "2026-07-24T18:32:04.512Z"
  },
  "device": { "id": "dev_01J8Z9DD44EE55", "registration_id": 8412 },
  "tokens": {
    "access_token": "eyJhbGciOiJFUzI1NiIsInR...",
    "access_expires_at": "2026-07-24T18:47:04.512Z",
    "refresh_token": "rt_01J8Z9FF66GG77HH88",
    "refresh_expires_at": "2026-10-22T18:32:04.512Z"
  }
}
```
**Failure `401`** — `{ "error": { "code": "otp_invalid", "retriable": false, "details": { "attempts_remaining": 2 } } }`

---

### 7.2 — Send message (`POST /messages`)
Body is opaque ciphertext per recipient device (Signal fan-out). Server routes and stores-and-forwards; it cannot read `ciphertext`.

**Request**
```http
POST /v1/messages HTTP/1.1
Authorization: Bearer eyJhbGciOi...
Idempotency-Key: 7c9a2e10-1f44-4b6d-8c31-9a0e5b7d2f10
X-Inditalk-Client: cove-ios/1.4.0 (iPhone16,2; iOS 18.5)
Content-Type: application/json
```
```json
{
  "conversation_id": "cnv_01J8ZA11BB22CC",
  "client_message_id": "cm_7c9a2e10",
  "type": "text",
  "recipients": [
    {
      "user_id": "usr_01J8ZBQQ",
      "device_id": "dev_01J8ZBRR",
      "envelope_type": 3,
      "ciphertext": "MwohBf0j...base64-signal-envelope..."
    },
    {
      "user_id": "usr_01J8ZBQQ",
      "device_id": "dev_01J8ZBSS",
      "envelope_type": 1,
      "ciphertext": "MwohBa71...base64-signal-envelope..."
    }
  ],
  "sent_at": "2026-07-24T18:33:10.004Z"
}
```
**Response `201`**
```json
{
  "message_id": "msg_01J8ZC77DD88EE",
  "conversation_id": "cnv_01J8ZA11BB22CC",
  "client_message_id": "cm_7c9a2e10",
  "server_timestamp": "2026-07-24T18:33:10.221Z",
  "delivery": [
    { "device_id": "dev_01J8ZBRR", "status": "queued" },
    { "device_id": "dev_01J8ZBSS", "status": "queued" }
  ]
}
```
**Partial failure `409`** — one recipient's prekey session is stale:
```json
{
  "error": {
    "code": "stale_prekey",
    "message": "A recipient device session is out of date. Refetch prekeys and resend.",
    "http_status": 409,
    "retriable": true,
    "details": {
      "stale_devices": [
        { "user_id": "usr_01J8ZBQQ", "device_id": "dev_01J8ZBSS" }
      ]
    }
  }
}
```

---

### 7.3 — Fetch history (`GET /conversations/{id}/messages`)
Cursor-paginated, newest first. Returns opaque ciphertext the client decrypts locally.

**Request**
```http
GET /v1/conversations/cnv_01J8ZA11BB22CC/messages?limit=2&direction=older HTTP/1.1
Authorization: Bearer eyJhbGciOi...
X-Inditalk-Client: cove-ios/1.4.0 (iPhone16,2; iOS 18.5)
```
**Response `200`**
```json
{
  "data": [
    {
      "message_id": "msg_01J8ZC77DD88EE",
      "sender": { "user_id": "usr_01J8ZBQQ", "device_id": "dev_01J8ZBSS" },
      "envelope_type": 1,
      "ciphertext": "MwohBa71...base64...",
      "server_timestamp": "2026-07-24T18:33:10.221Z",
      "receipts": { "delivered_at": "2026-07-24T18:33:11.000Z", "read_at": null }
    },
    {
      "message_id": "msg_01J8ZBZZ00AA11",
      "sender": { "user_id": "usr_01J8ZAME", "device_id": "dev_01J8ZAMF" },
      "envelope_type": 3,
      "ciphertext": "MwohBc93...base64...",
      "server_timestamp": "2026-07-24T18:31:02.510Z",
      "receipts": { "delivered_at": "2026-07-24T18:31:03.100Z", "read_at": "2026-07-24T18:31:40.900Z" }
    }
  ],
  "page": {
    "next_cursor": "eyJ0IjoiMjAyNi0wNy0yNFQxODozMTowMi41MTBaIiwiaWQiOiJtc2dfMDFKOFpCWloifQ",
    "prev_cursor": null,
    "has_more": true,
    "limit": 2
  }
}
```

---

### 7.4 — Create group (`POST /groups`)
Title/avatar are encrypted client-side; the server stores only refs + membership. Initial roster ciphertext (sender key distribution) is fanned out like a message.

**Request**
```http
POST /v1/groups HTTP/1.1
Authorization: Bearer eyJhbGciOi...
Idempotency-Key: a1d4f6e8-2b3c-4d5e-9f01-223344556677
X-Inditalk-Client: cove-ios/1.4.0 (iPhone16,2; iOS 18.5)
Content-Type: application/json
```
```json
{
  "client_group_id": "cg_a1d4f6e8",
  "encrypted_title": "8f3ac1...base64-sealed-title...",
  "avatar_ref": null,
  "members": [
    { "user_id": "usr_01J8ZBQQ" },
    { "user_id": "usr_01J8ZAME" }
  ],
  "sender_key_distribution": [
    { "user_id": "usr_01J8ZBQQ", "device_id": "dev_01J8ZBSS", "ciphertext": "MwohBd12...base64..." },
    { "user_id": "usr_01J8ZAME", "device_id": "dev_01J8ZAMF", "ciphertext": "MwohBe34...base64..." }
  ]
}
```
**Response `201`**
```json
{
  "group_id": "grp_01J8ZD55FF66GG",
  "conversation_id": "cnv_01J8ZD77HH88II",
  "created_at": "2026-07-24T18:35:20.700Z",
  "members": [
    { "user_id": "usr_01J8ZOWNER", "role": "admin", "joined_at": "2026-07-24T18:35:20.700Z" },
    { "user_id": "usr_01J8ZBQQ", "role": "member", "joined_at": "2026-07-24T18:35:20.700Z" },
    { "user_id": "usr_01J8ZAME", "role": "member", "joined_at": "2026-07-24T18:35:20.700Z" }
  ]
}
```

---

### 7.5 — Media upload pre-sign (`POST /media/uploads`)
Client encrypts the blob locally (AES-GCM, per-blob key shared in-band via the message ciphertext), then PUTs ciphertext bytes straight to object storage using the returned URL. Server never holds the blob key.

**Request**
```http
POST /v1/media/uploads HTTP/1.1
Authorization: Bearer eyJhbGciOi...
Idempotency-Key: c4e2a190-88ff-4a12-b0d3-556677889900
X-Inditalk-Client: cove-ios/1.4.0 (iPhone16,2; iOS 18.5)
Content-Type: application/json
```
```json
{
  "content_type": "application/octet-stream",
  "ciphertext_size_bytes": 2418176,
  "sha256_ciphertext": "b1946ac92492d2347c6235b4d2611184",
  "purpose": "message_attachment"
}
```
**Response `201`**
```json
{
  "media_id": "med_01J8ZE99JJ00KK",
  "upload": {
    "method": "PUT",
    "url": "https://blob.cove.app/uploads/med_01J8ZE99JJ00KK?X-Amz-Signature=...",
    "headers": {
      "Content-Type": "application/octet-stream",
      "x-amz-server-side-encryption": "AES256"
    },
    "expires_at": "2026-07-24T18:50:20.700Z"
  },
  "max_bytes": 104857600
}
```
After a successful PUT, the client references `med_01J8ZE99JJ00KK` inside the message ciphertext. **Failure `413`** if `ciphertext_size_bytes > max_bytes`.

---

### 7.6 — Contact discovery (`POST /contacts/discovery`)
Privacy-preserving: client submits truncated salted hashes of phone numbers; server returns matches only. Inditalk never receives plaintext address books. (Design note: a hardened deployment SHOULD run this in an enclave — see Limitations.)

**Request**
```http
POST /v1/contacts/discovery HTTP/1.1
Authorization: Bearer eyJhbGciOi...
Idempotency-Key: d7f0b3c2-99aa-4b34-8c56-778899aabbcc
X-Inditalk-Client: cove-ios/1.4.0 (iPhone16,2; iOS 18.5)
Content-Type: application/json
```
```json
{
  "hash_version": 2,
  "hashes": [
    "sha256:9f86d0818884...trunc",
    "sha256:2c26b46b68ff...trunc",
    "sha256:fcde2b2edba5...trunc"
  ]
}
```
**Response `200`**
```json
{
  "matches": [
    {
      "hash": "sha256:9f86d0818884...trunc",
      "user_id": "usr_01J8ZBQQ",
      "identity_key": "BQ2y9k...base64...",
      "profile": { "display_name": "Rowan", "avatar_ref": "med_01J8ZF..." }
    }
  ],
  "unmatched_count": 2
}
```

---

### 7.7 — Refresh access token (`POST /auth/token/refresh`)
Rotating refresh tokens: each refresh invalidates the presented token and issues a new pair. Reuse of a rotated token ⇒ `401 unauthenticated` and full session revocation (theft detection).

**Request**
```json
{ "refresh_token": "rt_01J8Z9FF66GG77HH88" }
```
**Response `200`**
```json
{
  "access_token": "eyJhbGciOiJFUzI1NiIsInR...",
  "access_expires_at": "2026-07-24T19:02:04.512Z",
  "refresh_token": "rt_01J8ZG11MM22NN33",
  "refresh_expires_at": "2026-10-22T18:47:04.512Z"
}
```

---

### 7.8 — Fetch prekey bundle (`GET /keys/{userId}/{deviceId}`)
Consumes one one-time prekey to bootstrap an X3DH session. If none remain, the signed prekey is returned alone (allowed, slightly weaker forward-secrecy at session start).

**Response `200`**
```json
{
  "user_id": "usr_01J8ZBQQ",
  "device_id": "dev_01J8ZBSS",
  "registration_id": 8412,
  "identity_key": "BQ2y9k...base64...",
  "signed_prekey": {
    "key_id": 17,
    "public_key": "BXf0...base64...",
    "signature": "MEUCIQ...base64..."
  },
  "one_time_prekey": {
    "key_id": 5099,
    "public_key": "BZ11...base64..."
  }
}
```
When exhausted, `one_time_prekey` is `null`. Server emits a low-water signal so the owning device tops up via `PUT /keys/prekeys`.

---

## 8. Limitations / Requires Independent Audit

- **Not production-secure as specified.** This contract has **not** undergone independent security or cryptographic review. Treat it as a design draft.
- **Contact discovery** as sketched (truncated salted hashes) is vulnerable to offline brute-force over the finite phone-number space and to a malicious server enumerating membership. A real deployment needs an oblivious/enclave-backed scheme (e.g. private set intersection or SGX-style CDS) and an independent audit before launch.
- **Metadata exposure:** while message *bodies* are E2EE, the server observes routing metadata (who talks to whom, when, sizes, group membership). Minimizing this (sealed sender, padding, timing defenses) is out of scope here and must be designed and audited separately.
- **Idempotency, rate-limit, and cursor HMAC** parameters above are illustrative; concrete windows, key rotation, and abuse thresholds are owned by `PHASE3_BACKEND_API.md` and require load/abuse testing.
- **JWT/refresh rotation** theft-detection assumes reliable server-side token-family tracking; failure modes (clock skew, replay across regions) need review.
- No claim is made that any endpoint resists a compromised or coerced server. E2EE limits, but does not eliminate, server trust.
