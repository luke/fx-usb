import AppKit
import SwiftUI

/// What the mic reports about itself (status packets from fxmic_reader.py, 20 per second).
struct MicStatus: Equatable {
    var effect = -1          // -1 clean, 0...3 effect presets
    var sample = 0           // 0...3
    var buttons: UInt8 = 0   // 1 play (white), 2 sample select, 4 effect select (orange)
    var handle = 0.0         // 0...1
    var effectPending = false, samplePending = false
    var motion = 0.0         // 0...1, how hard the mic is being shaken
}

let effectNames = ["CLEAN","ECHO","SPRING","PIXIE","ROBOT"]
let sampleNames = ["HORN","CLAPS","BELL","F*K"]

/// One snapshot of everything the window shows, refreshed 30 times a second.
struct Snapshot: Equatable {
    var connected = false
    var status = ""
    var level = 0.0
    var mic = MicStatus()
    var recordingSince: Date?
    var muted = false
    var gain = 1
    var useCalls = true
    var bridgeInstalled = true
    var callsName = ""
    var firmware = ""
    var bufferMs = 0.0
    var dropouts = 0
    var lostBlocks = 0
    var speakersOn = false
    var speakersVolume = 0.5
    var speakersDevice = ""
    var outputs: [String] = []
    var feedbackCaught = false
    var pressedSample: Int?
    var buttonsSummary = "Not set up"
    var notice = ""
}

final class MicModel: ObservableObject {
    @Published var snapshot = Snapshot()
    var toggleRecording: () -> Void = {}
    var toggleMute: () -> Void = {}
    var toggleCalls: () -> Void = {}
    var setGain: (Int) -> Void = { _ in }
    var installBridge: () -> Void = {}
    var setEffect: (Int) -> Void = { _ in }
    var pressSample: (Int) -> Void = { _ in }
    var selectSample: (Int) -> Void = { _ in }
    var releaseSample: () -> Void = {}
    var toggleSpeakers: () -> Void = {}
    var setVolume: (Double) -> Void = { _ in }
    var chooseOutput: (String) -> Void = { _ in }
    var openWindow: () -> Void = {}
    var openButtons: () -> Void = {}
    var openSoundSettings: () -> Void = {}
    var quit: () -> Void = {}
}

enum Palette {
    static let paper = Color(red:0.925,green:0.925,blue:0.918)
    static let ink = Color(red:0.07,green:0.07,blue:0.07)
    static let quiet = Color(red:0.52,green:0.52,blue:0.51)
    static let rule = Color(red:0.80,green:0.80,blue:0.79)
    static let orange = Color(red:1.0,green:0.33,blue:0.10)
    static let grille = Color(red:0.47,green:0.47,blue:0.47)
    static let hole = Color(red:0.25,green:0.25,blue:0.25)
    static let body = Color(red:0.95,green:0.95,blue:0.94)
    static let live = Color(red:0.20,green:0.75,blue:0.35)
}

