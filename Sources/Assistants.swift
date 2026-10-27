import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

/// An AI assistant app the buttons can switch between, and how to start or stop its voice chat.
struct Assistant: Codable, Equatable, Identifiable {
    var name: String
    var path: String
    var bundleIDs: [String] = []     // fallbacks when the app is not at `path`
    var combo: KeyCombo?             // the app's own voice hotkey, if it has one
    var tryButton = true             // look for its voice / hang up button through Accessibility first
    var id: String { name }
    static let controlShift = CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
    static let grokBot = Assistant(name:"Grok Bot",path:"/Applications/Grok Bot.app",bundleIDs:["com.anysphere.sand"])
    /// Just Grok Bot: the buttons switch bots inside it. Other apps are an optional extra (ADD APP… in the Buttons window).
    static let defaults = [grokBot]
    /// Known extras, used when one of these apps is added to the list.
    static let extras = [
        Assistant(name:"Claude",path:"/Applications/Claude.app",bundleIDs:["com.anthropic.claudefordesktop"]),
        // ChatGPT: Settings → Voice → Voice chat hotkey (⌃⇧V by default). Its sidebar has many "New voice chat" buttons, so no button search.
        Assistant(name:"ChatGPT",path:"/Applications/ChatGPT.app",bundleIDs:["com.openai.chat"],combo:KeyCombo(keyCode:9,flags:controlShift,modifierOnly:false),tryButton:false)]
}

/// The keys that move to the previous / next bot inside Grok Bot.
struct BotKeys: Codable, Equatable {
    var previous: KeyCombo
    var next: KeyCombo
    static let optionArrows = BotKeys(previous:KeyCombo(keyCode:126,flags:CGEventFlags.maskAlternate.rawValue,modifierOnly:false),
                                      next:KeyCombo(keyCode:125,flags:CGEventFlags.maskAlternate.rawValue,modifierOnly:false))
    static let controlTab = BotKeys(previous:KeyCombo(keyCode:48,flags:Assistant.controlShift,modifierOnly:false),
                                    next:KeyCombo(keyCode:48,flags:CGEventFlags.maskControl.rawValue,modifierOnly:false))
    static let presets: [(name: String, keys: BotKeys)] = [("⌥ ↑ / ⌥ ↓ (Grok Bot's own)",optionArrows),("⌃⇧ Tab / ⌃ Tab",controlTab)]
    var name: String { BotKeys.presets.first { $0.keys == self }?.name ?? "Custom" }
}

enum VoiceKind { case start, stop, confirm }
/// `restarted`: voice chat started here after ending a call that was running in another chat.
enum VoiceOutcome: Equatable { case pressed(on: Bool), restarted, notFound, noPermission }

/// What an Accessibility title, description or help text says about voice chat (nil: not a voice chat button).
func voiceKind(_ text: String) -> VoiceKind? {
    let t = text.lowercased()
    if t.contains("end and chat") { return .confirm }     // the "End the current voice chat?" dialog
    if ["voice input","dictat","transcript"].contains(where:t.contains) { return nil }     // dictation is not a call
    if t.contains("·") || t.range(of:"\\d+:\\d\\d",options:.regularExpression) != nil { return nil }   // "Voice chat · 01:38": the running call's timer, not a button to press
    if ["hang up","end call","end voice","stop voice","end conversation"].contains(where:t.contains) { return .stop }
    if ["voice chat","voice mode","start voice","start a voice"].contains(where:t.contains) { return .start }
    return nil
}

