import SwiftUI
import AppKit

let NW: CGFloat = 185, NH: CGFloat = 32, MENUBAR: CGFloat = 33
let SW: CGFloat = 560, SH: CGFloat = 300
let NCX = SW/2
let WARM  = Color(red:1.00, green:0.965, blue:0.898)
let AMBER = Color(red:1.00, green:0.757, blue:0.471)

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

struct Bg: View {
    var body: some View {
        ZStack(alignment:.topLeading){
            LinearGradient(colors:[Color(red:0.09,green:0.17,blue:0.33),
                                   Color(red:0.36,green:0.28,blue:0.45),
                                   Color(red:0.68,green:0.41,blue:0.32)],
                           startPoint:.topLeading,endPoint:.bottomTrailing)
            ForEach(0..<7, id:\.self){ i in
                Capsule().fill(.white.opacity(0.09))
                    .frame(width: CGFloat([210,150,240,120,190,160,130][i]), height: 7)
                    .offset(x: CGFloat([40,250,60,300,90,220,140][i]), y: 66 + CGFloat(i)*32)
            }
            Rectangle().fill(.black.opacity(0.30)).frame(height: MENUBAR)
            HStack(spacing:14){ Image(systemName:"apple.logo").font(.system(size:11))
                Text("Finder").font(.system(size:12.5,weight:.semibold))
                Text("File").font(.system(size:12.5)); Text("Edit").font(.system(size:12.5))
            }.foregroundStyle(.white.opacity(0.95)).padding(.leading,12).frame(height:MENUBAR)
            HStack(spacing:11){ Spacer(); Image(systemName:"battery.75"); Image(systemName:"wifi")
                Text("02:31").font(.system(size:12)) }
                .font(.system(size:11)).foregroundStyle(.white.opacity(0.95))
                .padding(.trailing,12).frame(width:SW,height:MENUBAR)
        }.frame(width:SW,height:SH,alignment:.topLeading)
    }
}

struct Thumb: View {
    var body: some View {
        RoundedRectangle(cornerRadius:5,style:.continuous)
            .fill(LinearGradient(colors:[AMBER, Color(red:0.93,green:0.52,blue:0.50),
                                         Color(red:0.34,green:0.37,blue:0.66)],
                                 startPoint:.topLeading,endPoint:.bottomTrailing))
            .frame(width:52,height:39).shadow(color:.black.opacity(0.45),radius:8,y:4)
    }
}

/// One beat of the observed NameDrop sequence, mapped to what delivers it live.
/// blurDepth: how far down the blur wave has swept (fraction of SH)
/// bloom: the island bloom · droplet: the lens · fileT: 0…1 launch progress
struct Frame: View {
    var blurDepth: CGFloat, blurAmt: CGFloat, bloom: CGFloat, droplet: CGFloat, fileT: CGFloat
    var showFile: Bool = false
    var body: some View {
        ZStack(alignment:.topLeading){
            Bg()
            // ── 1. THE BLUR WAVE (live: NSVisualEffectView.behindWindow + animated maskImage)
            if blurDepth > 0.01 {
                Bg().blur(radius: blurAmt)
                    .saturation(0.8)
                    .brightness(0.06)
                    .mask(LinearGradient(stops:[
                        .init(color:.white,             location: 0),
                        .init(color:.white,             location: max(0, blurDepth-0.34)),
                        .init(color:.white.opacity(0.85), location: max(0, blurDepth-0.25)),
                        .init(color:.white.opacity(0.5),  location: max(0, blurDepth-0.16)),
                        .init(color:.white.opacity(0.15), location: max(0, blurDepth-0.07)),
                        .init(color:.white.opacity(0),    location: blurDepth)],
                        startPoint:.top, endPoint:.bottom))
            }
            // ── 3. THE DROPLET (live: .glassEffect(.clear, in: DropletShape()))
            if droplet > 0.01 {
                let dw = 112*droplet + 42, dh = 82*droplet + 28
                let dy = NH + 7
                Bg().scaleEffect(1.35, anchor:.top).offset(y: -8).brightness(0.10).saturation(1.1)
                    .frame(width:SW,height:SH)
                    .mask(
                        ZStack(alignment:.topLeading){
                            Color.clear
                            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white).frame(width:dw,height:dh)
                                .offset(x:NCX-dw/2,y:dy)
                        }.frame(width:SW,height:SH,alignment:.topLeading)
                    )
                    .opacity(Double(droplet))
                Group {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color(red:1,green:0.45,blue:0.45).opacity(0.22*droplet), lineWidth:3.5)
                        .offset(x:-1.1,y:0.8)
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color(red:0.5,green:0.65,blue:1).opacity(0.22*droplet), lineWidth:3.5)
                        .offset(x:1.1,y:-0.8)
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(WARM.opacity(0.34*droplet), lineWidth:4.5)
                }
                .frame(width:dw,height:dh).offset(x:NCX-dw/2,y:dy)
                .blur(radius:6).blendMode(.plusLighter)
            }
            // ── 2. THE BLOOM (live: our own additive light)
            if bloom > 0.01 {
                Ellipse().fill(RadialGradient(colors:[.white.opacity(0.75*bloom),
                                                      WARM.opacity(0.40*bloom),
                                                      AMBER.opacity(0.12*bloom),
                                                      AMBER.opacity(0.04*bloom),
                                                      AMBER.opacity(0)],
                                              center:.center, startRadius:0, endRadius:210))
                    .frame(width:430,height:250)
                    .offset(x:NCX-215, y:NH-115).blendMode(.plusLighter)
                Ellipse().fill(RadialGradient(colors:[.white.opacity(0.9*bloom),
                                              WARM.opacity(0.35*bloom),
                                              WARM.opacity(0)],
                                              center:.center, startRadius:0, endRadius:70))
                    .frame(width:190,height:90)
                    .offset(x:NCX-95, y:NH-32).blendMode(.plusLighter)
            }
            // ── 4. the file, posting up through it
            if showFile {
                let y0: CGFloat = 205, y1: CGFloat = -46
                let N = 40
                ForEach(0..<N, id:\.self){ i in
                    let t = max(0, fileT - 0.16 + 0.16*CGFloat(i)/CGFloat(N-1))
                    let e = t*t*t
                    let y = y0 + (y1-y0)*e
                    if t <= 1 { Thumb().opacity(1.6/CGFloat(N)).offset(x:NCX-26, y:y) }
                }
            }
            // the hardware — always black, always on top, camera region never carries content
            NotchSil().fill(.black).frame(width:NW,height:NH).offset(x:NCX-NW/2,y:0)
            NotchSil().stroke(WARM.opacity(0.9*bloom), lineWidth:1.1)
                .frame(width:NW,height:NH).offset(x:NCX-NW/2,y:0)
                .blur(radius:1.0).blendMode(.plusLighter)
        }.frame(width:SW,height:SH,alignment:.topLeading).clipped()
    }
}