let mono = Font.system(size:10,weight:.medium,design:.monospaced)
func helvetica(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Helvetica Neue",size:size).weight(weight) }

/// The house mark: an M on a 5×5 dot matrix.
let markPattern: [[Bool]] = [
    [true,false,false,false,true],
    [true,true,false,true,true],
    [true,false,true,false,true],
    [true,false,false,false,true],
    [true,false,false,false,true]]

struct DotMark: View {
    var size: CGFloat = 16
    var lit = Palette.ink
    var body: some View {
        Canvas { context, canvas in
            let step = canvas.width/5, dot = step*0.72
            for row in 0..<5 { for col in 0..<5 {
                let rect = CGRect(x:CGFloat(col)*step+(step-dot)/2,y:CGFloat(row)*step+(step-dot)/2,width:dot,height:dot)
                context.fill(Path(ellipseIn:rect),with:.color(markPattern[row][col] ? lit : lit.opacity(0.15)))
            } }
        }.frame(width:size,height:size)
    }
}

func hint(_ s: Snapshot) -> String {
    if !s.connected { return s.status.isEmpty ? "Connect FX MIC with a USB-C cable." : s.status }
    if !s.notice.isEmpty { return s.notice }
    if s.feedbackCaught { return "Feedback caught and filtered. Lower the speakers or point the mic away." }
    if !s.bridgeInstalled { return "Install the FX–USB microphone to use it in calls." }
    if s.muted { return "Muted. Unmute to be heard." }
    if s.mic.handle < 0.02 && s.level < 0.02 { return "Hold the handle to talk. Click the orange button for the next effect." }
    return s.useCalls ? "You're live. In Zoom or Meet, pick \(s.callsName) as the mic." : "You're live. Turn CALLS on to send it to other apps."
}

struct Header: View {
    let snapshot: Snapshot
    var body: some View {
        HStack(spacing:8) {
            DotMark(size:14)
            Text("FX–USB").font(helvetica(15,.medium))
            Spacer()
            HStack(spacing:6) {
                Circle().fill(snapshot.connected ? Palette.live : Palette.rule).frame(width:7,height:7)
                Text(snapshot.connected ? "LIVE" : "OFFLINE").font(mono).foregroundColor(Palette.quiet)
            }
        }
    }
}

struct MainView: View {
    @ObservedObject var model: MicModel
    var body: some View {
        let s = model.snapshot
        VStack(spacing:0) {
            Header(snapshot:s).padding(.horizontal,22).padding(.top,10)
            MicReplica(snapshot:s,model:model).frame(height:340).padding(.top,4)
            Names(model:model).padding(.horizontal,22).padding(.top,6)
            Text(hint(s)).font(helvetica(13)).foregroundColor(s.connected ? Palette.ink : Palette.quiet)
                .frame(maxWidth:.infinity,minHeight:50,alignment:.leading).padding(.horizontal,22)
            ControlGrid(model:model,tile:(380-3)/4)
            OutputRow(model:model).padding(.horizontal,22).padding(.top,12)
            ButtonsRow(model:model).padding(.horizontal,22).padding(.top,8).padding(.bottom,14)
        }
        .frame(width:380)
        .background(Palette.paper)
        .foregroundColor(Palette.ink)
    }
}

/// The menu bar panel: same content without the drawing.
struct PopoverView: View {
    @ObservedObject var model: MicModel
    var body: some View {
        let s = model.snapshot
        VStack(spacing:0) {
            Header(snapshot:s).padding(.horizontal,16).padding(.top,14)
            Names(model:model).padding(.horizontal,16).padding(.top,12)
            Text(hint(s)).font(helvetica(12)).foregroundColor(s.connected ? Palette.ink : Palette.quiet)
                .frame(maxWidth:.infinity,minHeight:46,alignment:.leading).padding(.horizontal,16)
            ControlGrid(model:model,tile:80)
            OutputRow(model:model).padding(.horizontal,16).padding(.top,10)
            ButtonsRow(model:model).padding(.horizontal,16).padding(.top,6).padding(.bottom,10)
            Rectangle().fill(Palette.rule).frame(height:1)
            HStack(spacing:0) {
                FooterLink(title:"WINDOW",action:model.openWindow)
                FooterLink(title:"SOUND SETTINGS",action:model.openSoundSettings)
                FooterLink(title:"QUIT",action:model.quit)
            }.frame(height:34)
        }
        .frame(width:80*4+3)
        .background(Palette.paper)
        .foregroundColor(Palette.ink)
    }
}

/// Effect and sample names; tap either to step to the next one on the mic.
struct Names: View {
    @ObservedObject var model: MicModel
    var body: some View {
        let mic = model.snapshot.mic
        HStack(alignment:.top) {
            Readout(label:"EFFECT",value:effectNames[max(0,min(4,mic.effect+1))],pending:mic.effectPending)
                .onTapGesture { model.setEffect(mic.effect == 3 ? -1 : mic.effect+1) }
            Spacer()
            Readout(label:"SAMPLE",value:sampleNames[max(0,min(3,mic.sample))],pending:mic.samplePending,trailing:true)
                .onTapGesture { model.selectSample((mic.sample+1) % 4) }
        }
    }
}

struct Readout: View {
    let label: String, value: String
    var pending = false, trailing = false
    var body: some View {
        VStack(alignment:trailing ? .trailing : .leading,spacing:3) {
            Text(label).font(mono).foregroundColor(Palette.quiet)
            Text(value).font(helvetica(24,.medium)).opacity(pending ? 0.4 : 1)
        }.contentShape(Rectangle())
    }
}

struct FooterLink: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action:action) { Text(title).font(mono).foregroundColor(Palette.quiet).frame(maxWidth:.infinity,maxHeight:.infinity).contentShape(Rectangle()) }
            .buttonStyle(.plain)
    }
}

