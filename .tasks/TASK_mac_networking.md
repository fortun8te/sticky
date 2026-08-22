# BUILD: macOS Networking Services
Work dir: /Users/michael/Documents/sticky/macos/Sticky/Sources/Services/
Read protocol: /Users/michael/Documents/sticky/docs/PROTOCOL.md
Read shared types: /Users/michael/Documents/sticky/macos/Sticky/Sources/Models/TransferTypes.swift

Create these Swift files:

## DiscoveryService.swift
- NWBrowser for `_sticky._tcp.local.` via Network.framework
- UDP broadcast fallback to 255.255.255.255:53317 with JSON announce
- Maintain `[StickyDevice]` peer list with 30s expiry timer
- Re-announce on: app launch, NWPathMonitor network change
- Publish peers via @Published var for UI binding

## TransferService.swift  
- HTTPS server using NWListener on port 53317
- Endpoints per protocol spec: pair, info, prepare-upload, upload, complete, cancel, clipboard
- Self-signed TLS cert generated at first launch (SecKeyCreateRandomKey)
- Binary chunked streaming for uploads (64KB chunks)
- Save received files to ~/Downloads/Sticky/
- Parallel upload support
- Progress callback for UI updates

## PairingService.swift
- Generate self-signed cert (SecKeyCreateRandomKey + SecCertificateCreateWithData)
- 6-digit PIN display/verify flow
- Store pinned peer cert SHA-256 in UserDefaults/Keychain
- Mutual TLS after pairing

Make all files compile-ready with proper error handling and async/await.
Do NOT create notch UI files (already exists).
