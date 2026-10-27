import AppKit
import ApplicationServices
import SwiftUI

/// The mic's four controls, and what each one does on the mic itself.
enum Control: String, CaseIterable, Codable, Identifiable {
    case handle, effect, sample, play
    var id: String { rawValue }
    var name: String { ["handle":"Handle","effect":"Orange button","sample":"Middle button","play":"Bottom button"][rawValue]! }
    var micJob: String { ["handle":"talk","effect":"next effect","sample":"next sample","play":"play sample"][rawValue]! }
    /// Bit in the status packet's button byte (and in the mic's block mask). The handle has none.
    var bit: UInt8 { ["handle":0,"effect":4,"sample":2,"play":1][rawValue]! }
}

enum MacAction: String, CaseIterable, Codable, Identifiable {
    case none, assistant, voiceNote, keys, shortcut, previousAssistant, nextAssistant, voiceToggle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Nothing, mic only"
        case .assistant: return "Talk to an assistant"
        case .voiceNote: return "Record a voice note"
        case .keys: return "Press a keyboard shortcut"
        case .shortcut: return "Run a Shortcut"
        case .previousAssistant: return "Previous assistant"
        case .nextAssistant: return "Next assistant"
        case .voiceToggle: return "Toggle voice chat"
        }
    }
    /// Actions that last as long as the control is held.
    var holds: Bool { self == .assistant || self == .voiceNote }
}

let assistants = ["ChatGPT","Claude","Siri","Dictation","my assistant"]

