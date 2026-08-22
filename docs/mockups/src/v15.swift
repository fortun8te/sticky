import SwiftUI
import AppKit

// Windows 27" — we show the BOTTOM slice, because that edge faces the Mac.
let SW: CGFloat = 560, SH: CGFloat = 300
let TASKBAR: CGFloat = 44          // Win11 taskbar, centred icons
let MOUTH_W: CGFloat = 185         // aligned to the Mac's notch width
let NCX = SW/2
let WARM  = Color(red:1.00, green:0.965, blue:0.898)   // #FFF6E5
let AMBER = Color(red:1.00, green:0.757, blue:0.471)   // #FFC178

struct WinBg: View {
    var body: some View {
        ZStack(alignment:.topLeading){
            LinearGradient(colors:[Color(red:0.07,green:0.09,blue:0.17),
                                   Color(red:0.13,green:0.13,blue:0.24),
                                   Color(red:0.19,green:0.16,blue:0.27)],
                           startPoint:.topLeading,endPoint:.bottomTrailing)
            // an app window, so the wash has real content to act on
            RoundedRectangle(cornerRadius:8, style:.continuous)
                .fill(Color(white:0.13).opacity(0.95))
                .frame(width:330,height:150)
                .overlay(alignment:.topLeading){
                    VStack(alignment:.leading, spacing:0){
                        HStack{ Spacer()
                            ForEach(0..<3, id:\.self){ _ in
                                Rectangle().fill(.white.opacity(0.28)).frame(width:9,height:1.4).padding(.horizontal,5)
                            }
                        }.frame(height:26)
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
                .offset(x:44,y:34)
            // taskbar — centred icons, must stay legible in every frame
            Rectangle().fill(.black.opacity(0.55)).frame(width:SW,height:TASKBAR).offset(y:SH-TASKBAR)
            HStack(spacing:11){
                ForEach(0..<8, id:\.self){ i in
                    RoundedRectangle(cornerRadius:5,style:.continuous)
                        .fill(.white.opacity(i==2 ? 0.34 : 0.18)).frame(width:19,height:19)
                }
            }.frame(width:SW,height:TASKBAR).offset(y:SH-TASKBAR)
            HStack(spacing:9){ Spacer()
                Image(systemName:"wifi"); Image(systemName:"speaker.wave.2.fill")
                Text("03:41").font(.system(size:10.5))
            }.font(.system(size:9.5)).foregroundStyle(.white.opacity(0.72))
             .padding(.trailing,12).frame(width:SW,height:TASKBAR).offset(y:SH-TASKBAR)
        }.frame(width:SW,height:SH,alignment:.topLeading)
    }
}

/// Blur wave — rises UPWARD from the contact edge (the bottom), mirroring the Mac.
struct WinBlurWave: View {
    var depth: CGFloat, amt: CGFloat        // depth measured from the bottom
    var body: some View {
        if depth > 0.01 {
            let L = 1 - depth
            WinBg().blur(radius: amt).saturation(0.85).brightness(0.05)
                .mask(LinearGradient(stops:[
                    .init(color:.white.opacity(0),    location: max(0, L)),
                    .init(color:.white.opacity(0.15), location: min(1, L+0.07)),
                    .init(color:.white.opacity(0.5),  location: min(1, L+0.16)),
                    .init(color:.white.opacity(0.85), location: min(1, L+0.25)),
                    .init(color:.white,               location: min(1, L+0.34)),
                    .init(color:.white,               location: 1)],
                    startPoint:.top, endPoint:.bottom))
                // HARD RULE: the taskbar is never washed. Unlike the Mac's menu
                // bar (grazed briefly), Windows chrome sits exactly on the seam.
                .mask(VStack(spacing:0){
                    Rectangle().fill(.white).frame(height: SH-TASKBAR-6)
                    LinearGradient(colors:[.white, .white.opacity(0)],
                                   startPoint:.top, endPoint:.bottom).frame(height:6)
                    Color.clear.frame(height: TASKBAR)
                }.frame(width:SW,height:SH))
        }
    }
}

struct WinBloom: View {
    var i: CGFloat
    var body: some View {
        if i > 0.01 {
            Ellipse().fill(RadialGradient(stops:[
                    .init(color:.white.opacity(0.60*i), location:0),
                    .init(color:WARM.opacity(0.33*i),   location:0.32),
                    .init(color:AMBER.opacity(0.12*i),  location:0.62),
                    .init(color:AMBER.opacity(0.04*i),  location:0.82),
                    .init(color:AMBER.opacity(0),       location:1)],
                    center:.center, startRadius:0, endRadius:200))
                .frame(width:420,height:240)
                .offset(x:NCX-210, y:SH-TASKBAR-136).blendMode(.plusLighter)
        }
    }
}

/// The PC has no notch — its mouth is LIGHT: a sill line at the screen edge,
/// above the taskbar, aligned to the Mac's notch width.
struct WinSill: View {
    var i: CGFloat
    var body: some View {
        if i > 0.01 {
            let y = SH - TASKBAR - 5
            Capsule().fill(WARM.opacity(0.30*i)).frame(width:MOUTH_W+34,height:16)
                .blur(radius:11).offset(x:NCX-(MOUTH_W+34)/2, y:y-7).blendMode(.plusLighter)
            Capsule().fill(.white.opacity(0.88*i)).frame(width:MOUTH_W-24,height:1.6)
                .blur(radius:1.1).offset(x:NCX-(MOUTH_W-24)/2, y:y).blendMode(.plusLighter)
        }
    }
}

/// Same lens as the Mac: soft continuous-corner square, refracting the backdrop.
struct WinLens: View {
    var g: CGFloat, d: CGFloat
    var body: some View {
        if g > 0.01 {
            let w = 112*g + 42 + 18*d, h = 82*g + 28 + 14*d
            let fade = 1 - 0.5*d
            let y = SH - TASKBAR - h - 10
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            ZStack(alignment:.topLeading){
                WinBg().scaleEffect(1.42, anchor:.bottom).offset(y:6)
                    .brightness(0.13).saturation(1.12)
                    .frame(width:SW,height:SH)
                    .mask(ZStack(alignment:.topLeading){ Color.clear
                        shape.fill(.white).frame(width:w,height:h).offset(x:NCX-w/2,y:y)
                    }.frame(width:SW,height:SH,alignment:.topLeading))
                    .opacity(Double(fade))
                Group{
                    shape.stroke(Color(red:1,green:0.45,blue:0.45).opacity(0.22*fade), lineWidth:3.5)
                        .offset(x:-1.1,y:0.8)
                    shape.stroke(Color(red:0.5,green:0.65,blue:1).opacity(0.22*fade), lineWidth:3.5)
                        .offset(x:1.1,y:-0.8)
                    shape.stroke(WARM.opacity(0.34*fade), lineWidth:4.5)
                }
                .frame(width:w,height:h).offset(x:NCX-w/2,y:y)
                .blur(radius:6).blendMode(.plusLighter)
            }
        }
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

/// Arrival: the file emerges from the sill and rises INTO the screen — same
/// vector as it left the Mac, decelerating (ease-OUT) because it is landing.
struct WinArrive: View {
    var t: CGFloat          // 0…1
    var body: some View {
        if t > 0.001 {
            let y0 = SH - TASKBAR - 20, y1 = SH - TASKBAR - 150
            let N = 40
            ZStack{
                ForEach(0..<N, id:\.self){ i in
                    let tt = max(0, t - 0.18 + 0.18*CGFloat(i)/CGFloat(N-1))
                    let e = 1 - pow(1-tt, 3)
                    if tt <= 1 { Thumb().opacity(1.6/CGFloat(N)).offset(x:NCX-26, y: y0 + (y1-y0)*e) }
                }
            }
        }
    }
}

struct Frame: View {
    var beat: Int
    var body: some View {
        let depth: CGFloat = [0, 0.22, 0.46, 0.46, 0.40, 0.12][beat]
        let amt:   CGFloat = [0, 9, 16, 16, 13, 6][beat]
        let bloom: CGFloat = [0, 0.30, 0.66, 0.82, 0.5, 0.08][beat]
        let sill:  CGFloat = [0, 0.45, 0.85, 1.0, 0.6, 0.10][beat]
        let g:     CGFloat = [0, 0, 1, 1, 1, 0][beat]
        let d:     CGFloat = [0, 0, 0, 0, 1, 0][beat]
        let arr:   CGFloat = beat == 3 ? 1 : 0
        ZStack(alignment:.topLeading){
            WinBg()
            WinBlurWave(depth: depth, amt: amt)
            WinBloom(i: bloom)
            WinLens(g: g, d: d)
            WinArrive(t: arr)
            WinSill(i: sill)
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
    let beats = [("0 ms","rest — the 27\" bottom edge, taskbar untouched"),
                 ("150 ms","the Mac commits — this edge blooms in the SAME frame"),
                 ("320 ms","the wave rises upward; sill at the screen edge"),
                 ("480 ms","the lens forms — same soft square as the Mac"),
                 ("640 ms","the file rises in, decelerating; lens disperses"),
                 ("950 ms","rest — the taskbar was never washed, nothing remains")]
    let board = VStack(alignment:.leading, spacing:14){
        VStack(alignment:.leading,spacing:5){
            Text("Sticky — the Windows end of the same moment")
                .font(.system(size:15,weight:.bold)).foregroundStyle(.white)
            Text("Bottom slice of the 27\", which is the edge facing the MacBook. No notch, so the mouth is LIGHT, not a cutout — a sill at the screen edge aligned to the Mac's 185 pt notch width. The blur wave rises upward because the seam is below. Same warm white → amber, same soft square lens, same beats and timings. HARD RULE: the taskbar is never washed — unlike the Mac's menu bar, Windows chrome sits exactly on the seam.")
                .font(.system(size:11)).foregroundStyle(.white.opacity(0.5))
                .frame(width:SW*2+14, alignment:.leading)
        }
        LazyVGrid(columns:[GridItem(.fixed(SW),spacing:14),GridItem(.fixed(SW),spacing:14)],spacing:14){
            ForEach(0..<6, id:\.self){ b in Cell(n:beats[b].0, t:beats[b].1){ Frame(beat: b) } }
        }
    }.padding(18).background(Color(red:0.025,green:0.028,blue:0.035))
    render(board,"v15.png",1.6); print("wrote v15.png")
}
MainActor.assumeIsolated { go() }