struct Cell<V:View>: View {
    var n:String, t:String
    @ViewBuilder var body_:V
    var body: some View {
        VStack(alignment:.leading,spacing:0){
            body_
            HStack(spacing:7){
                Text(n).font(.system(size:9.5,weight:.medium,design:.monospaced)).foregroundStyle(AMBER)
                Text(t).font(.system(size:10.5,weight:.medium)).foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal:false,vertical:true)
            }.padding(.horizontal,12).padding(.vertical,10).frame(width:SW,alignment:.leading)
        }.background(Color(red:0.05,green:0.055,blue:0.065))
         .clipShape(RoundedRectangle(cornerRadius:8,style:.continuous))
    }
}

@MainActor func render<V:View>(_ v:V,_ p:String,_ s:CGFloat){
    let r=ImageRenderer(content:v); r.scale=s
    if let i=r.nsImage,let t=i.tiffRepresentation,let b=NSBitmapImageRep(data:t),
       let png=b.representation(using:.png,properties:[:]){ try? png.write(to:URL(fileURLWithPath:p)) }
}

@MainActor func go(){
    let board = VStack(spacing:14){
        VStack(alignment:.leading,spacing:5){
            Text("Sticky v14 — v11's composition, the lens as a soft square")
                .font(.system(size:15,weight:.bold)).foregroundStyle(.white)
            Text("The picked direction: v11's blur wave + bloom + v7's launch, with the lens a soft continuous-corner square. Both screens glow simultaneously; the PC end mirrors this (see MOTION.md).")
                .font(.system(size:11)).foregroundStyle(.white.opacity(0.5))
        }.frame(width:SW*2+14,alignment:.leading)
        LazyVGrid(columns:[GridItem(.fixed(SW),spacing:14),GridItem(.fixed(SW),spacing:14)],spacing:14){
            Cell(n:"0 ms",  t:"rest — nothing"){ Frame(blurDepth:0,blurAmt:0,bloom:0,droplet:0,fileT:0) }
            Cell(n:"150 ms",t:"contact — the top begins to blur away, faint glow at the aperture"){
                Frame(blurDepth:0.22,blurAmt:9,bloom:0.28,droplet:0,fileT:0) }
            Cell(n:"320 ms",t:"the wave descends, bloom grows — the screen is being washed"){
                Frame(blurDepth:0.46,blurAmt:16,bloom:0.62,droplet:0,fileT:0) }
            Cell(n:"480 ms",t:"the droplet — a lens forms under the aperture, dispersing its edges"){
                Frame(blurDepth:0.62,blurAmt:20,bloom:0.8,droplet:1,fileT:0) }
            Cell(n:"640 ms",t:"the file posts up through the droplet into the slot"){
                Frame(blurDepth:0.62,blurAmt:20,bloom:0.8,droplet:0.85,fileT:1, showFile:true) }
            Cell(n:"950 ms",t:"the wave lifts — everything sharpens back, nothing remains"){
                Frame(blurDepth:0.14,blurAmt:6,bloom:0.1,droplet:0,fileT:0) }
        }
    }.padding(18).background(Color(red:0.025,green:0.028,blue:0.035))
    render(board,"v14.png",1.7); print("wrote v14.png")
}
MainActor.assumeIsolated { go() }
