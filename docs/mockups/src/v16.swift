import SwiftUI
import AppKit

let NW: CGFloat = 185, NH: CGFloat = 32, MENUBAR: CGFloat = 33
let SW: CGFloat = 560, SH: CGFloat = 300
let TASKBAR: CGFloat = 44
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

struct MacBg: View {
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
                Text("03:58").font(.system(size:12)) }
                .font(.system(size:11)).foregroundStyle(.white.opacity(0.95))
                .padding(.trailing,12).frame(width:SW,height:MENUBAR)
        }.frame(width:SW,height:SH,alignment:.topLeading)
    }
}

struct WinBg: View {
    var body: some View {
        ZStack(alignment:.topLeading){
            LinearGradient(colors:[Color(red:0.07,green:0.09,blue:0.17),
                                   Color(red:0.13,green:0.13,blue:0.24),
                                   Color(red:0.19,green:0.16,blue:0.27)],
                           startPoint:.topLeading,endPoint:.bottomTrailing)
            RoundedRectangle(cornerRadius:8, style:.continuous)
                .fill(Color(white:0.13).opacity(0.95))
                .frame(width:330,height:150)
                .overlay(alignment:.topLeading){
                    VStack(alignment:.leading, spacing:0){
                        Color.clear.frame(height:24)
                        ForEach(0..<4, id:\.self){ i in
                            HStack(spacing:8){
                                RoundedRectangle(cornerRadius:2).fill(.white.opacity(0.20)).frame(width:11,height:11)
                                Rectangle().fill(.white.opacity(0.13))
                                    .frame(width:CGFloat([150,96,168,120][i]), height:6).clipShape(Capsule())
                                Spacer()
                            }.padding(.horizontal,12).frame(height:24)
                        }
                        Spacer()
                    }
                }
                .offset(x:44,y:30)
            Rectangle().fill(.black.opacity(0.55)).frame(width:SW,height:TASKBAR).offset(y:SH-TASKBAR)
            HStack(spacing:11){
                ForEach(0..<8, id:\.self){ i in
                    RoundedRectangle(cornerRadius:5,style:.continuous)
                        .fill(.white.opacity(i==2 ? 0.34 : 0.18)).frame(width:19,height:19)
                }
            }.frame(width:SW,height:TASKBAR).offset(y:SH-TASKBAR)
        }.frame(width:SW,height:SH,alignment:.topLeading)
    }
}

/// Soft radial spokes: light travelling along lines through a focus point.
/// inner…outer are distances from the focus; bright end is the INNER end.
struct BottomMask: View {
    var body: some View {
        VStack(spacing:0){
            Rectangle().fill(.white).frame(height: SH-TASKBAR-6)
            LinearGradient(colors:[.white, .white.opacity(0)],
                           startPoint:.top, endPoint:.bottom).frame(height:6)
            Color.clear.frame(height: TASKBAR)
        }.frame(width:SW,height:SH)
    }
}

struct Spokes: View {
    var focus: CGPoint, angles: [CGFloat], inner: CGFloat, outer: CGFloat, i: CGFloat
    var clipBottom: Bool = false
    var body: some View {
        ZStack(alignment:.topLeading){
            ForEach(0..<angles.count, id:\.self){ k in
                let a = angles[k]
                let len = max(outer - inner, 10)
                let mid = CGPoint(x: focus.x + cos(a)*(inner+outer)/2,
                                  y: focus.y + sin(a)*(inner+outer)/2)
                Capsule().fill(LinearGradient(stops:[
                        .init(color:WARM.opacity(0.40*i),  location:0),
                        .init(color:WARM.opacity(0.22*i),  location:0.35),
                        .init(color:AMBER.opacity(0.07*i), location:0.75),
                        .init(color:AMBER.opacity(0),      location:1)],
                        startPoint:.leading, endPoint:.trailing))
                    .frame(width: len, height: 42)
                    .rotationEffect(.radians(Double(a)), anchor:.center)
                    .position(x: mid.x, y: mid.y)
                    .blur(radius: 16)
            }
        }.frame(width:SW,height:SH,alignment:.topLeading)
         .mask(Group{ if clipBottom { AnyView(BottomMask()) } else { AnyView(Rectangle().fill(.white).frame(width:SW,height:SH)) } })
         .blendMode(.plusLighter)
    }
}