/// Switches between assistants and starts or stops their voice chat. Every outside effect is a closure, so the self-test can fake it.
final class AssistantRouter {
    unowned let store: ButtonsStore
    var tap: (KeyCombo) -> Void
    var installed: (Assistant) -> Bool = { AssistantRouter.appURL($0) != nil }
    var running: (Assistant) -> Bool = { AssistantRouter.runningApp($0) != nil }
    var activate: (Assistant, TimeInterval) -> Bool = AssistantRouter.bringToFront   // true once it is frontmost, waiting at most this long
    var axVoice: (Assistant, Bool) -> VoiceOutcome = AssistantRouter.pressVoiceButton // second argument: whether we think voice is on
    var readBot: (Assistant) -> String? = { AssistantRouter.readBots($0).current }    // the open chat's name, from Accessibility
    var pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval:$0) }
    var warm: (Assistant) -> Void = { _ = AssistantRouter.enableAX($0) }
    var trusted: () -> Bool = { AXIsProcessTrusted() }
    var offload: (@escaping () -> Void) -> Void = { AssistantRouter.queue.async(execute:$0) }
    var onMain: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute:$0) }
    private var busy = false
    static let queue = DispatchQueue(label:"fxusb.assistants")
    init(store: ButtonsStore, tap: @escaping (KeyCombo) -> Void) { self.store = store; self.tap = tap }

    /// The assistant buttons talk to: the active one, or the first installed one.
    func current() -> Assistant? {
        if let a = store.assistants.first(where:{ $0.name == store.active }), installed(a) { return a }
        guard let first = store.assistants.first(where:installed) else { return nil }
        store.active = first.name
        return first
    }
    /// Previous (-1) or next (+1) installed assistant, wrapping round; brings it to the front straight away.
    func cycle(_ step: Int) {
        let list = store.assistants, n = list.count
        var i = list.firstIndex { $0.name == store.active } ?? (step > 0 ? -1 : n)
        for _ in 0..<n {
            i = ((i + step) % n + n) % n
            guard installed(list[i]) else { continue }
            let a = list[i]
            store.active = a.name
            _ = activate(a,0)
            if a.tryButton { offload { [self] in warm(a) } }
            store.notice = "Active: \(a.name)"
            return
        }
        store.notice = n == 0 ? "No assistants in the list." : "No assistant apps are installed."
    }
    /// Previous (-1) or next (+1) bot inside Grok Bot: bring it to the front and press its own shortcut. A running voice chat is not touched.
    func cycleBot(_ step: Int) {
        let a = store.assistants.first { $0.name == Assistant.grokBot.name } ?? Assistant.grokBot
        guard installed(a) else { store.notice = "Grok Bot is not installed."; return }
        store.active = a.name
        let combo = step > 0 ? store.botKeys.next : store.botKeys.previous, word = step > 0 ? "Next bot" : "Previous bot"
        offload { [self] in
            var message = word, name: String?
            if !running(a) { _ = activate(a,0.5); message = "Opening Grok Bot. Press again to switch bots." }
            else {
                let before = readBot(a), front = activate(a,0.5)
                if !trusted() { message = "Allow FX–USB in System Settings → Privacy & Security → Accessibility." }
                else if !front { message = "Could not bring Grok Bot to the front." }
                else {
                    tap(combo)
                    if let before {      // wait (briefly) for the chat to change, then say which bot is open
                        var now = readBot(a), tries = 0
                        while now == before && tries < 7 { pause(0.06); now = readBot(a); tries += 1 }
                        name = now
                        if let now { message = now == before ? "Bot: \(now) (no \(step > 0 ? "next" : "previous") bot)" : "Bot: \(now)" }
                    }
                }
            }
            onMain { [self] in
                if let name { store.bot = name }
                store.notice = message
            }
        }
    }
    /// Starts voice chat in the active assistant, or ends it. Its button first (Accessibility), then its hotkey.
    func toggleVoice() {
        guard !busy else { return }
        guard let a = current() else { store.notice = "No assistant app is installed."; return }
        busy = true
        let wasOn = store.voiceOn[a.name] ?? false
        offload { [self] in
            var message = "", state: Bool?
            if !running(a) {
                _ = activate(a,0.5); message = "Opening \(a.name). Press again for voice chat."
            } else {
                let front = activate(a,0.5)
                if !trusted() { message = "Allow FX–USB in System Settings → Privacy & Security → Accessibility." }
                else {
                    var outcome = VoiceOutcome.notFound
                    if a.tryButton { outcome = axVoice(a,wasOn) }
                    switch outcome {
                    case .pressed(let on): state = on; message = "\(a.name): voice chat \(on ? "on" : "off")"
                    case .restarted: state = true; message = "\(a.name): voice chat on here (ended the call in the other chat)"
                    case .noPermission: message = "Allow FX–USB in System Settings → Privacy & Security → Accessibility."
                    case .notFound:
                        if let combo = a.combo {
                            if front { tap(combo); state = !wasOn; message = "\(a.name): voice chat \(!wasOn ? "on" : "off") (\(combo.label))" }
                            else { message = "Could not bring \(a.name) to the front." }
                        } else { message = "\(a.name): no voice chat button found. Record its voice shortcut in the Buttons window." }
                    }
                }
            }
            onMain { [self] in
                if let state { store.voiceOn[a.name] = state }
                store.notice = message; busy = false
            }
        }
    }
    /// At start-up: switch Accessibility on in the active assistant (Electron apps only build their tree once asked).
    func warmActive() { if let a = current(), a.tryButton { offload { [self] in warm(a) } } }

    // MARK: real backends

    static func appURL(_ a: Assistant) -> URL? {
        if FileManager.default.fileExists(atPath:a.path) { return URL(fileURLWithPath:a.path) }
        for id in a.bundleIDs { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:id) { return url } }
        return nil
    }
    static func bundleID(_ a: Assistant) -> String? { appURL(a).flatMap { Bundle(url:$0)?.bundleIdentifier } }
    static func runningApp(_ a: Assistant) -> NSRunningApplication? {
        for id in ([bundleID(a)] + a.bundleIDs.map { Optional($0) }).compactMap({ $0 }) {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier:id).first { return app }
        }
        return nil
    }
    /// Launches or activates the app, then waits (polling) up to `wait` seconds for it to be frontmost.
    static func bringToFront(_ a: Assistant, wait: TimeInterval) -> Bool {
        guard let url = appURL(a) else { return false }
        let id = bundleID(a)
        func front() -> Bool { id != nil && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == id }
        if front() { return true }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at:url,configuration:configuration,completionHandler:nil)
        let deadline = Date().addingTimeInterval(wait)
        while !front() && Date() < deadline {
            if Thread.isMainThread { RunLoop.current.run(until:Date().addingTimeInterval(0.03)) } else { Thread.sleep(forTimeInterval:0.03) }   // the frontmost app updates on the main run loop
        }
        return front() || (wait == 0 && id != nil)
    }

    // MARK: Accessibility

    static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e,name as CFString,&value) == .success ? value : nil
    }
    private static var enabled: Set<pid_t> = []      // apps already asked this session (the flag cannot be read back reliably)
    /// Electron apps build their Accessibility tree only after being asked. True if this call switched it on just now.
    @discardableResult static func enableAX(_ a: Assistant) -> Bool {
        guard AXIsProcessTrusted(), let app = runningApp(a) else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element,0.5)
        let first = !enabled.contains(app.processIdentifier)
        enabled.insert(app.processIdentifier)
        return AXUIElementSetAttributeValue(element,"AXManualAccessibility" as CFString,kCFBooleanTrue) == .success && first
    }
    struct Scan { var hits: [(element: AXUIElement, text: String, kind: VoiceKind)] = []; var confirms: [AXUIElement] = []; var composer: AXUIElement?; var nodes = 0 }
    /// Walks the app's windows for voice chat / hang up buttons (and the message box).
    static func scan(_ a: Assistant) -> Scan {
        var result = Scan()
        guard let app = runningApp(a) else { return result }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,0.5)
        let deadline = Date().addingTimeInterval(1.2)
        let buttons: Set<String> = ["AXButton","AXCheckBox","AXPopUpButton","AXMenuButton","AXRadioButton"]
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard result.nodes < 6000, depth < 60, Date() < deadline else { return }
            result.nodes += 1
            let role = attribute(e,"AXRole") as? String ?? ""
            if buttons.contains(role) {
                for key in ["AXTitle","AXDescription","AXHelp"] {
                    if let text = attribute(e,key) as? String, let kind = voiceKind(text) {
                        var size = CGSize.zero
                        if let v = attribute(e,"AXSize") { AXValueGetValue(v as! AXValue,.cgSize,&size) }
                        if size.width > 0 && size.height > 0 { if kind == .confirm { result.confirms.append(e) } else { result.hits.append((e,text,kind)) } }
                        break
                    }
                }
            } else if role == "AXTextArea", result.composer == nil { result.composer = e }
            if let kids = attribute(e,"AXChildren") as? [AXUIElement] { for k in kids { walk(k,depth+1) } }
        }
        for window in attribute(root,"AXWindows") as? [AXUIElement] ?? [] { walk(window,0) }
        return result
    }
    /// Grok Bot's open chat (the main landmark's title) and its sidebar bots (buttons in the "Bot list" region), read through Accessibility.
    static func readBots(_ a: Assistant) -> (current: String?, list: [String]) {
        guard AXIsProcessTrusted(), let app = runningApp(a) else { return (nil,[]) }
        let fresh = enableAX(a), started = Date()
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,0.5)
        var current: String?, list: [String] = [], nodes = 0
        func walk(_ e: AXUIElement, _ depth: Int, inList: Bool) {
            guard nodes < 3000, depth < 40 else { return }
            nodes += 1
            let role = attribute(e,"AXRole") as? String ?? "", sub = attribute(e,"AXSubrole") as? String ?? ""
            if sub == "AXLandmarkMain" { if let t = attribute(e,"AXTitle") as? String, !t.isEmpty { current = t }; return }
            if sub == "AXApplicationLog" { return }
            if role == "AXButton" && inList {
                if let d = attribute(e,"AXDescription") as? String, let name = d.components(separatedBy:", ").first, !name.isEmpty { list.append(name) }
                return
            }
            let here = inList || (sub == "AXLandmarkRegion" && (attribute(e,"AXDescription") as? String) == "Bot list")
            if let kids = attribute(e,"AXChildren") as? [AXUIElement] { for k in kids { walk(k,depth+1,inList:here) } }
        }
        func pass() { current = nil; list = []; nodes = 0; for w in attribute(root,"AXWindows") as? [AXUIElement] ?? [] { walk(w,0,inList:false) } }
        pass()
        while current == nil && fresh && Date().timeIntervalSince(started) < 1.0 { Thread.sleep(forTimeInterval:0.1); pass() }
        return (current,list)
    }
    /// Presses the hang up button if there is one (voice is on), else the voice chat button.
    static func pressVoiceButton(_ a: Assistant, wasOn: Bool) -> VoiceOutcome {
        guard AXIsProcessTrusted() else { return .noPermission }
        let fresh = enableAX(a)
        let started = Date()
        var found = scan(a)
        while found.hits.isEmpty && fresh && Date().timeIntervalSince(started) < 1.5 { Thread.sleep(forTimeInterval:0.15); found = scan(a) }
        if found.hits.isEmpty, let composer = found.composer {       // the voice button shows with the message box focused
            AXUIElementSetAttributeValue(composer,"AXFocused" as CFString,kCFBooleanTrue)
            Thread.sleep(forTimeInterval:0.15); found = scan(a)
        }
        guard let hit = found.hits.first(where:{ $0.kind == .stop }) ?? found.hits.first else { return .notFound }
        guard AXUIElementPerformAction(hit.element,kAXPressAction as CFString) == .success else { return .notFound }
        if hit.kind == .start {      // a call in another chat: "End the current voice chat?". The user asked to start here, so confirm.
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 0.35 {
                Thread.sleep(forTimeInterval:0.07)
                if let confirm = scan(a).confirms.first, AXUIElementPerformAction(confirm,kAXPressAction as CFString) == .success { return .restarted }
            }
        }
        return .pressed(on: hit.kind == .start)
    }
    /// Read-only report for `FXMic --assistants`.
    static func describe(_ a: Assistant, active: Bool) -> String {
        var line = "\(active ? "*" : " ") \(a.name): "
        guard let url = appURL(a) else { return line + "not installed" }
        line += "\(url.path) [\(bundleID(a) ?? "?")] \(runningApp(a) != nil ? "running" : "not running")"
        line += a.combo.map { ", hotkey \($0.label)" } ?? ", no hotkey"
        guard a.tryButton else { return line + ", button search off" }
        guard AXIsProcessTrusted() else { return line + ", Accessibility not allowed for this process" }
        guard runningApp(a) != nil else { return line }
        let fresh = enableAX(a), started = Date()
        var found = scan(a), tries = 0
        while found.hits.isEmpty && fresh && tries < 10 { Thread.sleep(forTimeInterval:0.15); found = scan(a); tries += 1 }
        let took = Int(Date().timeIntervalSince(started) * 1000)
        let bots = readBots(a)
        line += ", open bot: \(bots.current ?? "unknown"), bots: \(bots.list.isEmpty ? "none seen" : bots.list.joined(separator:", "))"
        let names = found.hits.map { "\($0.kind == .stop ? "stop" : "start") “\($0.text)”" }
        return line + ", AX: \(found.nodes) nodes in \(took) ms, " + (names.isEmpty ? "no voice button" : names.joined(separator:", "))
    }
}