/// Offscreen renders (--preview) cannot draw an NSMenu, so they show a plain label instead.
var renderingPreview = false

/// What the mic's controls do on the Mac, and the way into the Buttons window.
struct ButtonsRow: View {
    @ObservedObject var model: MicModel
    var body: some View {
        HStack(spacing:10) {
            Text("BUTTONS").font(mono).foregroundColor(Palette.quiet)
            Text(model.snapshot.buttonsSummary).font(mono).foregroundColor(Palette.ink).lineLimit(1).truncationMode(.tail)
            Spacer(minLength:6)
            Button(action:model.openButtons) { Text("SET UP ›").font(mono).foregroundColor(Palette.ink) }.buttonStyle(.plain)
        }
    }
}

struct OutputRow: View {
    @ObservedObject var model: MicModel
    var body: some View {
        let s = model.snapshot
        HStack(spacing:10) {
            Text("SPEAKERS").font(mono).foregroundColor(Palette.quiet)
            if renderingPreview {
                Text(s.speakersDevice + "  ▾").font(mono).foregroundColor(Palette.ink)
            } else { Menu {
                ForEach(s.outputs,id:\.self) { name in Button(name) { model.chooseOutput(name) } }
            } label: {
                Text(s.speakersDevice.isEmpty ? "No output" : s.speakersDevice).font(mono).foregroundColor(Palette.ink)
            }
            .menuStyle(.borderlessButton).fixedSize() }
            Spacer()
        }
    }
}

/// Two rows of equal tiles with hairline seams: controls on top, readouts below.
struct ControlGrid: View {
    @ObservedObject var model: MicModel
    let tile: CGFloat
    var body: some View {
        let s = model.snapshot
        let lift = -tile*0.05
        VStack(spacing:1) {
            HStack(spacing:1) {
                Tile(label:s.recordingSince.map { "REC " + elapsed($0) } ?? "REC",led:s.recordingSince != nil ? Color.red : nil,size:tile) {
                    if s.recordingSince != nil { RoundedRectangle(cornerRadius:3).fill(Color.red).frame(width:tile*0.22,height:tile*0.22).offset(y:lift) }
                    else { Circle().fill(Color.red).frame(width:tile*0.28,height:tile*0.28).offset(y:lift) }
                }
                .onTapGesture { if s.connected || s.recordingSince != nil { model.toggleRecording() } }
                Tile(label:s.bridgeInstalled ? "CALLS" : "SET UP CALLS",led:s.useCalls && s.bridgeInstalled ? Palette.live : nil,size:tile) {
                    Broadcast(color:s.useCalls ? Palette.ink : Palette.quiet,size:tile*0.46).offset(y:lift)
                }
                .onTapGesture { s.bridgeInstalled ? model.toggleCalls() : model.installBridge() }
                Tile(label:"SPEAKERS",led:s.speakersOn ? (s.feedbackCaught ? Palette.orange : Palette.live) : nil,size:tile) {
                    Knob(value:s.speakersVolume,fill:s.speakersOn ? Palette.ink : Palette.quiet,dot:Palette.paper,size:tile*0.44).offset(y:lift)
                }
                .gesture(KnobGesture(value:s.speakersVolume,tap:model.toggleSpeakers,change:model.setVolume))
                Tile(label:s.muted ? "MUTED" : "MUTE",led:s.muted ? Palette.orange : nil,size:tile) {
                    Rectangle().fill(s.muted ? Palette.orange : Palette.ink).frame(width:tile*0.2,height:tile*0.2).offset(y:lift)
                }
                .onTapGesture { model.toggleMute() }
            }
            HStack(spacing:1) {
                let steps = [1,2,4,8]
                let index = steps.firstIndex(of:s.gain) ?? 0
                Tile(label:"GAIN \(s.gain)×",led:nil,size:tile) {
                    Knob(value:Double(index)/3,fill:Palette.paper,dot:Palette.ink,stroke:true,size:tile*0.44).offset(y:lift)
                }
                .gesture(KnobGesture(value:Double(index)/3,tap:{ model.setGain(steps[(index+1)%4]) },change:{ v in model.setGain(steps[Int((v*3).rounded())]) }))
                Tile(label:"BUFFER MS",led:s.connected ? (s.dropouts == 0 ? Palette.live : Palette.orange) : nil,size:tile) {
                    Text(s.connected ? "\(Int(s.bufferMs.rounded()))" : "–").font(helvetica(tile*0.28,.medium)).offset(y:lift)
                }
                Tile(label:"FIRMWARE",led:nil,size:tile) {
                    Text(s.firmware.isEmpty ? "–" : s.firmware).font(helvetica(tile*0.2,.medium)).offset(y:lift)
                }
                Tile(label:"DROPOUTS",led:nil,size:tile) {
                    Text(s.connected ? "\(s.dropouts)" : "–").font(helvetica(tile*0.28,.medium)).offset(y:lift)
                }
            }
        }
        .background(Palette.rule)
        .overlay(Rectangle().fill(Palette.rule).frame(height:1),alignment:.top)
    }
    func elapsed(_ since: Date) -> String { let t = Int(Date().timeIntervalSince(since)); return String(format:"%02d:%02d",t/60,t%60) }
}

