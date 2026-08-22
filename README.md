# Sticky

Sticky is a local-first Mac ↔ Windows transfer gateway with a native macOS notch experience.
Drop files or folders on the notch to send them to your PC; the PC can send back without
taking over either machine’s system clipboard.

## Product rules

- Bidirectional transfers work from day one.
- The system clipboard is never silently replaced. Received text enters Sticky’s own slot and history.
- No global keyboard capture and no focus stealing.
- Discovery, pairing, and transfers stay on the private LAN. There are no cloud relays or telemetry.
- Sleep/wake, display changes, and IP changes recover without restarting the app.
- Motion is restrained and physical: magnetic pull, directional filament handoff, completion ripple.
- Reduced-motion settings replace flight and ripple effects with clear opacity/state changes.

## Build and run

### macOS

```bash
./scripts/build-macos.sh
"$(cd macos && swift build --show-bin-path)/Sticky"
```

For a launchable `.app` bundle:

```bash
./scripts/package-macos.sh
open "$HOME/Applications/Sticky.app"
```

The packaged app is deliberately written outside iCloud-backed Documents so
macOS can keep its signature valid after Finder launches it.

### Windows

On Windows with .NET 8:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-windows.ps1
powershell -ExecutionPolicy Bypass -File scripts/package-windows.ps1
```

The packaged executable is written to `build/release/win-x64`.

### Validation

```bash
./scripts/validate.sh
```

This runs Swift tests, builds the WPF client when .NET is available, type-checks the MCP bridge,
and verifies QA tooling.

## Network and permissions

- Discovery and transport use TCP/UDP port `53317`.
- Allow Sticky only on private networks. Do not expose it through a public network or port forwarding.
- macOS may ask for Local Network permission. Sticky does not require Accessibility for v1.
- Windows may show a private-network firewall prompt on first launch.

## QA

`tools/e2e/sticky_e2e.py` creates fixtures with hashes, records evidence for all 16 release cases,
verifies received trees, and produces a readiness report:

```bash
python3 tools/e2e/sticky_e2e.py doctor
python3 tools/e2e/sticky_e2e.py fixture --profile standard --output /tmp/sticky-fixtures
python3 tools/e2e/sticky_e2e.py record --run-dir /tmp/sticky-run --case XFER-MW-001 --status pass --notes 'hashes match'
python3 tools/e2e/sticky_e2e.py report --run-dir /tmp/sticky-run
```

A release is not ready until every case in `docs/E2E_TEST_PLAN.md` passes or has an explicit,
tracked product exception.