struct Ring: View {
    var c: CGPoint, R: CGFloat, i: CGFloat
    var clipBottom: Bool = false
    var body: some View {
        Circle().stroke(WARM.opacity(0.26*i), lineWidth: 130)
            .frame(width:R*2,height:R*2).position(x:c.x,y:c.y)
            .blur(radius: 42)
            .frame(width:SW,height:SH,alignment:.topLeading)
            .mask(Group{ if clipBottom { AnyView(BottomMask()) } else { AnyView(Rectangle().fill(.white).frame(width:SW,height:SH)) } })
            .blendMode(.plusLighter)
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

// ── MAC · INTAKE — everything converges into the notch ────
struct MacFrame: View {
    var beat: Int   // 1 charge · 2 converge · 3 swallowed
    var body: some View {
        let notch = CGPoint(x: NCX, y: NH)
        let angles: [CGFloat] = [0.45, 0.85, 1.20, 1.57, 1.94, 2.29, 2.69]  // fan below
        let inner: CGFloat = [190, 80, 26][beat-1]
        let outer: CGFloat = [430, 300, 120][beat-1]
        let si:    CGFloat = [0.40, 1.0, 0.5][beat-1]
        let ringR: CGFloat = [380, 190, 70][beat-1]
        let ringI: CGFloat = [0.32, 1.0, 0.6][beat-1]
        let bloom: CGFloat = [0.14, 0.6, 1.0][beat-1]
        let blurD: CGFloat = [0.30, 0.52, 0.60][beat-1]
        let fileT: CGFloat = [0, 0.55, 0.97][beat-1]
        ZStack(alignment:.topLeading){
            MacBg()
            MacBg().blur(radius: 8+8*blurD).saturation(0.85).brightness(0.05)
                .mask(LinearGradient(stops:[
                    .init(color:.white,               location: 0),
                    .init(color:.white,               location: max(0, blurD-0.34)),
                    .init(color:.white.opacity(0.85), location: max(0, blurD-0.25)),
                    .init(color:.white.opacity(0.5),  location: max(0, blurD-0.16)),
                    .init(color:.white.opacity(0.15), location: max(0, blurD-0.07)),
                    .init(color:.white.opacity(0),    location: blurD)],
                    startPoint:.top, endPoint:.bottom))
            Spokes(focus: notch, angles: angles, inner: inner, outer: outer, i: si)
            Ring(c: notch, R: ringR, i: ringI)
            // bloom gathers AT the aperture — brightest as everything arrives
            Ellipse().fill(RadialGradient(stops:[
                    .init(color:.white.opacity(0.60*bloom), location:0),
                    .init(color:WARM.opacity(0.32*bloom),   location:0.34),
                    .init(color:AMBER.opacity(0.10*bloom),  location:0.66),
                    .init(color:AMBER.opacity(0),           location:1)],
                    center:.center, startRadius:0, endRadius:170))
                .frame(width:340,height:190).offset(x:NCX-170,y:NH-88)
                .blendMode(.plusLighter)
            // the file, pulled in with the light (ease-IN)
            if fileT > 0.01 && fileT < 0.96 {
                let y0: CGFloat = 210, y1: CGFloat = NH - 20
                let N = 36
                ForEach(0..<N, id:\.self){ i in
                    let tt = max(0, fileT - 0.15 + 0.15*CGFloat(i)/CGFloat(N-1))
                    let e = tt*tt*tt
                    if tt <= 1 { Thumb().opacity(1.5/CGFloat(N)).offset(x:NCX-26, y: y0+(y1-y0)*e) }
                }
            }
            NotchSil().fill(.black).frame(width:NW,height:NH).offset(x:NCX-NW/2,y:0)
            NotchSil().stroke(WARM.opacity(0.65*bloom), lineWidth:1.1)
                .frame(width:NW,height:NH).offset(x:NCX-NW/2,y:0)
                .blur(radius:1.2).blendMode(.plusLighter)
        }.frame(width:SW,height:SH,alignment:.topLeading).clipped()
    }
}

// ── WINDOWS · EXHAUST — it erupts from the bottom edge ────
struct WinFrame: View {
    var beat: Int   // 1 ignition · 2 eruption · 3 settle
    var body: some View {
        let mouth = CGPoint(x: NCX, y: SH - TASKBAR - 4)
        let angles: [CGFloat] = [-0.45, -0.85, -1.20, -1.57, -1.94, -2.29, -2.69] // fan upward
        let inner: CGFloat = [8, 40, 150][beat-1]
        let outer: CGFloat = [90, 330, 480][beat-1]
        let si:    CGFloat = [0.9, 1.0, 0.35][beat-1]
        let ringR: CGFloat = [40, 200, 360][beat-1]
        let ringI: CGFloat = [0.8, 0.9, 0.30][beat-1]
        let bloom: CGFloat = [1.0, 0.7, 0.2][beat-1]
        let fileT: CGFloat = [0.05, 0.6, 1.0][beat-1]
        ZStack(alignment:.topLeading){
            WinBg()
            Spokes(focus: mouth, angles: angles, inner: inner, outer: outer, i: si, clipBottom: true)
            Ring(c: mouth, R: ringR, i: ringI, clipBottom: true)
            Ellipse().fill(RadialGradient(stops:[
                    .init(color:.white.opacity(0.62*bloom), location:0),
                    .init(color:WARM.opacity(0.33*bloom),   location:0.32),
                    .init(color:AMBER.opacity(0.11*bloom),  location:0.64),
                    .init(color:AMBER.opacity(0),           location:1)],
                    center:.center, startRadius:0, endRadius:180))
                .frame(width:360,height:200).offset(x:NCX-180, y:SH-TASKBAR-118)
                .mask(BottomMask())
                .blendMode(.plusLighter)
            Capsule().fill(.white.opacity(0.85*max(bloom, 0.3*si))).frame(width:NW-24,height:1.6)
                .blur(radius:1.1).offset(x:NCX-(NW-24)/2, y:SH-TASKBAR-6).blendMode(.plusLighter)
            // the file, fired OUT — fast at first, decelerating (ease-OUT)
            if fileT > 0.02 {
                let y0 = SH - TASKBAR - 16, y1: CGFloat = 92
                let N = 36
                ForEach(0..<N, id:\.self){ i in
                    let tt = max(0, fileT - 0.16 + 0.16*CGFloat(i)/CGFloat(N-1))
                    let e = 1 - pow(1-min(tt,1), 3)
                    if tt <= 1 { Thumb().opacity(1.5/CGFloat(N)).offset(x:NCX-26, y: y0+(y1-y0)*e) }
                }
            }
        }.frame(width:SW,height:SH,alignment:.topLeading).clipped()
    }
}

// ── the seam, both machines in frame at the peak instant ──
struct Hero: View {
    var body: some View {
        VStack(spacing:0){
            ZStack(alignment:.bottom){ WinFrame(beat:2) }
                .frame(width:SW, height:150, alignment:.bottom).clipped()
            LinearGradient(colors:[Color(white:0.10),Color(white:0.02),Color(white:0.02),Color(white:0.11)],
                           startPoint:.top,endPoint:.bottom).frame(width:SW,height:24)
            ZStack(alignment:.top){ MacFrame(beat:2) }
                .frame(width:SW, height:150, alignment:.top).clipped()
        }
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
                Text(t).font(.system(size:10.5,weight:.medium)).foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal:false,vertical:true)
            }.padding(.horizontal,12).padding(.vertical,9).frame(width:SW,alignment:.leading)
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
    let board = VStack(alignment:.leading, spacing:14){
        VStack(alignment:.leading,spacing:5){
            Text("Sticky v16 — the gateway: intake and exhaust")
                .font(.system(size:15,weight:.bold)).foregroundStyle(.white)
            Text("The Mac is the intake — every glow on the screen converges INTO the notch, spokes and ring collapsing inward. Windows is the exhaust — it erupts from the bottom edge outward. One directional throughput, like a gate firing between two systems.")
                .font(.system(size:11)).foregroundStyle(.white.opacity(0.5))
                .frame(width:SW*3+28, alignment:.leading)
        }
        HStack(alignment:.top, spacing:14){
            Cell(n:"seam", t:"the peak instant — Windows erupting above, the Mac swallowing below"){ Hero() }
            VStack(spacing:14){
                Cell(n:"mac · 200 ms", t:"charge — the field gathers, spokes reach in"){ MacFrame(beat:1) }
            }
            VStack(spacing:14){
                Cell(n:"win · 200 ms", t:"ignition — the sill flares, compact and hot"){ WinFrame(beat:1) }
            }
        }
        HStack(spacing:14){
            Cell(n:"mac · 450 ms", t:"converge — everything is drawn into the aperture"){ MacFrame(beat:2) }
            Cell(n:"mac · 700 ms", t:"swallowed — the last light closes in"){ MacFrame(beat:3) }
            Cell(n:"win · 450 ms", t:"eruption — spokes and ring burst outward, the file rides them"){ WinFrame(beat:2) }
        }
        HStack(spacing:14){
            Cell(n:"win · 700 ms", t:"settle — the wavefront expands and fades, the file lands"){ WinFrame(beat:3) }
        }
    }.padding(18).background(Color(red:0.025,green:0.028,blue:0.035))
    render(board,"v16.png",1.5); print("wrote v16.png")
}
MainActor.assumeIsolated { go() }