struct Tile<Content: View>: View {
    let label: String
    let led: Color?
    let size: CGFloat
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            Palette.paper
            content()
            VStack {
                HStack { Spacer(); Circle().fill(led ?? Palette.rule).frame(width:6,height:6) }
                Spacer()
                HStack { Text(label).font(.system(size:9,weight:.medium,design:.monospaced)).foregroundColor(Palette.quiet).lineLimit(1); Spacer() }
            }.padding(8)
        }
        .frame(width:size,height:size)
        .contentShape(Rectangle())
    }
}

/// A rotary knob: value 0...1 maps to -135°...+135°, the dot marks the position.
struct Knob: View {
    let value: Double
    let fill: Color
    let dot: Color
    var stroke = false
    let size: CGFloat
    var body: some View {
        let angle = (-135+270*value)*Double.pi/180
        ZStack {
            Circle().fill(fill).frame(width:size,height:size)
            if stroke { Circle().stroke(Palette.ink,lineWidth:1).frame(width:size,height:size) }
            Circle().fill(dot).frame(width:5,height:5)
                .offset(x:CGFloat(sin(angle))*size*0.34,y:-CGFloat(cos(angle))*size*0.34)
        }
    }
}

/// Tap toggles; dragging up or down turns the knob.
struct KnobGesture: Gesture {
    let value: Double
    let tap: () -> Void
    let change: (Double) -> Void
    var body: some Gesture {
        DragGesture(minimumDistance:0)
            .onChanged { g in
                if abs(g.translation.height) > 3 { change(max(0,min(1,value-Double(g.translation.height)/600))) }
            }
            .onEnded { g in if abs(g.translation.height) <= 3 { tap() } }
    }
}

/// Calls glyph: three arcs over a small solid triangle, like a broadcast mark.
struct Broadcast: View {
    let color: Color
    let size: CGFloat
    var body: some View {
        Canvas { c, area in
            let apex = CGPoint(x:area.width/2,y:area.height*0.62)
            for k in 1...3 {
                var arc = Path()
                arc.addArc(center:apex,radius:area.width*(0.08+0.11*CGFloat(k)),startAngle:.degrees(215),endAngle:.degrees(325),clockwise:false)
                c.stroke(arc,with:.color(color),style:StrokeStyle(lineWidth:2,lineCap:.round))
            }
            var tri = Path()
            tri.move(to:CGPoint(x:apex.x,y:apex.y-2))
            tri.addLine(to:CGPoint(x:apex.x+area.width*0.13,y:area.height*0.98))
            tri.addLine(to:CGPoint(x:apex.x-area.width*0.13,y:area.height*0.98))
            tri.closeSubpath()
            c.fill(tri,with:.color(color))
        }
        .frame(width:size,height:size*0.8)
    }
}