/// A key combination, or a single modifier key held on its own.
struct KeyCombo: Codable, Equatable {
    var keyCode: Int
    var flags: UInt64      // CGEventFlags: command, option, control, shift
    var modifierOnly: Bool
    static let modifierKeys: [(code: Int, flag: CGEventFlags, symbol: String)] = [
        (59,.maskControl,"⌃"),(58,.maskAlternate,"⌥"),(56,.maskShift,"⇧"),(55,.maskCommand,"⌘")]
    var label: String {
        if modifierOnly { return KeyCombo.names[keyCode] ?? "Key \(keyCode)" }
        let mods = KeyCombo.modifierKeys.filter { flags & $0.flag.rawValue != 0 }.map { $0.symbol }.joined()
        return mods + (mods.isEmpty ? "" : " ") + (KeyCombo.names[keyCode] ?? "Key \(keyCode)")
    }
    static let names: [Int:String] = {
        var n: [Int:String] = [36:"Return",48:"Tab",49:"Space",51:"Delete",53:"Esc",54:"Right ⌘",55:"⌘",56:"⇧",57:"Caps Lock",
            58:"⌥",59:"⌃",60:"Right ⇧",61:"Right ⌥",62:"Right ⌃",63:"fn",115:"Home",116:"Page Up",117:"⌦",119:"End",121:"Page Down",
            123:"←",124:"→",125:"↓",126:"↑",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",
            103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19"]
        let letters: [(Int,String)] = [(0,"A"),(11,"B"),(8,"C"),(2,"D"),(14,"E"),(3,"F"),(5,"G"),(4,"H"),(34,"I"),(38,"J"),(40,"K"),(37,"L"),
            (46,"M"),(45,"N"),(31,"O"),(35,"P"),(12,"Q"),(15,"R"),(1,"S"),(17,"T"),(32,"U"),(9,"V"),(13,"W"),(7,"X"),(16,"Y"),(6,"Z"),
            (29,"0"),(18,"1"),(19,"2"),(20,"3"),(21,"4"),(23,"5"),(22,"6"),(26,"7"),(28,"8"),(25,"9"),(27,"-"),(24,"="),(33,"["),(30,"]"),
            (41,";"),(39,"'"),(43,","),(47,"."),(44,"/"),(42,"\\"),(50,"`")]
        for (code,name) in letters { n[code] = name }
        return n
    }()
}

struct Mapping: Codable, Equatable {
    var action: MacAction = .none
    var assistant = "Claude"
    var combo: KeyCombo?
    var shortcutName = ""
    var cleanVoice = true        // assistant: effects off while held (on by default)
    var cleanNote = false        // voice note: effects off while held
    var alsoOnMic = false        // buttons: keep the mic's own action too
    var clean: Bool { action == .assistant ? cleanVoice : action == .voiceNote ? cleanNote : false }
}

/// Mappings, kept in UserDefaults, shared by the Buttons window and the engine.
final class ButtonsStore: ObservableObject {
    @Published var mappings: [Control:Mapping] { didSet { save() } }
    @Published var pressed: Set<Control> = []
    @Published var trusted = AXIsProcessTrusted()
    @Published var shortcuts: [String] = []
    @Published var notice = ""
    @Published var assistants: [Assistant] { didSet { saveAssistants() } }
    @Published var active: String { didSet { if persist { UserDefaults.standard.set(active,forKey:"activeAssistant") } } }
    @Published var voiceOn: [String:Bool] = [:]
    private let persist: Bool
    init(persist: Bool = true) {
        self.persist = persist
        var loaded: [Control:Mapping] = [:]
        if persist, let data = UserDefaults.standard.data(forKey:"buttonMappings"),
           let decoded = try? JSONDecoder().decode([String:Mapping].self,from:data) {
            for (key,value) in decoded { if let control = Control(rawValue:key) { loaded[control] = value } }
        }
        mappings = loaded
        assistants = persist ? (UserDefaults.standard.data(forKey:"assistantList").flatMap { try? JSONDecoder().decode([Assistant].self,from:$0) } ?? Assistant.defaults) : Assistant.defaults
        active = persist ? UserDefaults.standard.string(forKey:"activeAssistant") ?? "" : ""
    }
    subscript(control: Control) -> Mapping {
        get { mappings[control] ?? Mapping() }
        set { mappings[control] = newValue }
    }
    private func save() {
        guard persist else { return }
        let plain = Dictionary(uniqueKeysWithValues:mappings.map { ($0.key.rawValue,$0.value) })
        if let data = try? JSONEncoder().encode(plain) { UserDefaults.standard.set(data,forKey:"buttonMappings") }
    }
    private func saveAssistants() {
        guard persist else { return }
        if let data = try? JSONEncoder().encode(assistants) { UserDefaults.standard.set(data,forKey:"assistantList") }
    }
    static let assistantActions: Set<MacAction> = [.previousAssistant,.nextAssistant,.voiceToggle]
    var usesAssistants: Bool { Control.allCases.contains { ButtonsStore.assistantActions.contains(self[$0].action) } }
    /// "Active: Claude · voice off", shown beside the buttons summary while the buttons drive assistants.
    var assistantLine: String { active.isEmpty ? "" : "Active: \(active) · voice \(voiceOn[active] == true ? "on" : "off")" }
    /// One click: orange = previous assistant, middle = next assistant, bottom = toggle voice chat. The handle is left as it is.
    func applyAssistantPreset() {
        self[.effect] = Mapping(action:.previousAssistant)
        self[.sample] = Mapping(action:.nextAssistant)
        self[.play] = Mapping(action:.voiceToggle)
        notice = "Assistant buttons are set up."
    }
    /// Buttons whose mic action is switched off (bits for the mic's block mask).
    var blockMask: UInt8 {
        Control.allCases.filter { $0 != .handle && self[$0].action != .none && !self[$0].alsoOnMic }.reduce(0) { $0 | $1.bit }
    }
    var summary: String {
        let used = Control.allCases.filter { self[$0].action != .none }
        guard !used.isEmpty else { return "Not set up" }
        return used.map { control -> String in
            let m = self[control]
            let what: String
            switch m.action {
            case .assistant: what = m.assistant
            case .voiceNote: what = "voice note"
            case .keys: what = m.combo?.label ?? "shortcut"
            case .previousAssistant: what = "previous assistant"
            case .nextAssistant: what = "next assistant"
            case .voiceToggle: what = "voice chat"
            default: what = m.shortcutName.isEmpty ? "Shortcut" : m.shortcutName
            }
            return "\(control == .handle ? "Handle" : control.name.replacingOccurrences(of:" button",with:"")) → \(what)"
        }.joined(separator:" · ")
    }
    func refreshTrust(prompt: Bool = false) {
        if prompt { trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue():true] as CFDictionary) }
        else { trusted = AXIsProcessTrusted() }
    }
    func loadShortcuts() {
        DispatchQueue.global().async {
            let names = (try? runTool("/usr/bin/shortcuts",["list"]))?.split(separator:"\n").map(String.init).filter { !$0.isEmpty } ?? []
            DispatchQueue.main.async { self.shortcuts = names.sorted() }
        }
    }
}