func printAssistants() {
    let store = ButtonsStore()
    let router = AssistantRouter(store:store,tap:{ _ in })
    print("Assistants (active: \(router.current()?.name ?? "none")):")
    for a in store.assistants { print(AssistantRouter.describe(a,active:a.name == store.active)) }
}

/// `FXMic --assistant-focus NAME`: brings that assistant to the front and says how long it took (a hands-on check of cycling).
func focusAssistant(_ name: String) {
    let store = ButtonsStore(persist:false)
    guard let a = store.assistants.first(where:{ $0.name == name }) else { print("No assistant called \(name)"); return }
    let started = Date(), front = AssistantRouter.bringToFront(a,wait:0.5)
    print("\(a.name): frontmost \(front) after \(Int(Date().timeIntervalSince(started) * 1000)) ms (now: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
}

// MARK: - Buttons window: the assistant list

struct AssistantsPanel: View {
    @ObservedObject var store: ButtonsStore
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            if store.usesBots {
                HStack {
                    Text("BOTS IN GROK BOT").font(helvetica(14,.medium))
                    Spacer()
                    Text(store.bot.isEmpty ? "" : "OPEN: \(store.bot.uppercased())").font(mono).foregroundColor(Palette.quiet)
                }
                Field(label:"BOT KEYS") { ChoiceMenu(value:store.botKeys.name,options:BotKeys.presets.map { $0.name }) { name in
                    if let preset = BotKeys.presets.first(where:{ $0.name == name }) { store.botKeys = preset.keys }
                } }
                Field(label:"PREVIOUS") { ComboRecorder(combo:Binding(get:{ store.botKeys.previous },set:{ if let combo = $0 { store.botKeys.previous = combo } })) }
                Field(label:"NEXT") { ComboRecorder(combo:Binding(get:{ store.botKeys.next },set:{ if let combo = $0 { store.botKeys.next = combo } })) }
                Text("Switching bots does not end a voice chat: Grok Bot keeps the call running while you open other chats.")
                    .font(helvetica(12)).foregroundColor(Palette.quiet).fixedSize(horizontal:false,vertical:true)
                Rectangle().fill(Palette.rule).frame(height:1).padding(.vertical,4)
            }
            HStack {
                Text("VOICE CHAT APPS").font(helvetica(14,.medium))
                Spacer()
                Text(store.assistantLine.uppercased()).font(mono).foregroundColor(Palette.quiet)
            }
            VStack(spacing:1) {
                ForEach(Array(store.assistants.enumerated()),id:\.element.id) { index, _ in AssistantRow(store:store,index:index) }
            }.background(Palette.rule)
            HStack(spacing:8) {
                SmallButton(title:"ADD APP…") { store.addAssistant() }
                SmallButton(title:"RESET LIST") { store.resetAssistants() }
            }
            Text("The voice button works on the active app here. Add Claude or ChatGPT if you want it there too; the \u{201C}previous / next app\u{201D} jobs move through this list and skip apps that are not installed.")
                .font(helvetica(12)).foregroundColor(Palette.quiet).fixedSize(horizontal:false,vertical:true)
        }
        .padding(.horizontal,22).padding(.vertical,14)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(Palette.paper)
    }
}