/// A drawing of the mic, lit the way the real one is: effect and sample LEDs, buttons,
/// handle position. The grille glows from the bottom up with the voice level.
struct MicReplica: View {
    let snapshot: Snapshot
    var model: MicModel? = nil
    static let w: CGFloat = 186, h: CGFloat = 268, grilleH: CGFloat = 146, top: CGFloat = 18
    var body: some View {
        TimelineView(.animation(minimumInterval:1/30)) { timeline in
            Canvas { context, canvas in
                draw(&context,canvas,timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .overlay(GeometryReader { area in
            // The drawing's buttons work: orange = next effect, middle = next sample, bottom = play.
            let x = (area.size.width-MicReplica.w)/2+10+MicReplica.w-6
            let mic = snapshot.mic
            if let model {
                hitArea(x:x,y:MicReplica.top+22).onTapGesture { model.setEffect(mic.effect == 3 ? -1 : mic.effect+1) }
                hitArea(x:x,y:MicReplica.top+86).onTapGesture { model.selectSample((mic.sample+1) % 4) }
                hitArea(x:x,y:MicReplica.top+MicReplica.grilleH+50).gesture(DragGesture(minimumDistance:0)
                    .onChanged { _ in if snapshot.pressedSample == nil { model.pressSample(mic.sample) } }
                    .onEnded { _ in model.releaseSample() })
            }
        })
    }
    func hitArea(x: CGFloat, y: CGFloat) -> some View {
        Color.clear.contentShape(Rectangle()).frame(width:26,height:36).position(x:x+13,y:y+13)
    }
    func draw(_ c: inout GraphicsContext,_ canvas: CGSize,_ time: Double) {
        let s = snapshot, mic = s.mic
        let w = MicReplica.w, h = MicReplica.h
        let x0 = (canvas.width-w)/2+10, y0 = MicReplica.top
        let grilleH = MicReplica.grilleH
        let offline = !s.connected

        // Handle: a flat wedge hinged where it meets the body; pushing it folds it in.
        let pivot = CGPoint(x:x0+1,y:y0+grilleH+14)
        var lever = Path()
        lever.move(to:CGPoint(x:x0+1,y:y0+20))
        lever.addLine(to:CGPoint(x:x0-34,y:y0+38))
        lever.addLine(to:CGPoint(x:x0-5,y:y0+grilleH+14))
        lever.addLine(to:CGPoint(x:x0+1,y:y0+grilleH+14))
        lever.closeSubpath()
        let angle = Angle.degrees(mic.handle*11)
        let hinge = CGAffineTransform(translationX:pivot.x,y:pivot.y).rotated(by:CGFloat(angle.radians)).translatedBy(x:-pivot.x,y:-pivot.y)
        c.fill(lever.applying(hinge),with:.color(Palette.orange.opacity(offline ? 0.45 : 1)))

        // Body and grille.
        let body = Path(roundedRect:CGRect(x:x0,y:y0,width:w,height:h),cornerRadius:5)
        c.fill(body,with:.color(Palette.body))
        c.stroke(body,with:.color(Palette.rule),lineWidth:1)
        let grille = Path(roundedRect:CGRect(x:x0,y:y0,width:w,height:grilleH),cornerSize:CGSize(width:5,height:5),style:.continuous)
        c.fill(grille,with:.color(Palette.grille))
        let cols = 11, rows = 10
        let litRows = offline || s.muted ? 0 : min(Double(rows),s.level.squareRoot()*Double(rows)*1.1)
        for row in 0..<rows { for col in 0..<cols {
            let fromBottom = Double(rows-1-row)
            let glow = max(0,min(1,litRows-fromBottom))
            let cx = x0+12+CGFloat(col)*12.6, cy = y0+12+CGFloat(row)*13.6
            let hole = Path(ellipseIn:CGRect(x:cx,y:cy,width:9,height:9))
            c.fill(hole,with:.color(Palette.hole))
            if glow > 0 { c.fill(hole,with:.color(Color(red:1,green:0.97,blue:0.9).opacity(0.75*glow))) }
        } }

        // LED windows: effect (top) and sample (bottom), lit like the real ones.
        let blink = Int(time*4)%2 == 0
        for (index,(top,lit,pending)) in [(y0+16,mic.effect,mic.effectPending),(y0+80,mic.sample,mic.samplePending)].enumerated() {
            let pill = Path(roundedRect:CGRect(x:x0+w-24,y:top,width:12,height:54),cornerRadius:6)
            c.fill(pill,with:.color(Color(red:0.36,green:0.36,blue:0.36)))
            for led in 0..<4 {
                let r = CGRect(x:x0+w-21,y:top+5+CGFloat(led)*11.5,width:6,height:6)
                let on = !offline && (led == lit || (pending && blink && led == (lit+1)%4 && index >= 0))
                if on {
                    // The real mic's effect LEDs are red; the sample LEDs are white.
                    let lit = index == 0 ? Color(red:1,green:0.16,blue:0.10) : Color.white
                    c.fill(Path(ellipseIn:r.insetBy(dx:-4,dy:-4)),with:.color(lit.opacity(index == 0 ? 0.35 : 0.25)))
                    c.fill(Path(ellipseIn:r),with:.color(lit))
                } else {
                    c.fill(Path(ellipseIn:r),with:.color(Color(red:0.52,green:0.52,blue:0.52)))
                }
            }
        }

        // Buttons on the right edge (TE's guide): effect (orange), sample select (middle), sample play (bottom).
        let buttons: [(CGFloat,Color,UInt8)] = [(y0+22,Palette.orange,4),(y0+86,Color(red:0.93,green:0.93,blue:0.92),2),(y0+grilleH+50,Color(red:0.85,green:0.85,blue:0.84),1)]
        for (top,color,bit) in buttons {
            let pressed = mic.buttons & bit != 0 || (bit == 1 && s.pressedSample != nil)
            let rect = CGRect(x:x0+w-(pressed ? 3 : 0),y:top,width:pressed ? 9 : 12,height:28)
            let button = Path(roundedRect:rect,cornerRadius:4)
            c.fill(button,with:.color(pressed ? color.opacity(0.75) : color))
            c.stroke(button,with:.color(Color.black.opacity(0.22)),lineWidth:1)
        }

        // Screws, label, cable.
        for (sx,sy) in [(x0+10,y0+grilleH+10),(x0+w-22,y0+grilleH+10),(x0+10,y0+h-22),(x0+w-22,y0+h-22)] {
            c.stroke(Path(ellipseIn:CGRect(x:sx,y:sy,width:12,height:12)),with:.color(Palette.rule),lineWidth:1)
        }
        let cableX = x0+w*0.42
        for rib in 0..<5 {
            c.fill(Path(roundedRect:CGRect(x:cableX-9,y:y0+h+4+CGFloat(rib)*8,width:18,height:5),cornerRadius:2.5),with:.color(Color(red:0.62,green:0.62,blue:0.62)))
        }
        var cable = Path(); cable.move(to:CGPoint(x:cableX,y:y0+h)); cable.addLine(to:CGPoint(x:cableX,y:canvas.height))
        c.stroke(cable,with:.color(Color(red:0.62,green:0.62,blue:0.62)),lineWidth:3)

        // Shake indicator.
        if !offline && mic.motion > 0.08 {
            c.draw(Text("SHAKE").font(mono).foregroundColor(Palette.orange.opacity(min(1,mic.motion*2))),at:CGPoint(x:x0-30,y:y0+h-12))
        }
    }
}

/// Menu bar icon: the dot-matrix M; unlit dots fill in with the voice level.
func menuBarImage(level: Double, connected: Bool, muted: Bool) -> NSImage {
    let size = NSSize(width:18,height:18)
    let image = NSImage(size:size, flipped:true) { _ in
        let step: CGFloat = 3.4, dot: CGFloat = 2.5, origin: CGFloat = 0.9
        let lit = muted ? 0 : Int((min(1,pow(level,0.6)*1.6)*5).rounded())
        for row in 0..<5 { for col in 0..<5 {
            let on = markPattern[row][col] || (connected && 4-row < lit)
            let alpha: CGFloat = !connected ? (markPattern[row][col] ? 0.45 : 0.12) : (on ? 1 : 0.22)
            NSColor.black.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn:NSRect(x:origin+CGFloat(col)*step,y:origin+CGFloat(row)*step,width:dot,height:dot)).fill()
        } }
        return true
    }
    image.isTemplate = true
    return image
}

/// App icon: black rounded square, M lit in white on a 5×5 matrix, centre dot orange.
func renderAppIcon(pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
    let inset = size*0.1, tile = size-2*inset
    NSColor(calibratedWhite:0.07,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:inset,y:inset,width:tile,height:tile),xRadius:tile*0.225,yRadius:tile*0.225).fill()
    let step = tile*0.15, dot = step*0.66, start = inset+(tile-step*5)/2
    for row in 0..<5 { for col in 0..<5 {
        let lit = markPattern[row][col]
        let color: NSColor = row == 2 && col == 2 ? NSColor(calibratedRed:1,green:0.33,blue:0.10,alpha:1) : lit ? .white : NSColor(calibratedWhite:1,alpha:0.16)
        color.setFill()
        let y = start+CGFloat(4-row)*step+(step-dot)/2
        NSBezierPath(ovalIn:NSRect(x:start+CGFloat(col)*step+(step-dot)/2,y:y,width:dot,height:dot)).fill()
    } }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using:.png,properties:[:])
}

