import SwiftUI
import AppKit

let NW: CGFloat = 185, NH: CGFloat = 32, MENUBAR: CGFloat = 33
let SW: CGFloat = 520, SH: CGFloat = 300
let NCX = SW/2
let WARM  = Color(red:1.00, green:0.965, blue:0.898)
let AMBER = Color(red:1.00, green:0.757, blue:0.471)

struct NotchSil: Shape {
    var topR: CGFloat = 6, botR: CGFloat = 13
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX - topR, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY+topR), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY-botR))
        p.addQuadCurve(to: CGPoint(x: r.minX+botR, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX-botR, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY-botR), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY+tRv))
        p.addQuadCurve(to: CGPoint(x: r.maxX+topR, y: r.minY), control: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath(); return p
    }
    var tRv: CGFloat { topR }
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
                Text("03:19").font(.system(size:12)) }
                .font(.system(size:11)).foregroundStyle(.white.opacity(0.95))
                .padding(.trailing,12).frame(width:SW,height:MENUBAR)
        }.frame(width:SW,height:SH,alignment:.topLeading)
    }
}

struct BlurWave: View {
    var depth: CGFloat, amt: CGFloat
    var body: some View {
        if depth > 0.01 {
            Bg().blur(radius: amt).saturation(0.85).brightness(0.05)
                .mask(LinearGradient(stops:[
                    .init(color:.white,               location: 0),
                    .init(color:.white,               location: max(0, depth-0.34)),
                    .init(color:.white.opacity(0.85), location: max(0, depth-0.25)),
                    .init(color:.white.opacity(0.5),  location: max(0, depth-0.16)),
                    .init(color:.white.opacity(0.15), location: max(0, depth-0.07)),
                    .init(color:.white.opacity(0),    location: depth)],
                    startPoint:.top, endPoint:.bottom))
        }
    }
}

struct Bloom: View {
    var i: CGFloat
    var body: some View {
        if i > 0.01 {
            Ellipse().fill(RadialGradient(stops:[
                    .init(color:.white.opacity(0.42*i), location:0),
                    .init(color:WARM.opacity(0.24*i),   location:0.34),
                    .init(color:AMBER.opacity(0.09*i),  location:0.64),
                    .init(color:AMBER.opacity(0.03*i),  location:0.84),
                    .init(color:AMBER.opacity(0),       location:1)],
                    center:.center, startRadius:0, endRadius:190))
                .frame(width:380,height:210)
                .offset(x:NCX-190, y:NH-95).blendMode(.plusLighter)
        }
    }
}

/// Generic glass body: refracted backdrop + soft rim + soft chroma + top sheen.
struct Glass: View {
    var shape: AnyShape, w: CGFloat, h: CGFloat, x: CGFloat, y: CGFloat
    var fade: CGFloat = 1
    var body: some View {
        ZStack(alignment:.topLeading){
            Bg().scaleEffect(1.38, anchor:.top).offset(y:-4)
                .brightness(0.11).saturation(1.1)
                .frame(width:SW,height:SH)
                .mask(ZStack(alignment:.topLeading){
                    Color.clear
                    shape.fill(.white).frame(width:w,height:h).offset(x:x,y:y)
                }.frame(width:SW,height:SH,alignment:.topLeading))
                .opacity(Double(0.92*fade))
            shape.stroke(WARM.opacity(0.34*fade), lineWidth: 5)
                .frame(width:w,height:h).offset(x:x,y:y)
                .blur(radius: 6).blendMode(.plusLighter)
            shape.stroke(Color(red:1,green:0.5,blue:0.5).opacity(0.14*fade), lineWidth: 3)
                .frame(width:w,height:h).offset(x:x-1.2,y:y+0.8)
                .blur(radius: 5).blendMode(.plusLighter)
            shape.stroke(Color(red:0.55,green:0.68,blue:1).opacity(0.14*fade), lineWidth: 3)
                .frame(width:w,height:h).offset(x:x+1.2,y:y-0.8)
                .blur(radius: 5).blendMode(.plusLighter)
            // top sheen — a linear wash, not a glint blob
            LinearGradient(stops:[
                    .init(color:.white.opacity(0.28*fade), location:0),
                    .init(color:.white.opacity(0.08*fade), location:0.45),
                    .init(color:.white.opacity(0),         location:1)],
                    startPoint:.top, endPoint:.bottom)
                .frame(width:w,height:min(h,26)).offset(x:x,y:y)
                .mask(ZStack(alignment:.topLeading){ Color.clear
                    shape.fill(.white).frame(width:w,height:h).offset(x:x,y:y)
                }.frame(width:SW,height:SH,alignment:.topLeading))
                .blendMode(.plusLighter)
        }
    }
}