struct AssistantRow: View {
    @ObservedObject var store: ButtonsStore
    let index: Int
    var body: some View {
        if store.assistants.indices.contains(index) {
            let a = store.assistants[index], isActive = a.name == store.active, here = AssistantRouter.appURL(a) != nil
            VStack(alignment:.leading,spacing:8) {
                HStack(spacing:8) {
                    Circle().fill(isActive ? Palette.orange : Palette.rule).frame(width:8,height:8)
                    Text(a.name).font(helvetica(13,.medium)).lineLimit(1)
                    if !here { Text("NOT INSTALLED").font(mono).foregroundColor(Palette.quiet) }
                    else if store.voiceOn[a.name] == true { Text("VOICE ON").font(mono).foregroundColor(Palette.orange) }
                    Spacer(minLength:6)
                    if !isActive && here { SmallButton(title:"USE") { store.setActive(a.name) } }
                    SmallButton(title:"▲") { store.moveAssistant(index,by:-1) }
                    SmallButton(title:"▼") { store.moveAssistant(index,by:1) }
                    SmallButton(title:"✕") { store.removeAssistant(index) }
                }
                Field(label:"VOICE KEY") {
                    ComboRecorder(combo:Binding(get:{ store.assistants.indices.contains(index) ? store.assistants[index].combo : nil },
                                                set:{ if store.assistants.indices.contains(index) { store.assistants[index].combo = $0 } }))
                    if a.combo != nil { SmallButton(title:"CLEAR") { store.assistants[index].combo = nil } }
                }
                CheckBox(title:"Look for its voice button first",isOn:Binding(get:{ store.assistants.indices.contains(index) ? store.assistants[index].tryButton : false },
                                                                              set:{ if store.assistants.indices.contains(index) { store.assistants[index].tryButton = $0 } }))
            }
            .padding(.horizontal,12).padding(.vertical,10)
            .frame(maxWidth:.infinity,alignment:.leading)
            .background(Palette.paper)
        }
    }
}