@discardableResult func runTool(_ path: String, _ arguments: [String]) throws -> String {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath:path); process.arguments = arguments; process.standardOutput = pipe
    try process.run(); process.waitUntilExit()
    return String(data:pipe.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
}

/// Turns presses on the mic into actions on the Mac.
final class ButtonEngine {
    let store: ButtonsStore
    let send: (String) -> Void
    let startVoiceNote: () -> Bool
    let stopVoiceNote: () -> String?
    private var down: Set<Control> = []
    private var restoreEffect: [Control:Int] = [:]
    private var heldCombo: [Control:KeyCombo] = [:]
    private var noteOwner: Control?
    private var sentMask: UInt8?
    /// Swapped out by the self-test so it never presses real keys.
    lazy var keyPoster: (KeyCombo, Bool) -> Void = { [unowned self] combo, isDown in self.postCombo(combo,down:isDown) }
    /// Assistant cycling and the voice toggle; its taps go through `keyPoster`.
    lazy var router = AssistantRouter(store:store,tap:{ [unowned self] combo in self.keyPoster(combo,true); self.keyPoster(combo,false) })
    init(store: ButtonsStore, send: @escaping (String) -> Void, startVoiceNote: @escaping () -> Bool, stopVoiceNote: @escaping () -> String?) {
        self.store = store; self.send = send; self.startVoiceNote = startVoiceNote; self.stopVoiceNote = stopVoiceNote
    }
    /// The mic forgets the mask when the reader restarts, so it is resent on every connect.
    func connected(_ isConnected: Bool) {
        if !isConnected { sentMask = nil; releaseAll() }
        else if store.usesAssistants { router.warmActive() }
    }
    func syncMask() {
        let mask = store.blockMask
        if mask != sentMask { send("m\(mask)"); sentMask = mask }
    }
    func update(_ mic: MicStatus) {
        syncMask()
        var now: Set<Control> = []
        if mic.handle > (down.contains(.handle) ? 0.06 : 0.15) { now.insert(.handle) }
        for control in [Control.effect,.sample,.play] where mic.buttons & control.bit != 0 { now.insert(control) }
        for control in now.subtracting(down) { press(control,mic) }
        for control in down.subtracting(now) { release(control) }
        down = now
        if store.pressed != now { store.pressed = now }
    }
    private func press(_ control: Control, _ mic: MicStatus) {
        let m = store[control]
        if m.clean && mic.effect != -1 { restoreEffect[control] = mic.effect; send("e0") }
        switch m.action {
        case .none: break
        case .assistant:
            if let combo = m.combo { keyPoster(combo,true); heldCombo[control] = combo }
        case .voiceNote:
            if noteOwner == nil, startVoiceNote() { noteOwner = control; store.notice = "Recording a voice note…" }
        case .keys:
            if let combo = m.combo { keyPoster(combo,true); keyPoster(combo,false) }
        case .shortcut:
            let name = m.shortcutName
            if !name.isEmpty { DispatchQueue.global().async { _ = try? runTool("/usr/bin/shortcuts",["run",name]) } }
        case .previousAssistant: router.cycle(-1)
        case .nextAssistant: router.cycle(1)
        case .voiceToggle: router.toggleVoice(); store.refreshTrust()
        }
    }
    private func release(_ control: Control) {
        if let combo = heldCombo.removeValue(forKey:control) { keyPoster(combo,false) }
        if noteOwner == control {
            noteOwner = nil
            if let name = stopVoiceNote() { store.notice = "Voice note saved: \(name)" }
        }
        if let effect = restoreEffect.removeValue(forKey:control) { send("e\(effect+1)") }
    }
    private func releaseAll() { for control in down { release(control) }; down = [] }

