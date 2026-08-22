# Sticky End-to-End Test Plan

## Scope and rules

This plan verifies one physical Mac and one physical Windows PC on the same private LAN. It covers discovery, pairing, bidirectional transfers, folders, 500GB-scale streaming, power/network changes, denial paths, cancellation, collisions, clipboard promotion, Wispr Flow paste, and UI correctness.

- Do not use guest, public, hotel, or captive-portal networks. Disable VPNs unless they explicitly pass local LAN traffic.
- Use release-equivalent debug builds from the same commit. Record the commit SHA, build command, OS versions, app versions, hostnames, and both local IP addresses before testing.
- Clear `~/Downloads/Sticky` on both machines at the start of a clean run.
- The receiver must stream file bytes; it may not buffer an entire large file in memory.
- Every case needs timestamped evidence saved in the run directory created by `tools/e2e/sticky_e2e.py`. A case is **Pass** only when its expected result and listed evidence are present. Mark **Blocked** rather than silently skipping a prerequisite failure.

## Evidence standard

Capture evidence as applicable to each case:

1. Harness JSON/JSONL output from `tools/e2e/sticky_e2e.py`.
2. Source and destination path, byte size, relative tree, and SHA-256 for normal files. For a sparse 500GB-scale source, record size plus SHA-256 of sampled head/middle/tail chunks; otherwise compare full hashes.
3. Screenshots or screen recordings of both UIs, including idle → active → success/failure transitions.
4. Native app logs, macOS Console excerpts, Windows Event Viewer excerpts, firewall state, and control API responses where available.
5. Memory samples from Activity Monitor / Task Manager during large transfers.
6. Exact clock timestamps for sleep, wake, network change, rediscovery, send start, and completion.

Do not paste secrets, full trust-store contents, or private certificate material into evidence.

## Matrix