extension ButtonsStore {
    func setActive(_ name: String) { active = name; notice = "Active: \(name)" }
    func moveAssistant(_ index: Int, by step: Int) {
        let to = index + step
        guard assistants.indices.contains(index), assistants.indices.contains(to) else { return }
        assistants.swapAt(index,to)
    }
    func removeAssistant(_ index: Int) { if assistants.indices.contains(index) { assistants.remove(at:index) } }
    func resetAssistants() { assistants = Assistant.defaults }
    /// Adds an app (picked in a panel) to the end of the list; it starts with no voice key and no button search.
    func add(app url: URL) {
        let bundle = Bundle(url:url)
        let name = bundle?.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? bundle?.object(forInfoDictionaryKey:"CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        guard !assistants.contains(where:{ $0.name == name || $0.path == url.path }) else { notice = "\(name) is already in the list."; return }
        if var known = Assistant.extras.first(where:{ $0.name == name }) { known.path = url.path; assistants.append(known) }
        else { assistants.append(Assistant(name:name,path:url.path,bundleIDs:bundle?.bundleIdentifier.map { [$0] } ?? [],tryButton:false)) }
        notice = "Added \(name)."
    }
    func addAssistant() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath:"/Applications")
        panel.allowsMultipleSelection = false
        panel.message = "Choose an assistant app"
        if panel.runModal() == .OK, let url = panel.url { add(app:url) }
    }
}

// MARK: - Self-test

