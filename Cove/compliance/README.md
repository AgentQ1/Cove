# Export compliance — Inditalk

Inditalk encrypts message bodies itself (not just HTTPS), so it is **not exempt** and needs
export documentation. All algorithms are standard and published, which puts it in the
ordinary mass-market **ECCN 5D992.c** lane — no CCATS review needed.

## Files

| File | What it is |
|---|---|
| `bis-self-classification-report.csv` | The filing. One row per product, which is the format BIS parses. |
| `bis-self-classification-report.pdf` | Same content as a readable document. Apple rejects `.csv`, so this is what App Store Connect got. |

## Status

- **27 Jul 2026** — filed with BIS (`crypt@bis.doc.gov`) and NSA (`enc@nsa.gov`).
- **27 Jul 2026** — PDF uploaded to the App Store Connect declaration
  `2ed1d506-08f6-4891-9771-5f3a10acffc9`, which auto-submitted and is **IN_REVIEW**.

### Still to do

1. **Follow-up email to BIS.** The first send attached an earlier draft that had the same
   content in a vertical key/value layout rather than the one-row-per-product format.
   Nothing in it was wrong or missing — reply-all attaching the CSV above, noting it
   supersedes the previous attachment.
2. **Wait for Apple** to approve the declaration and issue a compliance code.
3. When the code arrives, add **both** keys to `Inditalk/Info.plist`, then rebuild:

   ```xml
   <key>ITSAppUsesNonExemptEncryption</key><true/>
   <key>ITSEncryptionExportComplianceCode</key><string>THE-CODE</string>
   ```

> ⚠️ **Never add `ITSAppUsesNonExemptEncryption` on its own.** Without a matching code every
> upload fails with error 90592 (*"Invalid Export Compliance Code … [] doesn't match the
> app's export compliance documentation"*), which blocks TestFlight too. Tested on build 4.

### Recurring obligation

Self-classification reports are due **annually by 1 February** covering the prior calendar
year. If Inditalk ships in 2026, the next report is due **1 Feb 2027**.

## What the app actually uses

Verified against the signed binary, not from memory.

**Implemented by the app** (via Apple CryptoKit) — X25519 ECDH (RFC 7748), Ed25519
signatures (RFC 8032), ChaCha20-Poly1305 (RFC 8439), HKDF-SHA256 (RFC 5869), HMAC-SHA256,
SHA-256. Key management is an X3DH-style handshake plus a Double Ratchet — published
designs built only from those primitives. **No proprietary cryptography, no open
cryptographic interface.**

**Third-party, bundled** — BoringSSL via Firebase/gRPC (`openssl_grpc.framework`) for
TLS 1.2/1.3, and WebRTC (`WebRTC.framework`) for DTLS-SRTP call media. This is why the
App Store Connect answer to *"contains third-party cryptography"* is **Yes**, even though
the app's own crypto is all Apple CryptoKit.