/// Writes AppIcon.iconset PNGs for iconutil (used by build.sh).
func writeIconset(_ directory: String) throws {
    try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
    for base in [16,32,128,256,512] {
        for scale in [1,2] {
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try renderAppIcon(pixels:base*scale)?.write(to:URL(fileURLWithPath:directory+"/"+name))
        }
    }
}

final class MainWindow {
    let window: NSWindow
    init(model: MicModel) {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:380,height:640),styleMask:[.titled,.closable,.miniaturizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named:.aqua)
        window.backgroundColor = NSColor(calibratedRed:0.925,green:0.925,blue:0.918,alpha:1)
        window.title = "FX–USB"
        window.contentView = NSHostingView(rootView:MainView(model:model))
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
        window.setFrameAutosaveName("FXUSBMain")
    }
    func show() { NSApp.activate(ignoringOtherApps:true); window.makeKeyAndOrderFront(nil) }
}

/// Renders the window with sample states to PNGs (design review without a screen capture).
@MainActor func renderPreviews(_ directory: String) {
    renderingPreview = true
    let store = ButtonsStore(persist:false)
    store[.handle] = Mapping(action:.assistant,assistant:"Claude",combo:KeyCombo(keyCode:49,flags:CGEventFlags.maskAlternate.rawValue,modifierOnly:false))
    store[.play] = Mapping(action:.voiceNote)
    store.trusted = true
    store.pressed = [.handle]
    let buttonsRenderer = ImageRenderer(content:ButtonsView(store:store))
    buttonsRenderer.scale = 2
    if let image = buttonsRenderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff) {
        try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"\(directory)/buttons.png"))
    } else { print("buttons preview: renderer returned no image") }
    try? FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
    let assistantStore = ButtonsStore(persist:false)
    assistantStore.applyAssistantPreset(); assistantStore.active = "Claude"; assistantStore.voiceOn["Claude"] = true; assistantStore.trusted = true
    let assistantsRenderer = ImageRenderer(content:ButtonsView(store:assistantStore))
    assistantsRenderer.scale = 2
    if let image = assistantsRenderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff) {
        try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"\(directory)/buttons-assistants.png"))
    }
    let devices = ["MacBook Pro Speakers","Studio Display Speakers","External Headphones"]
    let live = Snapshot(connected:true,status:"",level:0.45,mic:MicStatus(effect:1,sample:2,buttons:4,handle:0.6,motion:0.3),
                        recordingSince:Date().addingTimeInterval(-83),gain:2,useCalls:true,callsName:"FX–USB",firmware:"1.1.2",bufferMs:40,speakersOn:true,speakersVolume:0.6,speakersDevice:devices[1],outputs:devices)
    let idle = Snapshot(connected:true,mic:MicStatus(effect:-1,sample:1),firmware:"1.1.2",bufferMs:40,speakersDevice:devices[1],outputs:devices)
    let offline = Snapshot(connected:false,status:"Connect FX–MIC by USB-C and press its handle")
    for (name,snapshot) in [("live",live),("idle",idle),("offline",offline)] {
        let model = MicModel(); model.snapshot = snapshot
        model.snapshot.buttonsSummary = "Handle → Claude · Bottom → voice note"
        for (suffix,view) in [("",AnyView(MainView(model:model))),("-menubar",AnyView(PopoverView(model:model)))] {
            let renderer = ImageRenderer(content:view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff) {
                try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"\(directory)/\(name)\(suffix).png"))
            }
        }
    }
}