// ── the three light treatments ────────────────────────────
struct VeilLight: View {
    var i: CGFloat, front: CGFloat
    var body: some View {
        let L = 1 - front
        Ellipse().fill(RadialGradient(stops:[
                .init(color:WARM.opacity(0.44*i),  location:0),
                .init(color:WARM.opacity(0.24*i),  location:0.36),
                .init(color:AMBER.opacity(0.10*i), location:0.66),
                .init(color:AMBER.opacity(0.03*i), location:0.86),
                .init(color:AMBER.opacity(0),      location:1)],
                center:.center, startRadius:0, endRadius:SH*1.15))
            .frame(width:SW*2.3, height:SH*2.3)
            .offset(x:NCX-SW*1.15, y:NH-SH*1.15)
            .mask(LinearGradient(stops:[
                .init(color:.white.opacity(0),    location: max(0, L-0.20)),
                .init(color:.white.opacity(0.3),  location: min(1, L+0.05)),
                .init(color:.white.opacity(0.75), location: min(1, L+0.25)),
                .init(color:.white,               location: min(1, L+0.45)),
                .init(color:.white,               location: 1)],
                startPoint:.top, endPoint:.bottom))
            .blendMode(.plusLighter)
    }
}
struct RayPair: View {
    var i: CGFloat, reach: CGFloat
    var body: some View {
        let len: CGFloat = 373
        let ray = Capsule().fill(LinearGradient(stops:[
                .init(color:AMBER.opacity(0),      location:0),
                .init(color:AMBER.opacity(0.14*i), location:0.30),
                .init(color:WARM.opacity(0.30*i),  location:0.75),
                .init(color:WARM.opacity(0.42*i),  location:1)],
                startPoint:.leading, endPoint:.trailing))
            .frame(width: len*reach, height: 150)
            .blur(radius: 34)
            .rotationEffect(.radians(-0.80), anchor:.leading)
            .offset(x: -6, y: SH - 75 - 40)
        ZStack(alignment:.topLeading){
            ray
            ZStack(alignment:.topLeading){ Color.clear; ray }
                .frame(width:SW,height:SH,alignment:.topLeading)
                .scaleEffect(x:-1, y:1, anchor:.center)
        }.blendMode(.plusLighter)
    }
}
struct TideRing: View {
    var i: CGFloat, r: CGFloat
    var body: some View {
        let R = 470*(1-r) + 66
        ZStack(alignment:.topLeading){
            Circle().stroke(WARM.opacity(0.30*i), lineWidth: 150)
                .frame(width:R*2,height:R*2).offset(x:NCX-R,y:NH-R)
                .blur(radius: 44)
            Circle().stroke(AMBER.opacity(0.12*i), lineWidth: 270)
                .frame(width:R*2,height:R*2).offset(x:NCX-R,y:NH-R)
                .blur(radius: 70)
        }.blendMode(.plusLighter)
    }
}

