# Sticky Release Checklist

Release is blocked until every gate below has a recorded result, evidence, build SHA, OS versions, network type, and tester. “Pass” means a normal user can complete the action without developer tools or a workaround.

## Release gates

### 1. Pairing and bidirectional transfer
- [ ] Mac and Windows find each other on the same private network within 30 seconds.
- [ ] First pairing accepts the displayed PIN; a wrong PIN is rejected.
- [ ] Restarting both apps reconnects without asking for the PIN again.
- [ ] Send a small file, a large file, and clipboard text in both directions.
- [ ] Received files land in `Downloads/Sticky`, keep their names, and match the source bytes.

**Gate:** both directions pass on the same build with no silent failure.

### 2. 500GB-scale streaming
- [ ] Send a real 500GB-scale file, or the largest production-representative file available.
- [ ] Both apps remain responsive and progress continues.
- [ ] Activity Monitor / Task Manager shows memory staying flat rather than filling with the file.
- [ ] Canceling mid-transfer stops cleanly, cleans partial data, and allows another transfer.
- [ ] Final file size and checksum match the source.

**Gate:** no full-file buffering, no app freeze, no corrupted result.

### 3. Folders
- [ ] Send a folder with 60+ files, nested folders, spaces, long names, Unicode names, and an empty subfolder where supported.
- [ ] The receiving folder keeps the original relative structure.
- [ ] Sending the same folder again creates `(2)` names and does not overwrite anything.

**Gate:** every expected file arrives in the expected place.

### 4. Images and previews
- [ ] Send JPEG, PNG, HEIC, screenshot, and a large image.
- [ ] Preview thumbnails appear or fail visibly without blocking the queue.
- [ ] Received images open and look identical to the source.

**Gate:** previews never corrupt or delay the real transfer.

### 5. Sticky clipboard and Wispr Flow
- [ ] Receiving text does not immediately overwrite the system clipboard.
- [ ] The sticky slot/history can promote text to the system clipboard.
- [ ] Plain UTF-8 text with accents, emoji, quotes, line breaks, and code punctuation pastes correctly into Wispr Flow.

**Gate:** Wispr Flow receives the exact text with no lost characters.

### 6. Clipboard isolation
- [ ] Copying in the normal system clipboard does not send or promote Sticky clipboard content by accident.
- [ ] The Sticky clipboard has a separate visible slot and history from the system clipboard.
- [ ] Quitting, restarting, and clearing Sticky history does not leak old content into the system clipboard.

**Gate:** the user chooses when Sticky content becomes system clipboard content.

### 7. Sleep and wake
- [ ] Sleep one machine for 30 seconds, wake it, and rediscover the peer within 30 seconds.
- [ ] Send text and a small file after wake.
- [ ] A transfer interrupted by sleep fails visibly or resumes safely; it does not hang or corrupt the destination.

**Gate:** wake recovery is automatic or clearly explains the user’s next action.

### 8. IP address change
- [ ] Switch Wi-Fi/network or renew the IP, then wait for stale peers to expire.
- [ ] The app uses the current address and rediscovers within 30 seconds.
- [ ] A new transfer succeeds after the change.

**Gate:** no attempt continues against a dead address after rediscovery.

### 9. Offline and connection failure
- [ ] Disable Wi-Fi or turn off the receiver during text and file sends.
- [ ] Retry and failure are visible; the sender stops after its retry policy instead of hanging forever.
- [ ] Reconnecting allows a new send without restarting either app.

**Gate:** every failed send has a visible, understandable outcome and a clean retry.

### 10. Firewall and system prompts
- [ ] Fresh install on Mac and Windows shows only expected firewall/permission prompts.
- [ ] Accepting the prompts enables discovery and transfer.
- [ ] Denying a prompt produces a clear recovery message rather than a silent failure.
- [ ] Reinstall or update does not repeatedly ask for the same permission.

**Gate:** prompts are expected, explainable, and recoverable.

### 11. Accessibility and permissions
- [ ] The app does not request accessibility permission unless a documented feature requires it.
- [ ] Missing permission produces a specific message and a direct path to System Settings / Windows settings.
- [ ] Granting the permission works without restarting more than once.