| ID | Area | Pass condition | Required evidence |
|---|---|---|---|
| ENV-001 | Both machines | Both builds launch cleanly, grant required permissions, expose their local APIs, and show correct device identity/platform/version. | Build metadata, launch screenshots, `/api/v1/control/status` responses, permission screenshots. |
| DISC-001 | Same-LAN discovery | Each machine discovers the other within 30 seconds using mDNS, with UDP fallback only if needed. TXT fields match protocol v1. Stale peers disappear after 30 seconds without refresh. | Both peer lists with timestamps, mDNS/browser output, UDP fallback log if used, stale-expiry recording. |
| PAIR-001 | Pairing | First pairing accepts the displayed six-digit PIN, pins the peer certificate, and succeeds without cloud access. Restarting both apps reconnects without another PIN. Unpair removes trust and forces pairing again. | PIN screens with digits masked if recorded, pair result, restart/reconnect recordings, trust-state change note, unpair/re-pair recording. |
| PAIR-002 | Wrong PIN | A deliberately wrong PIN returns a visible authentication failure, does not create trust, and leaves both apps recoverable. | Sender/receiver screenshots, HTTP/status or log evidence, proof that no peer was trusted. |
| XFER-MW-001 | Mac→Windows | One small file, one image, and one text payload each move Mac→Windows. Bytes/hashes match, text is exact UTF-8, images open with matching dimensions/content, and destination names match. | Manifest, hashes/dimensions, destination listing, transfer records, both UI recordings. |
| XFER-WM-001 | Windows→Mac | Repeat the same representative payloads Windows→Mac. Bytes/hashes match, text is exact UTF-8, images open correctly, and destinations match. | Same evidence as XFER-MW-001, captured in the reverse direction. |
| FOLD-001 | Folders | A nested folder containing 60+ files, spaces, Unicode names, long-but-supported paths, and an empty subfolder preserves its relative structure under `Downloads/Sticky`. Empty folders may be absent only where the platform cannot represent them; record that limitation. | Source/destination trees, file count, per-file hash comparison, empty-folder behavior screenshot/log. |
| BIG-001 | 500GB-scale streaming | A production-representative 500GB-scale file completes (or reaches an agreed time-boxed checkpoint) while both apps remain responsive. Receiver memory stays flat, progress updates continuously, disk space remains sufficient, and completed bytes/hash samples match. If time-boxed, cancel through CANCEL-001 and still verify streaming/memory/cleanup. | Start/end or checkpoint timestamps, progress recording, periodic memory samples, source/destination sizes, sampled hashes, disk-free logs. |
| LIFE-001 | Sleep/wake | Sleep either machine for about 30 seconds. After wake, it re-announces and peers rediscover within 30 seconds; then text and a small file transfer successfully. | Sleep/wake timestamps, rediscovery interval, peer-list screenshots, post-wake transfer records and hashes. |
| NET-001 | Network/IP change | Change the tested machine's IP or network, allow stale-peer expiry, and rediscovery uses the current address. A subsequent transfer succeeds without restarting either app. | Before/after IP addresses, stale-expiry timestamp, discovery logs showing current address, post-change transfer record/hash. |
| SEC-001 | Firewall denial | Deny inbound TCP 53317 (and UDP 53317 for discovery) on the receiver. Discovery/send fails visibly within retry policy, does not hang forever, and restoring the rule allows recovery without reinstalling. | Firewall rule before/during/after, failed-send UI/log/control error, recovery transfer evidence. |
| CANCEL-001 | Cancel mid-transfer | Cancel a sufficiently large transfer from sender or receiver. Both sides stop promptly, mark failure/cancelled, clean partial/temp state, free the session, and can immediately start another transfer. | Cancel timestamp, both UI states, session/transfer records, temp-directory before/after listings, follow-on transfer evidence. |
| NAME-001 | Duplicate filenames | Sending a filename that already exists creates `(2)`, `(3)`, etc., without overwriting. Repeating a folder send also collision-safes affected entries while preserving unrelated content. | Pre/post destination trees, hashes proving originals unchanged, new-name screenshots/listings. |
| CLIP-001 | Clipboard promotion | Incoming text enters the separate Sticky slot/history without overwriting the system clipboard. Promotion copies selected text to the system clipboard, pastes correctly elsewhere, and history retains the latest 20 entries. | System clipboard before/after, sticky slot/history recordings, paste results, history-count evidence. |
| WISPR-001 | Wispr Flow paste | Plain UTF-8 text containing accents, emoji, quotes, line breaks, and code punctuation promotes and pastes into a focused Wispr Flow input without loss or formatting artifacts. | Source text hash/escape dump, Wispr Flow before/after recording, close-up comparison, paste target confirmation. |
| UI-001 | UI state correctness | Idle, hover/armed, sending, receiving, success, failure, expanded shelf/history, disabled/busy, and reconnect states appear only when appropriate. Failure copy is actionable; motion completes without stuck overlays; controls remain responsive after every scenario. | Timestamped screen recordings keyed to transfer/session IDs, state-transition notes, accessibility/focus checks, post-failure recovery recording. |

## Execution order

1. Run ENV-001, DISC-001, PAIR-001, and PAIR-002.
2. Run XFER-MW-001 and XFER-WM-001 before larger/riskier cases.
3. Run FOLD-001, NAME-001, CLIP-001, and WISPR-001.
4. Run SEC-001, LIFE-001, and NET-001.
5. Run BIG-001 with CANCEL-001 available as its controlled early-exit path.
6. Finish with UI-001 across recovered and failed states.

A release is ready only when all cases pass or each remaining exception has an explicit product decision and tracked follow-up.

## Harness

`tools/e2e/sticky_e2e.py` is a standard-library skeleton for run setup, fixture generation, local control-API probes, evidence recording, destination verification, and report collection. It intentionally does not replace human observation of both native UIs or physical sleep/network/firewall actions.

```bash
python3 tools/e2e/sticky_e2e.py doctor
python3 tools/e2e/sticky_e2e.py fixture --profile standard --output tools/e2e/.artifacts/<run-id>/fixtures
python3 tools/e2e/sticky_e2e.py record --run-dir tools/e2e/.artifacts/<run-id> --case XFER-MW-001 --status pass --evidence screenshot.png --notes 'hashes match'
python3 tools/e2e/sticky_e2e.py verify --manifest tools/e2e/.artifacts/<run-id>/fixtures/manifest.json --destination ~/Downloads/Sticky
python3 tools/e2e/sticky_e2e.py report --run-dir tools/e2e/.artifacts/<run-id>
```
