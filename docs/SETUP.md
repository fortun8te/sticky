# Sticky Setup

## Requirements

- Both computers on the same trusted home/office network. Do not use guest, public, hotel, or captive-portal Wi-Fi.
- Disable VPNs during discovery/transfers unless the VPN explicitly allows local LAN traffic.
- Allow local network access when macOS asks. Keep UDP/TCP 53317 open only on private firewall profiles.
- Incoming files are written to `~/Downloads/Sticky`.

## macOS

1. Open `~/Applications/Sticky.app` from the packaged build.
2. Approve the **Local Network** prompt if macOS shows one.
3. Allow Sticky in **Firewall** settings if macOS asks. No Accessibility or Automation permission is required.
4. Drag files onto the notch or the menu-bar icon. If the PC is offline, they stay in Sticky's queue and send automatically later.

### Advanced: run from source

1. Install Xcode command-line tools: `xcode-select --install`.
2. Build: `./scripts/build-macos.sh`.
3. Launch the executable path printed by the script.

Sticky does not use global shortcuts, keyboard injection, Accessibility, or Automation.

macOS firewall can be enabled from System Settings; add Sticky as an allowed incoming app if prompted. No router port forwarding is needed.

## Windows

1. Install the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).
2. Build: `powershell -ExecutionPolicy Bypass -File scripts/build-windows.ps1`.
3. Launch `windows/StickyWin/bin/Release/net8.0-windows/StickyWin.exe`.
4. When Windows asks, allow access on **Private networks** only. If no prompt appears, run PowerShell as administrator once:

```powershell
New-NetFirewallRule -DisplayName "Sticky TCP 53317" -Direction Inbound -Protocol TCP -LocalPort 53317 -Action Allow -Profile Private
New-NetFirewallRule -DisplayName "Sticky UDP 53317" -Direction Inbound -Protocol UDP -LocalPort 53317 -Action Allow -Profile Private
netsh http add urlacl url=http://+:53317/api/v1/ user="$env:USERDOMAIN\$env:USERNAME"
```

The URL reservation lets the pill listen without running Sticky as administrator. Remove it if you uninstall: `netsh http delete urlacl url=http://+:53317/api/v1/`.

## MCP bridge

1. Start the native Sticky app first.
2. Install and check the bridge: `./scripts/check-mcp.sh`.
3. Open Sticky once, then run it with an MCP client using stdio: `./scripts/start-mcp.sh`.

The bridge talks only to `127.0.0.1:53318`; do not open that loopback endpoint to other hosts. Its requests require Sticky's local control token.

## Release checks

Run `docs/MANUAL_QA.md` end to end after every protocol, transfer, clipboard, or networking change.
