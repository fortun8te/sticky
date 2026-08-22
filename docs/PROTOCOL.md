# Sticky Transfer Protocol v1

## Overview
Peer-to-peer LAN file and clipboard transfer between macOS and Windows.
No cloud, no accounts. Devices discover each other via mDNS, pair via a short-lived PIN,
then transfer directly over encrypted TLS.

## Discovery
- Service type: `_sticky._tcp.local.`
- Default port: 53317
- TXT records: `id` (device fingerprint SHA-256 prefix), `name`, `platform` (mac|win), `ver` (protocol version)
- Fallback: UDP broadcast to 255.255.255.255:53317 with JSON announce payload
- Re-announce on: app launch, network interface change, wake from sleep
- Stale peers expire after 30s without announcement refresh

## Pairing & Trust
1. First connection: receiver presents self-signed TLS cert + 6-digit PIN displayed in UI
2. Sender enters the displayed PIN and pins the receiving device’s TLS certificate
3. Both sides store pinned cert (SHA-256) in local trust store
4. Subsequent connections: TLS server-certificate pinning plus direction-specific bearer tokens; no PIN needed. The Windows receiver additionally requires the paired device certificate.
5. Unpair: delete the peer certificate and both directional tokens from local trust storage

## Transport
- HTTPS (TLS 1.3) with self-signed certs
- REST-style endpoints
- Chunked binary streaming for files (64KB default chunks)
- Parallel chunk uploads for large files (>100MB uses 4 parallel streams)

## Endpoints

### POST /api/v1/pair
Initiate pairing. Body: `{ "pin": "123456", "returnToken": "<32-byte hex secret>", "fingerprint": "<sender certificate SHA-256>", "device": { ... } }`.

The request and response establish one bearer token for each sending direction, so a completed pairing supports both Mac → Windows and Windows → Mac transfers.
Response: `200 { "paired": true, "token": "<32-byte hex secret>" }` or `401 Unauthorized`.
The token is a per-peer LAN credential issued only after the correct PIN. Clients store it securely.

The PIN is a local convenience check, not a substitute for manually verifying a device on a hostile network. Pair only devices you can see and trust; a future version can add a two-device confirmation code for stronger first-pairing protection.

### Authenticated endpoints

`prepare-upload`, `upload`, `complete`, and `cancel` require:

```text
Authorization: Bearer <pairing-token>
```

### GET /api/v1/info
Device info probe.
Response: `{ "id": "...", "name": "...", "platform": "mac", "ver": "1.0" }`

### POST /api/v1/prepare-upload
Send metadata before file bytes. Receiver accepts/rejects.
Body:
```json
{
  "session": "uuid",
  "sender": { "id": "...", "name": "Michael's MacBook" },
  "files": [
    { "id": "f1", "path": "relative/path.png", "size": 12345, "mime": "image/png" }
  ],
  "text": "optional clipboard text",
  "kind": "files" | "clipboard"
}
```
Response: `{ "session": "uuid", "tokens": { "f1": "token1" } }`
Errors: `403 Rejected`, `409 Busy`

### POST /api/v1/upload?session=X&file=f1&token=T
Binary body = raw file bytes for that fileId.
Parallel-safe. Response: `204 No Content` or `422 Checksum mismatch`.

### POST /api/v1/complete?session=X
Signal all chunks done. Receiver finalizes (moves temp → dest).
Response: `200 { "received": ["path1", "path2"] }`

### POST /api/v1/cancel?session=X
Abort session.

### POST /api/v1/clipboard
Send sticky clipboard text.
Body: `{ "text": "...", "sender": { "id": "..." }, "ts": 1234567890 }`
Requires the same pairing bearer token. Response: `200 OK`
Response: `200 OK`

## Sticky Clipboard
- Separate from system clipboard on both platforms
- Sticky never observes or automatically sends the normal system clipboard.
- Text enters the private Sticky slot only when received from a paired device or explicitly written in Sticky/MCP.
- The user explicitly promotes a selected Sticky item to the system clipboard.
- Wispr Flow compatibility: text arrives as plain UTF-8, no formatting loss
- History: last 20 entries stored locally

## File Handling
- Folders: recursive walk, relative paths preserved, zip on-the-fly if >50 files
- Large files: chunked at 64KB, streamed (no full-file buffering)
- Image preview: first 32KB of image sent inline in prepare-upload metadata for thumbnail
- Destination: `~/Downloads/Sticky/` on both platforms
- Name collision: append `(2)`, `(3)` etc.

## Error Recovery
- Transfer timeout: 10min idle → abort
- Chunk retry: 3 attempts with backoff
- Resume: not v1 (future)
- Offline queue: sender retries every 30s up to 5 times, then notifies failure
