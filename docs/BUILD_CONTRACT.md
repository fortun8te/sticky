# Sticky Build Contract

## Product
- Native macOS notch gateway plus native Windows pill.
- Bidirectional LAN transfers, separate Sticky clipboard, drag shelf, and MCP bridge.
- No global keyboard shortcuts in v1. No focus stealing. No cloud dependency.

## Shared protocol
- Discovery: Bonjour `_sticky._tcp.local.` on TCP 53317, UDP broadcast fallback on 53317.
- Transfer: HTTPS/TLS endpoints under `/api/v1`: `pair`, `info`, `prepare-upload`, `upload`, `complete`, `cancel`, `clipboard`.
- JSON field names exactly match `docs/PROTOCOL.md`.
- Incoming files go to `~/Downloads/Sticky`, preserving relative paths and collision-safe names.
- Large files stream; never buffer an entire file in memory.

## Platform contracts
- macOS is Swift 5.9 / SwiftUI / AppKit in `macos/Sticky`.
- Windows is .NET 8 WPF in `windows/StickyWin`.
- MCP bridge is TypeScript in `mcp` and talks only to the local app API.

## Integration rules
- One owner per file. Do not edit outside your assigned scope.
- Keep public names stable: `StickyDevice`, `TransferRequest`, `PrepareResponse`, `CompleteResponse`, `NotchState`, `NotchViewModel`, `DiscoveryService`, `TransferService`, `ClipboardService`, `PairingService`.
- Every service must start/stop cleanly and publish user-visible failures instead of silently swallowing them.
- UI states are idle, hover, armed, sending, receiving, success, failure, expanded shelf/history.
- Motion must feel physical and continuous: magnetic pull, filament handoff, ripple completion, restrained failure shake.

## Definition of done for this pass
- macOS debug build succeeds.
- Windows project builds where .NET SDK is available.
- TypeScript typecheck/build succeeds.
- Core transfer, discovery, clipboard, pairing, and UI state paths have focused tests or explicit manual verification steps.
