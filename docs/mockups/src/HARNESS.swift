// Shared harness. COPY this into your concept file and build on it.
// Build: xcrun swiftc -O -target arm64-apple-macos26.0 yourfile.swift -o yourbin && ./yourbin
import SwiftUI
import AppKit

// MEASURED on the target machine — do not change these.
let NW: CGFloat = 185, NH: CGFloat = 32, MENUBAR: CGFloat = 33
let SW: CGFloat = 520, SH: CGFloat = 300
let NX = (SW-NW)/2, NCX = SW/2

/// The exact hardware notch silhouette. Concave shoulders. Never resize it.
struct NotchSil: Shape {
    func path(in r: CGRect) -> Path {
        let tR: CGFloat = 6, bR: CGFloat = 13
        var p = Path()
        p.move(to: CGPoint(x: r.minX - tR, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY+tR), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY-bR))
        p.addQuadCurve(to: CGPoint(x: r.minX+bR, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX-bR, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY-bR), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY+tR))
        p.addQuadCurve(to: CGPoint(x: r.maxX+tR, y: r.minY), control: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath(); return p
    }
}

/// Desktop + menu bar. The menu bar must stay legible in EVERY frame.
struct Bg: View {
    var body: some View {
        ZStack(alignment:.topLeading){
            LinearGradient(colors:[Color(red:0.10,green:0.18,blue:0.34),
                                   Color(red:0.34,green:0.27,blue:0.44),
                                   Color(red:0.64,green:0.39,blue:0.31)],
                           startPoint:.topLeading, endPoint:.bottomTrailing)
            Rectangle().fill(.black.opacity(0.30)).frame(height: MENUBAR)
            HStack(spacing:14){ Image(systemName:"apple.logo").font(.system(size:11))
                Text("Finder").font(.system(size:12.5,weight:.semibold))
                Text("File").font(.system(size:12.5)); Text("Edit").font(.system(size:12.5))
            }.foregroundStyle(.white.opacity(0.95)).padding(.leading,12).frame(height:MENUBAR)
            HStack(spacing:11){ Spacer(); Image(systemName:"battery.75"); Image(systemName:"wifi")
                Text("00:41").font(.system(size:12)) }
                .font(.system(size:11)).foregroundStyle(.white.opacity(0.95))
                .padding(.trailing,12).frame(width:SW,height:MENUBAR)
        }.frame(width:SW,height:SH,alignment:.topLeading)
    }
}

/// A realistic photo thumbnail — the thing being sent. Not a placeholder card.
struct Thumb: View {
    var w: CGFloat = 54, h: CGFloat = 40
    var body: some View {
        RoundedRectangle(cornerRadius: 5, style:.continuous)
            .fill(LinearGradient(colors:[Color(red:0.96,green:0.72,blue:0.42),
                                         Color(red:0.86,green:0.42,blue:0.44),
                                         Color(red:0.32,green:0.35,blue:0.62)],
                                 startPoint:.topLeading,endPoint:.bottomTrailing))
            .overlay(ZStack{
                Circle().fill(.white.opacity(0.55)).frame(width:w*0.17,height:w*0.17).offset(x:w*0.22,y:-h*0.2)
                Path{p in p.move(to:CGPoint(x:0,y:h*0.85)); p.addLine(to:CGPoint(x:w*0.3,y:h*0.4))
                          p.addLine(to:CGPoint(x:w*0.55,y:h*0.85)); p.closeSubpath()}
                    .fill(.black.opacity(0.22))
            }.clipShape(RoundedRectangle(cornerRadius:5,style:.continuous)))
            .overlay(RoundedRectangle(cornerRadius:5,style:.continuous).stroke(.white.opacity(0.35),lineWidth:0.8))
            .frame(width: w, height: h)
    }
}

struct Cell<V:View>: View {
    var n:String, t:String, accent: Color
    @ViewBuilder var body_:V
    var body: some View {
        VStack(alignment:.leading,spacing:0){
            body_
            HStack(spacing:7){
                Text(n).font(.system(size:9.5,weight:.medium,design:.monospaced)).foregroundStyle(accent)
                Text(t).font(.system(size:11,weight:.medium)).foregroundStyle(.white.opacity(0.72))
            }.padding(.horizontal,12).padding(.vertical,10).frame(width:SW,alignment:.leading)
        }.background(Color(red:0.05,green:0.055,blue:0.065))
         .clipShape(RoundedRectangle(cornerRadius:8,style:.continuous))
    }
}

@MainActor func render<V:View>(_ v:V,_ path:String,_ scale:CGFloat = 1.7){
    let r = ImageRenderer(content:v); r.scale = scale
    if let i=r.nsImage, let t=i.tiffRepresentation, let b=NSBitmapImageRep(data:t),
       let png=b.representation(using:.png,properties:[:]) {
        try? png.write(to:URL(fileURLWithPath:path)); print("wrote \(path)")
    }
}
