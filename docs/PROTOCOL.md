# Sticky wire protocol — v1

**Both platforms implement this document.** Neither extends it unilaterally. If
something here is ambiguous, that is a bug in this file — fix it here first, in
its own commit, then implement.

Shape is adapted from [LocalSend](https://github.com/localsend/protocol), whose
prepare/upload split is well proven. Identity is adapted from Syncthing. The
mutual-pinning requirement in §4 is stricter than either.

---

## 1. Constants

```
DISCOVERY_GROUP   224.0.0.167
DISCOVERY_PORT    47831/udp
TRANSFER_PORT     47832/tcp        HTTPS, TLS 1.3, mutual auth
ANNOUNCE_INTERVAL 3s while unpaired-or-disconnected, 15s while connected
PEER_TIMEOUT      45s without an announce → peer considered gone
PROTOCOL_VERSION  1
```

One port number for each transport, so the firewall story is two numbers, not ten.

---

## 2. Identity

A device's identity is an Ed25519 keypair and a self-signed X.509 certificate
wrapping it.

```
deviceId = lowercase hex of SHA-256(DER-encoded leaf certificate)
```

The ID **is** the fingerprint. It cannot be forged without the private key, so
there is no separate pin registry to keep in sync.

`shortCode` = first 6 hex chars of `deviceId`, uppercased, shown to the human
during pairing.

**Key storage**
- macOS: Keychain, plain accessibility constant, **no `SecAccessControl` flags**,
  written with `SecItemUpdate` (never delete+add). Requires a stable Developer ID
  signature or macOS re-prompts every launch.
- Windows: `ProtectedData.Protect(..., DataProtectionScope.CurrentUser)` with
  per-install entropy, under `%LOCALAPPDATA%\Sticky\`, ACL restricted to the
  current user.

---

## 3. Discovery

UDP multicast. **Not mDNS** — Windows has no responder usable from .NET, and
Apple's Bonjour contends for 5353.

Announce (sent by both sides):

```json
{
  "v": 1,
  "deviceId": "9f2c…",
  "name": "Michael's MacBook Pro",
  "platform": "macos",
  "port": 47832,
  "reply": true
}
```

A peer receiving `reply: true` answers once, unicast, with `reply: false`.
Ignore any datagram whose `deviceId` equals your own.

**Fallback.** If no announce is seen for 10 s, sweep the /24 with
`GET /v1/hello` (TLS, 400 ms timeout, 32 concurrent). Some networks drop
multicast; this is why LocalSend ships the same fallback.

---

## 4. Transport security

TLS 1.3, **mutually authenticated, both sides pinning**.

1. Default chain validation is *replaced*, not augmented — a self-signed cert
   never passes it.
2. Each side computes SHA-256 of the peer's leaf certificate and compares it,
   constant-time, against the stored `deviceId`.
3. Mismatch, or an unknown peer → close the connection. Do not prompt, do not
   fall back, do not serve a 403 with detail.

- macOS: `sec_protocol_options_set_verify_block` on `NWProtocolTLS.Options`.
- Windows: `RemoteCertificateValidationCallback` on **both**
  `SslClientAuthenticationOptions` and `SslServerAuthenticationOptions`.
  Use `GetCertHash(HashAlgorithmName.SHA256)` — `Thumbprint` is SHA-1.

An unpaired device on the same LAN can reach nothing but `/v1/pair`.

---

## 5. Pairing

`POST /v1/pair`

```json
{ "v": 1, "deviceId": "9f2c…", "name": "…", "platform": "windows" }
```

Both devices display the same `pairCode` — the first 6 hex characters of
`SHA-256(sorted(deviceIdA, deviceIdB))`, uppercased, rendered as `A1B2C3`.
Deriving it from both IDs means neither side can choose it.

The human confirms on **both** machines. Each then stores the other's
`deviceId`. `200` on mutual confirm, `403` on rejection, `409` if a pairing is
already in flight.

After pairing there is no PIN, no prompt, and no further dialog.

---

## 6. Transfer

### 6.1 `POST /v1/prepare`

```json
{
  "v": 1,
  "sessionId": "018f3c…",
  "totalBytes": 5242880,
  "files": [
    {
      "id": "f1",
      "name": "Screenshot 2026-08-22 at 14.03.11.png",
      "relPath": "Screenshot 2026-08-22 at 14.03.11.png",
      "size": 5242880,
      "sha256": "e3b0c4…",
      "modified": "2026-08-22T14:03:11Z"
    }
  ]
}
```

- `name` and `relPath` are **NFC-normalised UTF-8**, always, on the wire. The
  sender normalises; the receiver does not have to guess. macOS emits NFD
  natively, so the Mac side must normalise before sending.
- `relPath` uses `/` separators, is always relative, and never begins with `/`
  or contains `..`. Receivers re-validate; they do not trust it.
- Folders are flattened into their files; the folder is implied by `relPath`.

Response `200`:
```json
{ "sessionId": "018f3c…", "tokens": { "f1": "9a7d…" }, "resume": { "f1": 0 } }
```

`resume[fileId]` is the byte offset the receiver already holds — `0` for a fresh
transfer, non-zero to continue an interrupted one.

### 6.2 `POST /v1/upload?session=…&file=…&token=…&offset=…`

Raw bytes in the body, starting at `offset`. `Content-Length` required.

### 6.3 `POST /v1/cancel?session=…`

Either side may call it. The receiver deletes its `.part` file.

### 6.4 `GET /v1/progress?session=…`

Returns receiver-acknowledged bytes. **Progress shown to the user comes from
here**, never from bytes written to the local socket.

```json
{ "sessionId": "018f3c…", "received": { "f1": 3145728 }, "state": "active" }
```

---

## 7. Status codes

| Code | Meaning | Client behaviour |
|---|---|---|
| `200` | OK | continue |
| `400` | malformed request | bug — log loudly, do not retry |
| `401` | not paired | prompt to pair |
| `403` | rejected by user | stop, surface "Declined" |
| `409` | another session active | queue, retry in 2 s |
| `413` | exceeds size ceiling | surface the actual ceiling |
| `422` | checksum mismatch | delete `.part`, retry once, then fail as "Checksum mismatch" |
| `507` | insufficient space | surface "Not enough space on <device>" |

Error bodies: `{"error":"code","message":"human readable"}`. The `message` is
shown to the user verbatim, so write it for a human.

---

## 8. Receiving

1. Stream to `<dest>/.sticky-<fileId>.part` — **in the destination directory**,
   because atomic rename only works within one volume.
2. Verify SHA-256 **before** renaming. Never expose a file at its final name
   until it has been verified.
3. `fsync` the file, rename, `fsync` the directory.
   - Windows: `ReplaceFile`, or `MoveFileEx` with
     `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH`. Plain `File.Move` is
     **not** guaranteed atomic. Retry with backoff for ~1 s — antivirus and
     Search indexing routinely hold a transient lock on a just-written file.
4. Destination is `~/Downloads/Sticky` / `%USERPROFILE%\Downloads\Sticky`.
5. Orphaned `.part` files are swept on launch.

### 8.1 Filename sanitisation — receiver side, both platforms

Applied in this order:

1. Normalise to NFC.
2. Reject if `relPath` is absolute, contains `..`, a NUL, or a drive letter.
3. Replace `< > : " / \ | ? *` and U+0000–U+001F with `_`.
4. Strip trailing dots and spaces from every component.
5. If a component matches `^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)`
   case-insensitively — **including with an extension**, since `NUL.txt`
   collapses to `NUL` — prefix it with `_`.
6. Case-**insensitive** collision check against the destination. On collision,
   append ` (2)`, ` (3)`, … and **log the rename**. Never silently overwrite.

The vectors in `mac/Tests/SanitiseTests` and `win/Sticky.Tests/SanitiseTests`
are identical and both must pass:

```
../etc/passwd   → reject        foo/../../x → reject       C:          → reject
foo:bar         → foo_bar       shot<>.png  → shot__.png   con.txt     → _con.txt
NUL.txt         → _NUL.txt      nul         → _nul         photo.      → photo
café.pdf (NFD)  → café.pdf (NFC, 9 bytes not 10)
Report.pdf + report.pdf         → Report.pdf, report (2).pdf
```

---

## 9. Offline and resume

- No peer → the session is **pending**, never a silent success. The sender holds
  the file list; contents are copied into app-managed storage only when the
  source might disappear.
- On reconnect the sender re-runs `/v1/prepare` with the same `sessionId`; the
  receiver returns non-zero `resume` offsets for anything partially written.
- Reconnect is event-driven: `NWPathMonitor` (macOS) and
  `NetworkChange.NetworkAvailabilityChanged` (Windows) trigger an immediate
  attempt, with a flat 30 s timer underneath as a fallback.
- **Never cache a peer's IP.** Forget the dead address, re-run discovery, redial.
