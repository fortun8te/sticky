# BUILD: Windows C# .NET 8 Tray App
Work dir: /Users/michael/Documents/sticky/windows/StickyWin/
Read protocol: /Users/michael/Documents/sticky/docs/PROTOCOL.md

Create a complete .NET 8 console app project:

## StickyWin.csproj
- net8.0-windows target
- NuGet: Zeroconf, System.CommandLine
- ApplicationIcon for tray

## Program.cs
- Entry point, Mutex single-instance check
- NotifyIcon system tray with context menu (Send to Mac, Settings, Exit)

## DiscoveryService.cs
- Zeroconf mDNS browse for _sticky._tcp.local.
- UDP broadcast fallback on port 53317
- Peer list with 30s expiry, re-announce on network change

## TransferService.cs
- HttpListener on https://0.0.0.0:53317/
- All protocol endpoints: pair, info, prepare-upload, upload, complete, cancel, clipboard
- Self-signed TLS cert
- Stream file chunks to Downloads/Sticky/

## PairingService.cs
- Self-signed cert gen (CertificateRequest API)
- 6-digit PIN verify
- Cert pinning store in %APPDATA%/Sticky/

## ClipboardService.cs
- Clipboard monitor via AddClipboardFormatListener
- Sticky clipboard history (last 20 entries)
- Push text changes to Mac peer
- Receive into sticky slot (not system clipboard)

## ShellContextMenu.cs
- Register "Send to Sticky" in Windows Explorer context menu via registry

## ToastNotification.cs
- Windows toast for incoming files using Microsoft.Toolkit.Uwp.Notifications
