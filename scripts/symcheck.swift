import AppKit
let names = [
 // portal states
 "arrow.down.to.line","arrow.up.to.line","checkmark","exclamationmark.triangle.fill",
 "arrow.left.arrow.right","paperplane.fill","xmark","arrow.clockwise",
 // devices
 "macbook","pc","desktopcomputer","laptopcomputer","display",
 "macbook.and.iphone","desktopcomputer.and.macbook",
 // direction
 "arrow.up.right","arrow.down.left","arrow.right","arrow.left",
 "chevron.up","chevron.down",
 // file kinds
 "folder.fill","music.note","film.fill","doc.richtext.fill","photo.fill",
 "doc.zipper","doc.fill","text.document.fill","square.and.arrow.up.fill",
 // menu
 "gearshape.fill","link","link.badge.plus","bolt.horizontal.circle.fill",
 "wifi.slash","clock.arrow.circlepath","tray.full.fill","tray.and.arrow.down.fill",
 "tray.and.arrow.up.fill","power","questionmark.circle","externaldrive.badge.wifi",
 // status / states
 "circle.fill","circle.dotted","exclamationmark.circle.fill","checkmark.circle.fill",
 "arrow.trianglehead.2.clockwise.rotate.90","hourglass","pause.circle.fill",
 // extras
 "sparkles","lock.fill","lock.open.fill","key.fill","shield.lefthalf.filled",
 "square.stack.3d.up.fill","square.on.square.dashed","plus","minus",
 "arrow.down.doc.fill","arrow.up.doc.fill","externaldrive.connected.to.line.below.fill"
]
var ok = [String](); var bad = [String]()
for n in names {
    if NSImage(systemSymbolName: n, accessibilityDescription: nil) != nil { ok.append(n) } else { bad.append(n) }
}
print("RESOLVED \(ok.count)/\(names.count)")
if !bad.isEmpty { print("\nMISSING:"); bad.forEach { print("  ✗ \($0)") } }
