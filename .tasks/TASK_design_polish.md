# REVIEW & POLISH: Notch UI Design Quality
Work dir: /Users/michael/Documents/sticky/macos/Sticky/Sources/Views/
Read existing: NotchView.swift, Models/TransferTypes.swift

Review the notch UI against these quality bars:
1. NameDrop magnetic animation — two rounded panels expand toward each other with ripple
2. Dynamic Island pill morphing — smooth spring transitions between states
3. Liquid Glass aesthetic — translucent materials, subtle blur, depth
4. Notchy-style drag shelf — clean file staging with image previews
5. Clipboard history — scrollable list inside expanded notch

Create:
- ShelfView.swift (drag-and-drop file shelf with thumbnails, drag-out support)
- ClipboardHistoryView.swift (scrollable sticky clipboard entries)
- RippleEffect.swift (Metal shader or Canvas-based water ripple for transfer animation)

Ensure all animations use proper spring curves (response ~0.42, dampingFraction ~0.82).
Every state transition should feel physical and Apple-quality.
No jank. No lag. No keyboard capture.
