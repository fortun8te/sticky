# Manual QA

Test on one Mac and one Windows PC on the same private network. Record build SHA, OS versions, network type, and failures. Clear both `~/Downloads/Sticky` folders first.

## Setup and pairing

- [ ] Both apps discover each other within 30 seconds.
- [ ] First pairing accepts the displayed PIN; wrong PIN is rejected.
- [ ] Restarting both apps reconnects without asking for PIN again.
- [ ] Unpairing removes trust and requires pairing again.

## Large streaming — 500GB scale

- [ ] Send a real 500GB-scale file (or the largest production-representative file available).
- [ ] Sender and receiver remain responsive while progress updates.
- [ ] Receiver memory stays flat; Activity Monitor/Task Manager does not show the whole file buffered.
- [ ] Destination file size matches source. Compare SHA-256 (`shasum -a 256 FILE`, `Get-FileHash FILE`).
- [ ] Cancel mid-transfer removes/cleans the partial receiver state and frees the session.
- [ ] A second transfer starts after completion or cancellation.

## Folders

- [ ] Send nested folders with 60+ files, long paths, spaces, Unicode names, and an empty subfolder where supported.
- [ ] Relative folder structure is preserved under `Downloads/Sticky`.
- [ ] Repeat send creates collision-safe `(2)` names without overwriting.

## Images

- [ ] Send JPEG, PNG, HEIC, screenshot, and a large image.
- [ ] Previews render or fail visibly without blocking the queue.
- [ ] Received images open and dimensions/content match the originals.

## Sleep/wake and IP change

- [ ] Sleep one machine for 30 seconds, wake it, and confirm rediscovery within 30 seconds.
- [ ] Send clipboard and a small file after wake.
- [ ] Change IP (switch Wi-Fi/network or renew DHCP), wait for stale peer expiry, and confirm the current address is used.
- [ ] Send successfully after rediscovery.

## Offline failure

- [ ] Disable Wi-Fi or turn off the receiver, then attempt text/file sends.
- [ ] Retry/failure is visible; the sender stops after its retry policy instead of hanging forever.
- [ ] Reconnect and verify a new send succeeds.

## Wispr Flow and clipboard promotion

- [ ] Focus a Wispr Flow input and receive plain UTF-8 text containing accents, emoji, quotes, line breaks, and code punctuation.
- [ ] Text pastes into Wispr Flow without lost characters or formatting artifacts.
- [ ] Receiving text does not immediately overwrite the system clipboard.
- [ ] Promote from the sticky slot/history and paste into Notes/Notepad.
- [ ] History keeps the latest 20 entries and clears/quits behavior is intentional.

## MCP

- [ ] With the native app running, list peers/info succeeds.
- [ ] Send text through MCP and promote/paste it on the peer.
- [ ] Send a representative file through MCP and verify destination bytes/name.
- [ ] Stopping the native app produces a clear MCP error rather than a silent hang.