/// variant 1 · ISLAND — a rounded-rect glass plate AROUND the notch (the iPhone
/// Liquid Glass widget look). variant 2 · CHIP — a compact square lens floating
/// below. variant 3 · THROAT — the notch itself extends, lower half turns glass.
struct Frame: View {
    var variant: Int, beat: Int
    var body: some View {
        let depth: CGFloat = [0.14, 0.42, 0.36][beat-1]
        let amt:   CGFloat = [6, 14, 11][beat-1]
        let bloom: CGFloat = [0.16, 0.44, 0.30][beat-1]
        let g:     CGFloat = [0, 1, 1][beat-1]
        let d:     CGFloat = [0, 0, 1][beat-1]
        let fade  = 1 - 0.45*d
        ZStack(alignment:.topLeading){
            Bg()
            BlurWave(depth: depth, amt: amt)
            switch variant {
            case 1: VeilLight(i: [0.8, 1, 0.4][beat-1], front: [0.42, 1, 0.8][beat-1])
            case 2: RayPair(i: [0.85, 1, 0.38][beat-1], reach: [0.55, 1, 1][beat-1])
            default: TideRing(i: [0.8, 1, 0.32][beat-1], r: [0.3, 0.9, 1][beat-1])
            }
            Bloom(i: bloom)
            if g > 0.01 {
                switch variant {
                case 1:  // ISLAND: plate wider than the notch, notch sits inside it
                    let w = NW + 30 + 46*g + 24*d, h = NH + 30 + 42*g + 18*d
                    Glass(shape: AnyShape(RoundedRectangle(cornerRadius: 26, style: .continuous)),
                          w: w, h: h, x: NCX - w/2, y: 5, fade: fade)
                case 2:  // CHIP: compact near-square lens below the notch
                    let w = 112 + 44*g + 22*d, h = 94 + 34*g + 16*d
                    Glass(shape: AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous)),
                          w: w, h: h, x: NCX - w/2, y: NH + 9, fade: fade)
                default: // THROAT: the notch extends; its extension is the glass
                    let w = NW + 14*g, h = NH + 16 + 48*g + 14*d
                    ZStack(alignment:.topLeading){
                        NotchSil(topR: 8, botR: 22).fill(.black.opacity(0.5*Double(fade)))
                            .frame(width:w,height:h).offset(x:NCX-w/2,y:0)
                        Glass(shape: AnyShape(NotchSil(topR: 8, botR: 22)),
                              w: w, h: h, x: NCX - w/2, y: 0, fade: fade*0.85)
                    }
                }
            }
            NotchSil().fill(.black).frame(width:NW,height:NH).offset(x:NCX-NW/2,y:0)
            NotchSil().stroke(WARM.opacity(0.6*bloom), lineWidth:1.1)
                .frame(width:NW,height:NH).offset(x:NCX-NW/2,y:0)
                .blur(radius:1.2).blendMode(.plusLighter)
        }.frame(width:SW,height:SH,alignment:.topLeading).clipped()
    }
}

struct Cell<V:View>: View {
    var t:String
    @ViewBuilder var body_:V
    var body: some View {
        VStack(alignment:.leading,spacing:0){
            body_
            Text(t).font(.system(size:10.5,weight:.medium)).foregroundStyle(.white.opacity(0.68))
                .padding(.horizontal,12).padding(.vertical,9)
                .frame(width:SW,alignment:.leading)
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
    let beats = ["light rises, screen-wide","converges — the glass forms","disperses back out — glass melts away"]
    let vars: [(Int,String,String,String)] = [
        (1,"v13a.png","A · ISLAND","a rounded-rect glass plate around the notch — the Liquid Glass widget look; quiet veil light"),
        (2,"v13b.png","B · CHIP","a compact square lens floating just below the aperture; corner-ray light"),
        (3,"v13c.png","C · THROAT","the notch itself extends and its lower half becomes glass; contracting-ring light")]
    for (v, file, name, note) in vars {
        let board = VStack(alignment:.leading, spacing:10){
            HStack(spacing:10){
                Text(name).font(.system(size:14,weight:.bold,design:.monospaced)).foregroundStyle(AMBER)
                Text(note).font(.system(size:11.5)).foregroundStyle(.white.opacity(0.55))
            }
            HStack(spacing:14){
                ForEach(1...3, id:\.self){ b in Cell(t: beats[b-1]){ Frame(variant: v, beat: b) } }
            }
        }.padding(18).background(Color(red:0.025,green:0.028,blue:0.035))
        render(board, file, 1.6)
        print("wrote \(file)")
    }
}
MainActor.assumeIsolated { go() }