/// Self-test: cycling, the voice toggle and the preset, through the engine, with fake apps, fake Accessibility and fake keys.
func assistantsSelfTest() -> String {
    let store = ButtonsStore(persist:false)
    var commands: [String] = [], keys: [String] = [], activated: [String] = [], pressed: [String] = []
    let engine = ButtonEngine(store:store,send:{ commands.append($0) },startVoiceNote:{ false },stopVoiceNote:{ nil })
    // Fake Grok Bot: its bots in order, and the open one moves with ⌥ ↑ / ⌥ ↓ or ⌃⇧ Tab / ⌃ Tab.
    let bots = ["Grok Bot","Mac","Bento","IWA","Sec"]
    var open = 0, readable = true
    engine.keyPoster = { combo, down in
        keys.append("\(combo.label) \(down ? "down" : "up")")
        if down, let move = ["⌥ ↑":-1,"⌥ ↓":1,"⌃⇧ Tab":-1,"⌃ Tab":1][combo.label] { open = max(0,min(bots.count-1,open+move)) }
    }
    var missing: Set<String> = ["Ghost"], isRunning = true, axReplies: [VoiceOutcome] = [], allowed = true, front = true
    let router = engine.router
    router.installed = { !missing.contains($0.name) }
    router.running = { _ in isRunning }
    router.activate = { a, wait in activated.append("\(a.name)/\(wait)"); return front }
    router.axVoice = { a, wasOn in pressed.append("\(a.name) \(wasOn)"); return axReplies.isEmpty ? .notFound : axReplies.removeFirst() }
    router.warm = { _ in }
    router.pause = { _ in }
    router.readBot = { _ in readable ? bots[open] : nil }
    router.trusted = { allowed }
    router.offload = { $0() }
    router.onMain = { $0() }
    precondition(store.assistants.map { $0.name } == ["Grok Bot"] && store.botKeys == .optionArrows,"Assistants: default list is just Grok Bot")
    store.assistants = Assistant.defaults + Assistant.extras + [Assistant(name:"Ghost",path:"/nonexistent/Ghost.app",tryButton:false)]
    precondition(store.assistants.map { $0.name } == ["Grok Bot","Claude","ChatGPT","Ghost"],"Assistants: extended list")

    // The preset: orange previous, middle next, bottom voice; handle untouched; all three mic jobs off.
    store[.handle] = Mapping(action:.assistant,assistant:"Claude",combo:KeyCombo(keyCode:49,flags:CGEventFlags.maskAlternate.rawValue,modifierOnly:false))
    store.applyAssistantPreset()
    precondition(store[.effect].action == .previousBot && store[.sample].action == .nextBot && store[.play].action == .voiceToggle && store[.handle].action == .assistant,"Assistants: preset")
    precondition(store.blockMask == 7 && store.usesAssistants && store.usesBots,"Assistants: mic jobs off (\(store.blockMask))")
    precondition(store.summary == "Handle → Claude · Orange → previous bot · Middle → next bot · Bottom → voice chat","Assistants: summary \(store.summary)")
    func tap(_ bits: UInt8) { var mic = MicStatus(effect:2,sample:1); mic.buttons = bits; engine.update(mic); mic.buttons = 0; engine.update(mic) }
    engine.connected(true); store.active = ""

    // Bots inside Grok Bot: orange = ⌥ ↑, middle = ⌥ ↓ (it comes to the front first), and the open bot is read back.
    open = 1; store.active = ""; activated = []; keys = []
    tap(2)
    precondition(keys == ["⌥ ↓ down","⌥ ↓ up"] && activated == ["Grok Bot/0.5"] && store.notice == "Bot: Bento" && store.bot == "Bento" && store.active == "Grok Bot","Assistants: next bot \(keys) \(store.notice)")
    tap(2); tap(4); tap(4)
    precondition(store.bot == "Mac" && store.notice == "Bot: Mac" && keys.count == 8,"Assistants: previous bot \(store.bot)")
    tap(4); precondition(store.bot == "Grok Bot" && store.notice == "Bot: Grok Bot","Assistants: previous bot reaches the top")
    tap(4); precondition(store.notice == "Bot: Grok Bot (no previous bot)","Assistants: top of the list \(store.notice)")
    precondition(store.assistantLine == "Bot: Grok Bot · voice off","Assistants: bot line \(store.assistantLine)")
    store.voiceOn["Grok Bot"] = true                     // a call is running: switching bots only presses the bot keys, nothing else
    keys = []; pressed = []; tap(2); tap(2)
    precondition(keys == ["⌥ ↓ down","⌥ ↓ up","⌥ ↓ down","⌥ ↓ up"] && pressed.isEmpty && store.voiceOn["Grok Bot"] == true && store.bot == "Bento" && store.assistantLine == "Bot: Bento · voice on","Assistants: switching during a call \(keys) \(pressed)")
    store.voiceOn["Grok Bot"] = false
    store.botKeys = .controlTab; keys = []; tap(2); tap(4)    // the alternative keys
    precondition(keys == ["⌃ Tab down","⌃ Tab up","⌃⇧ Tab down","⌃⇧ Tab up"] && store.botKeys.name == "⌃⇧ Tab / ⌃ Tab","Assistants: ⌃Tab keys \(keys)")
    store.botKeys = .optionArrows
    readable = false; keys = []; tap(2)
    precondition(keys.count == 2 && store.notice == "Next bot" && store.bot == "Bento","Assistants: name unreadable \(store.notice)")
    tap(4); precondition(store.notice == "Previous bot","Assistants: previous, name unreadable")
    readable = true; open = 2
    isRunning = false; keys = []; tap(2)
    precondition(keys.isEmpty && store.notice.hasPrefix("Opening Grok Bot"),"Assistants: Grok Bot not running")
    isRunning = true; allowed = false; tap(2)
    precondition(keys.isEmpty && store.notice.contains("Accessibility"),"Assistants: bot keys need permission")
    allowed = true; front = false; tap(2)
    precondition(keys.isEmpty && store.notice == "Could not bring Grok Bot to the front.","Assistants: bot keys not frontmost")
    front = true; missing = ["Ghost","Grok Bot"]; tap(2)
    precondition(keys.isEmpty && store.notice == "Grok Bot is not installed.","Assistants: Grok Bot missing")
    missing = ["Ghost"]
    // The voice button after switching bots starts voice in the open chat; if a call runs elsewhere the confirmation is pressed.
    axReplies = [.pressed(on:true),.restarted,.pressed(on:false)]; store.active = "Grok Bot"; keys = []; pressed = []
    tap(1); precondition(store.voiceOn["Grok Bot"] == true && store.notice == "Grok Bot: voice chat on" && keys.isEmpty,"Assistants: voice in the open chat")
    tap(1); precondition(store.voiceOn["Grok Bot"] == true && store.notice.contains("ended the call in the other chat"),"Assistants: End and Chat \(store.notice)")
    tap(1); precondition(store.voiceOn["Grok Bot"] == false && store.notice == "Grok Bot: voice chat off","Assistants: hang up")
    store[.effect] = Mapping(action:.previousAssistant); store[.sample] = Mapping(action:.nextAssistant)
    store.active = ""; store.bot = ""; activated = []

    // Cycling: next goes Grok Bot → Claude → ChatGPT → (Ghost is skipped) → Grok Bot; previous goes back; the app comes to the front at once.
    tap(2); precondition(store.active == "Grok Bot" && store.notice == "Active: Grok Bot","Assistants: first next \(store.active)")   // nothing active yet: starts at the top
    activated = []
    tap(2); tap(2); tap(2)
    precondition(store.active == "Grok Bot" && activated == ["Claude/0.0","ChatGPT/0.0","Grok Bot/0.0"],"Assistants: next cycle \(activated)")
    activated = []; tap(4); tap(4)
    precondition(store.active == "Claude" && activated == ["ChatGPT/0.0","Claude/0.0"],"Assistants: previous \(activated)")
    store.active = "Grok Bot"; activated = []; tap(4)
    precondition(store.active == "ChatGPT" && activated == ["ChatGPT/0.0"],"Assistants: previous wraps \(store.active)")
    missing = ["Ghost","Claude"]; store.active = "Grok Bot"; tap(2)
    precondition(store.active == "ChatGPT" && store.assistantLine == "Active: ChatGPT · voice off","Assistants: skips uninstalled \(store.active)")
    missing = Set(store.assistants.map { $0.name }); tap(2)
    precondition(store.active == "ChatGPT" && store.notice == "No assistant apps are installed.","Assistants: none installed")
    missing = ["Ghost"]

    // Voice toggle on ChatGPT: no button search, so its hotkey ⌃⇧ V is tapped; the state flips each press.
    store.active = "ChatGPT"; keys = []; activated = []; pressed = []
    tap(1)
    precondition(keys == ["⌃⇧ V down","⌃⇧ V up"] && pressed.isEmpty && store.voiceOn["ChatGPT"] == true && activated == ["ChatGPT/0.5"],"Assistants: ChatGPT on \(keys) \(activated)")
    precondition(store.assistantLine == "Active: ChatGPT · voice on","Assistants: line \(store.assistantLine)")
    tap(1)
    precondition(keys.count == 4 && store.voiceOn["ChatGPT"] == false && store.notice.contains("voice chat off"),"Assistants: ChatGPT off \(store.notice)")

    // Grok Bot: its button first. The button's own state wins over what we thought.
    store.active = "Grok Bot"; keys = []; pressed = []
    axReplies = [.pressed(on:true),.pressed(on:false)]
    tap(1); precondition(store.voiceOn["Grok Bot"] == true && store.notice == "Grok Bot: voice chat on" && pressed == ["Grok Bot false"],"Assistants: Grok on \(pressed)")
    tap(1); precondition(store.voiceOn["Grok Bot"] == false && store.notice == "Grok Bot: voice chat off" && pressed.last == "Grok Bot true" && keys.isEmpty,"Assistants: Grok off")
    axReplies = [.pressed(on:false)]; store.voiceOn["Grok Bot"] = nil; tap(1)
    precondition(store.voiceOn["Grok Bot"] == false,"Assistants: button state wins")

    // Button not found: the hotkey if there is one, else a plain message. Claude has no hotkey by default.
    axReplies = []; store.active = "Claude"; keys = []; tap(1)
    precondition(keys.isEmpty && store.notice.contains("no voice chat button found") && store.voiceOn["Claude"] == nil,"Assistants: Claude without hotkey \(store.notice)")
    store.assistants[1].combo = KeyCombo(keyCode:9,flags:CGEventFlags.maskCommand.rawValue,modifierOnly:false)
    tap(1); precondition(keys == ["⌘ V down","⌘ V up"] && store.voiceOn["Claude"] == true,"Assistants: Claude fallback hotkey \(keys)")
    store.assistants[1].combo = nil
    store.active = "Grok Bot"; store.assistants[0].combo = KeyCombo(keyCode:96,flags:0,modifierOnly:false); keys = []; tap(1)
    precondition(keys == ["F5 down","F5 up"],"Assistants: button missing falls back to the key \(keys)")

    // Never press keys into the wrong app, and say what is needed.
    front = false; keys = []; store.active = "ChatGPT"; tap(1)
    precondition(keys.isEmpty && store.notice == "Could not bring ChatGPT to the front.","Assistants: not frontmost")
    front = true; allowed = false; tap(1)
    precondition(keys.isEmpty && store.notice.contains("Accessibility"),"Assistants: no permission")
    allowed = true; isRunning = false; store.voiceOn["ChatGPT"] = false; activated = []; tap(1)
    precondition(keys.isEmpty && store.notice.hasPrefix("Opening ChatGPT") && activated == ["ChatGPT/0.5"] && store.voiceOn["ChatGPT"] == false,"Assistants: app not running")
    isRunning = true
    axReplies = [.noPermission]; store.active = "Grok Bot"; tap(1)
    precondition(store.notice.contains("Accessibility"),"Assistants: AX refused")

    // What the button texts mean.
    precondition(voiceKind("Start voice chat") == .start && voiceKind("Hang up") == .stop && voiceKind("End call") == .stop,"Assistants: button names")
    precondition(voiceKind("Start voice input") == nil && voiceKind("Send") == nil && voiceKind("Show transcript") == nil && voiceKind("Mute") == nil && voiceKind("Press and hold to record") == nil && voiceKind("Voice chat · 01:38") == nil,"Assistants: not voice chat")
    precondition(voiceKind("End and Chat") == .confirm && voiceKind("Cancel") == nil,"Assistants: confirmation button")

    // Saved lists and mappings: the list round-trips, and mappings saved before these actions existed still load.
    let list = try! JSONDecoder().decode([Assistant].self,from:JSONEncoder().encode(store.assistants))
    precondition(list == store.assistants,"Assistants: list round trip")
    let old = #"{"handle":{"action":"assistant","assistant":"Claude","cleanVoice":true,"cleanNote":false,"alsoOnMic":false,"shortcutName":""},"play":{"action":"voiceNote","assistant":"Claude","cleanVoice":true,"cleanNote":false,"alsoOnMic":false,"shortcutName":""}}"#
    let decoded = try! JSONDecoder().decode([String:Mapping].self,from:Data(old.utf8))
    precondition(decoded["handle"]?.action == .assistant && decoded["play"]?.action == .voiceNote,"Assistants: old mappings")
    let reloaded = try! JSONDecoder().decode([String:Mapping].self,from:JSONEncoder().encode(Dictionary(uniqueKeysWithValues:store.mappings.map { ($0.key.rawValue,$0.value) })))
    precondition(reloaded["play"]?.action == .voiceToggle && reloaded["effect"]?.action == .previousAssistant,"Assistants: new mappings round trip")
    let keysBack = try! JSONDecoder().decode(BotKeys.self,from:JSONEncoder().encode(BotKeys.controlTab))
    precondition(keysBack == .controlTab && BotKeys.optionArrows.name.hasPrefix("⌥ ↑"),"Assistants: bot keys round trip")
    store.applyAssistantPreset()
    precondition(store[.effect].action == .previousBot && store[.sample].action == .nextBot,"Assistants: preset uses bots, not apps")
    return "assistants (preset, bot switching, app cycling, voice toggle, fallbacks)"
}
