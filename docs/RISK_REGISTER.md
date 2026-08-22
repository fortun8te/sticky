# Sticky Risk Register

Risks are ordered by release impact. “Guard” is the practical check that must pass before release.

| ID | Risk | Why it matters | Guard | Release response |
| --- | --- | --- | --- | --- |
| R1 | A large file is loaded into memory instead of streamed. | A 500GB transfer can freeze or crash either app. | Watch memory during the 500GB gate; it must stay flat while progress advances. | Block release. |
| R2 | A completed transfer is silently corrupted. | The user believes a backup or delivery succeeded when it did not. | Compare source and destination size and checksum for small, large, and folder transfers. | Block release. |
| R3 | A folder transfer loses structure, skips files, or overwrites an existing file. | The receiver gets an incomplete or misleading copy. | Send 60+ nested files with spaces, long names, Unicode, and repeat sends. | Block release. |
| R4 | Sticky clipboard accidentally replaces the system clipboard. | The user pastes the wrong content or loses something they meant to keep. | Verify received text stays in the Sticky slot until the user promotes it. | Block release. |
| R5 | Wispr Flow receives altered text. | Dictation or assistant text loses accents, punctuation, line breaks, or emoji. | Paste the full UTF-8 test string into Wispr Flow and compare it exactly. | Block release. |
| R6 | Sleep, wake, or IP change leaves a dead peer address. | Transfers hang or fail even though both devices are reachable again. | Sleep/wake and change IP, then require rediscovery and a successful send within 30 seconds. | Block release. |
| R7 | Offline failure hangs forever or looks like success. | The user waits for a transfer that will never finish. | Disable the network and confirm visible retry, visible failure, cleanup, and later recovery. | Block release. |
| R8 | Firewall or permission prompts are confusing or unrecoverable. | A normal user cannot make discovery or transfer work. | Fresh-install both platforms; accept and deny prompts and verify each recovery path. | Block release. |
| R9 | The notch/pill breaks across displays or clamshell mode. | The product becomes unusable in common Mac setups. | Test built-in, external-only, and mixed displays, plus lid close/reopen. | Block release. |
| R10 | Sticky captures or delays keyboard input. | This feels invasive, breaks typing/passwords, and violates the no-shortcuts contract. | Type in browser, password field, terminal, editor, and game; confirm no interception or global shortcuts. | Block release. |
| R11 | An unpaired or spoofed device reaches transfer or clipboard endpoints. | Local files and clipboard content could be exposed on the network. | Reject all transfer, clipboard, and info actions before successful pairing; verify unpair removes access. | Block release. |
| R12 | Diagnostics leak private file names, clipboard contents, credentials, or tokens. | A user trying to get help accidentally shares sensitive data. | Create and inspect a support bundle for content-free errors and safe fields only. | Block release. |
| R13 | Uninstall leaves background services, firewall entries, helpers, or MCP registration. | Sticky keeps running or interferes after the user removes it. | Uninstall, restart, inspect active processes/startup/firewall/MCP state, then reinstall fresh. | Block release or document exact removable leftovers with a cleanup step. |
| R14 | Rollback cannot restore the previous working release. | Users are trapped on a broken update. | Upgrade a known-good install, roll back, and retest pairing/transfer/clipboard/discovery. | Block release. |
| R15 | Preview generation blocks or corrupts the transfer queue. | A bad image stops unrelated work. | Send valid, invalid, and large images; queue must continue and previews must fail visibly. | Block release if real transfers stop. |
| R16 | Discovery fallback creates duplicate or stale devices. | The user sends to the wrong-looking or unavailable peer. | Toggle networks and restart services; require one current reachable identity per peer. | Block release if the wrong destination can be selected. |
| R17 | Cancellation leaves partial files, locked sessions, or hidden disk usage. | The receiver cannot tell what arrived and the next transfer may fail. | Cancel mid-transfer, inspect destination/session state, then start a new transfer. | Block release. |

## Risk sign-off

For release, every guard needs a recorded pass, evidence, build SHA, tester, and date. Any blocked gate needs a named owner, a user-visible workaround if one exists, and an explicit release decision.