    /// Posts a combo as real key events: modifiers down, key down … key up, modifiers up.
    /// Needs the Accessibility permission; without it macOS drops the events silently.
    func postCombo(_ combo: KeyCombo, down isDown: Bool) {
        let source = CGEventSource(stateID:.hidSystemState)
        func flagsEvent(_ code: Int, _ flags: CGEventFlags) {
            guard let e = CGEvent(keyboardEventSource:source,virtualKey:CGKeyCode(code),keyDown:true) else { return }
            e.type = .flagsChanged; e.flags = flags; e.post(tap:.cghidEventTap)
        }
        if combo.modifierOnly {
            flagsEvent(combo.keyCode,isDown ? CGEventFlags(rawValue:combo.flags) : [])
            return
        }
        let mods = KeyCombo.modifierKeys.filter { combo.flags & $0.flag.rawValue != 0 }
        var flags: CGEventFlags = []
        if isDown {
            for mod in mods { flags.insert(mod.flag); flagsEvent(mod.code,flags) }
            let e = CGEvent(keyboardEventSource:source,virtualKey:CGKeyCode(combo.keyCode),keyDown:true); e?.flags = flags; e?.post(tap:.cghidEventTap)
        } else {
            flags = CGEventFlags(rawValue:mods.reduce(0) { $0 | $1.flag.rawValue })
            let e = CGEvent(keyboardEventSource:source,virtualKey:CGKeyCode(combo.keyCode),keyDown:false); e?.flags = flags; e?.post(tap:.cghidEventTap)
            for mod in mods.reversed() { flags.remove(mod.flag); flagsEvent(mod.code,flags) }
        }
    }
}

// MARK: - Buttons window

struct ButtonsView: View {
    @ObservedObject var store: ButtonsStore
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            VStack(alignment:.leading,spacing:6) {
                HStack { DotMark(size:14); Text("BUTTONS").font(helvetica(15,.medium)); Spacer() }
                Text("Give the mic's controls a job on your Mac. A control with a job stops doing its mic job, unless you tick \u{201C}also on the mic\u{201D}.")
                    .font(helvetica(13)).foregroundColor(Palette.quiet).fixedSize(horizontal:false,vertical:true)
                HStack(spacing:8) {
                    SmallButton(title:"SET UP ASSISTANT BUTTONS") { store.applyAssistantPreset(); store.refreshTrust() }
                    Text("orange ◀  middle ▶  bottom voice").font(mono).foregroundColor(Palette.quiet)
                }.padding(.top,4)
            }.padding(.horizontal,22).padding(.top,14).padding(.bottom,14)
            if needsKeys && !store.trusted {
                HStack(alignment:.top,spacing:10) {
                    Rectangle().fill(Palette.orange).frame(width:3)
                    VStack(alignment:.leading,spacing:8) {
                        Text("FX–USB needs permission to press keys for other apps.").font(helvetica(13,.medium))
                        Text("System Settings → Privacy & Security → Accessibility → turn on FX–USB.").font(helvetica(12)).foregroundColor(Palette.quiet)
                        HStack(spacing:8) {
                            SmallButton(title:"OPEN SETTINGS") { store.refreshTrust(prompt:true); NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
                            SmallButton(title:"I'VE DONE IT") { store.refreshTrust() }
                        }
                    }
                }.padding(.horizontal,22).padding(.bottom,14)
            }
            VStack(spacing:1) {
                ForEach(Control.allCases) { control in ControlRow(store:store,control:control) }
            }
            .background(Palette.rule)
            .overlay(Rectangle().fill(Palette.rule).frame(height:1),alignment:.top)
            if store.usesAssistants { AssistantsPanel(store:store) }
            Text(store.notice.isEmpty ? "Changes apply straight away." : store.notice)
                .font(mono).foregroundColor(Palette.quiet).padding(.horizontal,22).padding(.vertical,12)
        }
        .frame(width:460)
        .background(Palette.paper)
        .foregroundColor(Palette.ink)
        .onAppear { store.refreshTrust(); store.loadShortcuts() }
    }
    var needsKeys: Bool { Control.allCases.contains { [.assistant,.keys,.voiceToggle].contains(store[$0].action) } }
}