**Gate:** permission state is visible and never blocks unrelated features.

### 12. Displays, clamshell, and focus
- [ ] Test built-in display only, external display only, and mixed displays.
- [ ] Close the Mac lid with an external display attached and wake it again.
- [ ] The notch/pill UI appears on the intended display and remains clickable.
- [ ] No transfer or UI action steals keyboard focus or brings an app to the foreground unexpectedly.

**Gate:** the UI survives display changes and never steals focus.

### 13. Keyboard capture
- [ ] Type in a browser, password field, terminal, text editor, and game while Sticky runs.
- [ ] Confirm no global keyboard shortcut is registered in v1.
- [ ] Confirm keystrokes are not intercepted, logged, buffered, or delayed.

**Gate:** Sticky is invisible to normal typing.

### 14. Security and trust
- [ ] Pairing uses the displayed PIN and pins the peer certificate.
- [ ] A device that has not paired cannot read files, send files, or use the clipboard API.
- [ ] Unpairing removes trust and requires pairing again.
- [ ] Transfers use encrypted LAN traffic; no credentials, file contents, or clipboard contents are sent to a cloud service.

**Gate:** only explicitly paired devices can transfer.

### 15. Telemetry-free diagnostics and support bundle
- [ ] Diagnostics contain no file contents, clipboard contents, passwords, tokens, full file paths outside `Downloads/Sticky`, or personal identifiers beyond the local device name.
- [ ] A support bundle can be created from the app without developer tools.
- [ ] The bundle includes app version, OS version, service state, recent non-content errors, and permission/firewall state.
- [ ] The bundle is saved locally and explains where it went.

**Gate:** a user can share diagnostics safely.

### 16. Uninstall and cleanup
- [ ] Quit and uninstall/remove the app on both platforms.
- [ ] No helper, launch/login item, firewall rule, service, background process, or MCP registration remains active.
- [ ] Document what user data remains, how to delete it, and what is intentionally retained.
- [ ] Reinstalling after cleanup works like a fresh install.

**Gate:** uninstall stops all Sticky activity and leaves no hidden behavior.

### 17. Rollback
- [ ] Preserve the previous working installer/build and its version number.
- [ ] Upgrade a known-good setup to the release candidate.
- [ ] Roll back to the previous version without reinstalling the OS or manually repairing system settings.
- [ ] After rollback, pairing, transfer, clipboard, and discovery work with the previous release.

**Gate:** rollback restores the previous user experience without data loss.

## Release record

Record for each gate:

| Gate | Result | Evidence / notes | Build SHA | Tester | Date |
| --- | --- | --- | --- | --- | --- |
| Bidirectional transfer | Pass / Fail / Blocked |  |  |  |  |
| 500GB streaming | Pass / Fail / Blocked |  |  |  |  |
| Folders | Pass / Fail / Blocked |  |  |  |  |
| Images / previews | Pass / Fail / Blocked |  |  |  |  |
| Clipboard isolation | Pass / Fail / Blocked |  |  |  |  |
| Wispr Flow | Pass / Fail / Blocked |  |  |  |  |
| Sleep / wake | Pass / Fail / Blocked |  |  |  |  |
| IP change | Pass / Fail / Blocked |  |  |  |  |
| Offline failure | Pass / Fail / Blocked |  |  |  |  |
| Firewall / prompts | Pass / Fail / Blocked |  |  |  |  |
| Accessibility / permissions | Pass / Fail / Blocked |  |  |  |  |
| Displays / clamshell | Pass / Fail / Blocked |  |  |  |  |
| Keyboard capture | Pass / Fail / Blocked |  |  |  |  |
| Security | Pass / Fail / Blocked |  |  |  |  |
| Diagnostics / support bundle | Pass / Fail / Blocked |  |  |  |  |
| Uninstall / cleanup | Pass / Fail / Blocked |  |  |  |  |
| Rollback | Pass / Fail / Blocked |  |  |  |  |