struct SmallButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action:action) {
            Text(title).font(mono).padding(.horizontal,10).frame(height:24).overlay(Rectangle().stroke(Palette.ink,lineWidth:1))
        }.buttonStyle(.plain)
    }
}

struct ControlRow: View {
    @ObservedObject var store: ButtonsStore
    let control: Control
    var body: some View {
        let m = store[control]
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:10) {
                ControlGlyph(control:control)
                Text(control.name.uppercased()).font(helvetica(14,.medium))
                Spacer()
                Text("ON THE MIC: \(control.micJob.uppercased())").font(mono).foregroundColor(Palette.quiet)
                Circle().fill(store.pressed.contains(control) ? Palette.live : Palette.rule).frame(width:7,height:7)
            }
            Field(label:"ON YOUR MAC") {
                ChoiceMenu(value:m.action.title,options:MacAction.allCases.map { $0.title }) { title in
                    store[control].action = MacAction.allCases.first { $0.title == title } ?? .none
                    if [.assistant,.keys,.voiceToggle].contains(store[control].action) { store.refreshTrust() }
                }
            }
            if m.action == .assistant {
                Field(label:"ASSISTANT") { ChoiceMenu(value:m.assistant,options:assistants) { store[control].assistant = $0 } }
                Field(label:"ITS SHORTCUT") { ComboRecorder(combo:binding(\.combo)) }
                CheckBox(title:"Clean voice while talking (effects off)",isOn:binding(\.cleanVoice))
            }
            if m.action == .keys { Field(label:"SHORTCUT") { ComboRecorder(combo:binding(\.combo)) } }
            if m.action == .voiceNote {
                CheckBox(title:"Clean voice while recording (effects off)",isOn:binding(\.cleanNote))
            }
            if m.action == .shortcut {
                Field(label:"SHORTCUT") {
                    ChoiceMenu(value:m.shortcutName.isEmpty ? "Choose…" : m.shortcutName,options:store.shortcuts.isEmpty ? ["No Shortcuts found"] : store.shortcuts) { name in
                        if store.shortcuts.contains(name) { store[control].shortcutName = name }
                    }
                }
            }
            if control != .handle && m.action != .none {
                CheckBox(title:"Also do it on the mic (\(control.micJob))",isOn:binding(\.alsoOnMic))
            }
            Text(explanation(m)).font(helvetica(12)).foregroundColor(Palette.quiet).fixedSize(horizontal:false,vertical:true)
        }
        .padding(.horizontal,22).padding(.vertical,14)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(Palette.paper)
    }
    func binding<T>(_ path: WritableKeyPath<Mapping,T>) -> Binding<T> {
        Binding(get:{ store[control][keyPath:path] },set:{ store[control][keyPath:path] = $0 })
    }
    func explanation(_ m: Mapping) -> String {
        let verb = control == .handle ? "Hold the handle" : "Hold the \(control.name.lowercased())"
        let tap = control == .handle ? "Push the handle" : "Press the \(control.name.lowercased())"
        let clean = m.clean ? ", with the effects off" : ""
        switch m.action {
        case .none: return "Does only its usual job on the mic."
        case .assistant:
            guard let combo = m.combo else { return "Record the shortcut \(m.assistant) uses to start listening (push to talk or dictation)." }
            return "\(verb): FX–USB holds \(combo.label) so \(m.assistant) listens to you\(clean). Let go to stop."
        case .voiceNote: return "\(verb) to record a voice note\(clean). Let go to save it in Music/FX–USB/Voice notes."
        case .keys: return m.combo.map { "\(tap): FX–USB presses \($0.label)." } ?? "Record the shortcut to press."
        case .shortcut: return m.shortcutName.isEmpty ? "Choose a Shortcut from the Shortcuts app." : "\(tap): runs the Shortcut \u{201C}\(m.shortcutName)\u{201D}."
        case .previousAssistant: return "\(tap): brings the previous assistant in the list to the front."
        case .nextAssistant: return "\(tap): brings the next assistant in the list to the front."
        case .voiceToggle: return "\(tap): starts voice chat in the active assistant, or ends it (its voice button, or its voice key)."
        }
    }
}

struct Field<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing:12) {
            Text(label).font(mono).foregroundColor(Palette.quiet).frame(width:96,alignment:.leading)
            content()
            Spacer(minLength:0)
        }
    }
}

/// A plain dropdown (offscreen renders show a label, since they cannot draw menus).
struct ChoiceMenu: View {
    let value: String
    let options: [String]
    let choose: (String) -> Void
    var body: some View {
        if renderingPreview {
            Text(value + "  ▾").font(helvetica(13,.medium)).padding(.horizontal,8).frame(height:24).overlay(Rectangle().stroke(Palette.ink,lineWidth:1))
        } else {
            Menu { ForEach(options,id:\.self) { option in Button(option) { choose(option) } } } label: {
                Text(value).font(helvetica(13,.medium))
            }.menuStyle(.borderlessButton).fixedSize()
        }
    }
}

/// Click, then press the keys. A modifier pressed and released on its own records just that key.
struct ComboRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var listening = false
    @State private var monitor: Any?
    @State private var pendingModifier: (code: Int, flags: UInt64)?
    var body: some View {
        Button(action:toggle) {
            Text(listening ? "PRESS THE KEYS…" : (combo?.label ?? "RECORD"))
                .font(listening || combo == nil ? mono : helvetica(13,.medium))
                .foregroundColor(listening ? Palette.paper : Palette.ink)
                .padding(.horizontal,10).frame(height:24)
                .background(listening ? Palette.orange : Color.clear)
                .overlay(Rectangle().stroke(listening ? Palette.orange : Palette.ink,lineWidth:1))
        }.buttonStyle(.plain)
        .onDisappear(perform:stop)
    }
    func toggle() { listening ? stop() : start() }
    func start() {
        listening = true; pendingModifier = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.flagsChanged]) { event in
            let flags = cgFlags(event.modifierFlags)
            if event.type == .keyDown {
                if event.keyCode == 53 && flags == 0 { stop(); return nil }   // Esc cancels
                combo = KeyCombo(keyCode:Int(event.keyCode),flags:flags,modifierOnly:false); stop(); return nil
            }
            if flags != 0 { pendingModifier = (Int(event.keyCode),flags) }
            else if let pending = pendingModifier { combo = KeyCombo(keyCode:pending.code,flags:pending.flags,modifierOnly:true); stop() }
            return nil
        }
    }
    func stop() {
        listening = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    func cgFlags(_ f: NSEvent.ModifierFlags) -> UInt64 {
        var out: CGEventFlags = []
        if f.contains(.command) { out.insert(.maskCommand) }
        if f.contains(.option) { out.insert(.maskAlternate) }
        if f.contains(.control) { out.insert(.maskControl) }
        if f.contains(.shift) { out.insert(.maskShift) }
        return out.rawValue
    }
}

/// A square checkbox in the app's style (drawn in SwiftUI, so offscreen renders show it too).
struct CheckBox: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Button(action:{ isOn.toggle() }) {
            HStack(spacing:8) {
                ZStack {
                    Rectangle().stroke(Palette.ink,lineWidth:1.2).frame(width:13,height:13)
                    if isOn { Rectangle().fill(Palette.ink).frame(width:7,height:7) }
                }
                Text(title).font(helvetica(13)).foregroundColor(Palette.ink)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// Small picture of each control, in the mic's colours.
struct ControlGlyph: View {
    let control: Control
    var body: some View {
        switch control {
        case .handle:
            Path { p in p.move(to:CGPoint(x:12,y:2)); p.addLine(to:CGPoint(x:2,y:6)); p.addLine(to:CGPoint(x:9,y:20)); p.addLine(to:CGPoint(x:12,y:20)); p.closeSubpath() }
                .fill(Palette.orange).frame(width:14,height:22)
        case .effect: RoundedRectangle(cornerRadius:2).fill(Palette.orange).overlay(RoundedRectangle(cornerRadius:2).stroke(Color.black.opacity(0.25))).frame(width:8,height:18)
        case .sample: RoundedRectangle(cornerRadius:2).fill(Color(red:0.93,green:0.93,blue:0.92)).overlay(RoundedRectangle(cornerRadius:2).stroke(Color.black.opacity(0.3))).frame(width:8,height:18)
        case .play: RoundedRectangle(cornerRadius:2).fill(Color(red:0.85,green:0.85,blue:0.84)).overlay(RoundedRectangle(cornerRadius:2).stroke(Color.black.opacity(0.3))).frame(width:8,height:18)
        }
    }
}

final class ButtonsWindow {
    let window: NSWindow
    init(store: ButtonsStore) {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:460,height:640),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named:.aqua)
        window.backgroundColor = NSColor(calibratedRed:0.925,green:0.925,blue:0.918,alpha:1)
        window.title = "Buttons"
        // The window follows its content's size as rows open and close.
        let controller = NSHostingController(rootView:ButtonsView(store:store))
        controller.sizingOptions = [.preferredContentSize]
        window.contentViewController = controller
        window.center()
        window.setFrameAutosaveName("FXUSBButtons")
    }
    func show() { NSApp.activate(ignoringOtherApps:true); window.makeKeyAndOrderFront(nil) }
}

/// Self-test: simulated presses through the engine, with fake keys, commands and recorder.
func buttonsSelfTest() -> String {
    let store = ButtonsStore(persist:false)
    var commands: [String] = [], keys: [String] = [], notes: [String] = []
    let engine = ButtonEngine(store:store,send:{ commands.append($0) },
                              startVoiceNote:{ notes.append("start"); return true },
                              stopVoiceNote:{ notes.append("stop"); return "Voice note.wav" })
    engine.keyPoster = { combo, down in keys.append("\(combo.label) \(down ? "down" : "up")") }
    let optionSpace = KeyCombo(keyCode:49,flags:CGEventFlags.maskAlternate.rawValue,modifierOnly:false)
    store[.handle] = Mapping(action:.assistant,assistant:"Claude",combo:optionSpace)
    store[.play] = Mapping(action:.voiceNote)
    store[.effect] = Mapping(action:.keys,combo:KeyCombo(keyCode:15,flags:CGEventFlags.maskCommand.rawValue,modifierOnly:false))
    var mic = MicStatus(effect:2,sample:1)
    engine.connected(true)
    engine.update(mic)                                   // idle: only the mask goes out
    mic.handle = 0.5; engine.update(mic)                 // handle in: effects off, hold ⌥ Space
    mic.handle = 0.1; engine.update(mic)                 // still held (hysteresis)
    mic.handle = 0; engine.update(mic)                   // released: let go, effect back
    mic.buttons = 1; engine.update(mic); mic.buttons = 0; engine.update(mic)   // bottom: voice note
    mic.buttons = 4; engine.update(mic); mic.buttons = 0; engine.update(mic)   // orange: ⌘ R tap
    let expectCommands = ["m5","e0","e3"]
    let expectKeys = ["⌥ Space down","⌥ Space up","⌘ R down","⌘ R up"]
    precondition(commands == expectCommands,"Buttons: commands \(commands)")
    precondition(keys == expectKeys,"Buttons: keys \(keys)")
    precondition(notes == ["start","stop"] && store.notice == "Voice note saved: Voice note.wav","Buttons: voice note \(notes)")
    precondition(store.summary == "Handle → Claude · Orange → ⌘ R · Bottom → voice note","Buttons: summary \(store.summary)")
    return "buttons (mask, clean voice, hold, tap, voice note), " + assistantsSelfTest()
}
