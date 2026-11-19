import AppKit
import IOKit.ps
import WebKit

// MacMark: this Mac's About window as a sigil drawn from its real specs.
// A native window holding a web canvas (web/), fed by Machine (Machine.swift).
//   MacMark                      the window
//   MacMark --json               print the reading and quit
//   MacMark --live               print the live reading (memory, GPU, uptime,
//                                battery charge, thermal state, devices) and quit
//   MacMark --storage            print what fills the disk, by category, and quit
//   MacMark --shot out.png [--strip] [--hover N] [--mode NAME] [--colors NAME] [--wait S]
//                                draw the window off-screen and save a PNG
//                                (--storage-file F: use a saved --storage reading)

let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// The web view under the transparent title bar: a press in the page's
// header (but not on its buttons) moves the window, as a title bar does,
// and a double-click there zooms it. The page reports where its header and
// buttons are ("regions").
final class DragWebView: WKWebView {
    var headerHeight: CGFloat = 30
    var noDrag: [CGRect] = []   // in the page's coordinates (top-left origin)

    func inDragArea(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        let y = isFlipped ? p.y : bounds.height - p.y
        guard y >= 0 && y < headerHeight else { return false }
        return !noDrag.contains { $0.insetBy(dx: -2, dy: -2).contains(CGPoint(x: p.x, y: y)) }
    }

    override func mouseDown(with event: NSEvent) {
        guard inDragArea(event), let window = window else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            // As the user set it in System Settings › Desktop & Dock.
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window.miniaturize(nil) } else if action != "None" { window.zoom(nil) }
            return
        }
        window.performDrag(with: event)
    }
}

final class Controller: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!
    var web: DragWebView!
    var machine: [String: Any]?
    var pageReady = false
    var reading = false
    var readAgain = false
    var liveTimer: Timer?
    // What fills the disk (Machine.storageParts): slow, so measured once
    // in the background after the first reading, and kept across readings.
    var storage: [String: Any]?
    var measuring = false
    var appearanceObs: NSKeyValueObservation?
    let shotPath = arg("--shot")

    func start() {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        for name in ["copy", "error", "ready", "close", "log", "regions", "colors"] { ucc.add(self, name: name) }
        config.userContentController = ucc

        let size = NSSize(width: 1100, height: 680)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "MacMark"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 760, height: 560)
        window.delegate = self
        window.setFrameAutosaveName("MacMark")
        if !window.setFrameUsingName("MacMark") { window.center() }

        web = DragWebView(frame: window.contentView!.bounds, configuration: config)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        window.contentView!.addSubview(web)
        window.backgroundColor = .windowBackgroundColor

        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("web"),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path) else {
            FileHandle.standardError.write("MacMark: web/index.html is missing from the app's Resources\n".data(using: .utf8)!)
            exit(1)
        }
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)

        if shotPath != nil {
            // Off-screen: drawn but never shown.
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Light and dark mode, and the accent colour: the colours follow.
        appearanceObs = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.sendPalette(); self?.read() }
        }
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sendPalette(); self?.read()
        }
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("AppleColorPreferencesChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            self?.sendPalette(); self?.read()
        }
        // A display plugged in or out: read again (a ring more or less).
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.read()
        }

        read()
        // While open: memory, GPU load, uptime and the battery's charge every
        // 4 seconds; what is plugged in or paired every third time.
        liveTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.live() }
        // The Mac getting hotter or cooling down: at once too.
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.live(devices: false)
        }
        // A charger plugged in or out: at once, not at the next tick.
        powerChanged = { [weak self] in self?.live(devices: false) }
        if let src = IOPSNotificationCreateRunLoopSource({ _ in powerChanged?() }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    // A reading asked for while one runs is queued, not dropped.
    func read() {
        if reading { readAgain = true; return }
        reading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let m = Machine.read()
            DispatchQueue.main.async {
                self.reading = false
                self.machine = m
                self.send()
                self.measureStorage()
                if self.readAgain { self.readAgain = false; self.read() }
            }
        }
    }

    func measureStorage() {
        // (Tests: a breakdown saved with --storage, instead of measuring.)
        if storage == nil, let f = arg("--storage-file"), let d = FileManager.default.contents(atPath: f),
           let s = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { storageDone(s); return }
        guard storage == nil, !measuring, let d = machine?["disk"] as? [String: Any],
              let total = d["total"] as? Int, let used = d["used"] as? Int else { return }
        measuring = true
        DispatchQueue.global(qos: .utility).async {
            let s = Machine.storageParts(total: total, used: used)
            DispatchQueue.main.async { self.measuring = false; self.storageDone(s) }
        }
    }
    // Merged into the reading the page shows: a whole reading sent again
    // would be older than the live updates since, and ignored.
    func storageDone(_ s: [String: Any]) {
        storage = s
        if pageReady { js("MacMark.storage(\(Machine.json(s)))") }
        if shotPath != nil { shoot() }
    }

    var liveTicks = 0
    func live(devices: Bool? = nil) {
        guard machine != nil, pageReady, window.isVisible || shotPath != nil else { return }
        var withDevices = devices ?? false
        if devices == nil { liveTicks += 1; withDevices = liveTicks % 3 == 0 }
        DispatchQueue.global(qos: .utility).async {
            let v = Machine.live(devices: withDevices)
            DispatchQueue.main.async { self.js("MacMark.live(\(Machine.json(v)))") }
        }
    }

    func send() {
        guard pageReady, var m = machine else { return }
        if var d = m["disk"] as? [String: Any] {
            if let s = storage { d["parts"] = s["parts"]; d["partsAt"] = s["at"] } else { d["measuring"] = true }
            m["disk"] = d
        }
        js("MacMark.take(\(Machine.json(m)))")
        if shotPath != nil { shoot() }
    }

    func js(_ code: String) { web.evaluateJavaScript(code) { _, err in if let err = err { FileHandle.standardError.write("MacMark JS: \(err)\n".data(using: .utf8)!) } } }

    // MARK: colours

    static func hex(_ c: NSColor) -> String {
        guard let s = c.usingColorSpace(.sRGB) else { return "#888888" }
        return String(format: "#%02x%02x%02x", Int(round(s.redComponent * 255)), Int(round(s.greenComponent * 255)), Int(round(s.blueComponent * 255)))
    }

    // With its alpha, for the page's own CSS (separators, secondary text).
    static func rgba(_ c: NSColor) -> String {
        guard let s = c.usingColorSpace(.sRGB) else { return "rgba(128,128,128,0.5)" }
        return String(format: "rgba(%d,%d,%d,%.3f)", Int(round(s.redComponent * 255)), Int(round(s.greenComponent * 255)), Int(round(s.blueComponent * 255)), s.alphaComponent)
    }

    // The colour schemes C cycles through: each section's colour (hardware,
    // software, age), and optionally a fourth for the accent (the Uptime
    // ring, the logo, the selection). All follow light and dark mode as the
    // default does: system colours, or greys that do. The choice is kept in the app's
    // preferences, by name, so it is there the next time it opens.
    static let schemes: [(name: String, colors: () -> [NSColor])] = [
        ("System", { [.systemBlue, .systemYellow, .systemPink] }),
        ("Ocean", { [.systemCyan, .systemIndigo, .systemMint] }),
        ("Sunset", { [.systemOrange, .systemRed, .systemPurple] }),
        ("Garden", { [.systemGreen, .systemTeal, .systemYellow] }),
        ("Berry", { [.systemPurple, .systemPink, .systemIndigo] }),
        ("Accent", { [.controlAccentColor, .controlAccentColor, .controlAccentColor] }),
        ("Mono", { [grey(0.93, 0.13), grey(0.72, 0.36), grey(0.52, 0.55), grey(1, 0)] }),
        // (The page colours each ring its own hue and turns them: these are
        // only the fallback.)
        ("Rainbow", { [.systemBlue, .systemYellow, .systemPink] })
    ]
    // A grey for dark mode and one for light: light on a dark window, dark
    // on a light one.
    static func grey(_ dark: CGFloat, _ light: CGFloat) -> NSColor {
        NSColor(name: nil) { ap in NSColor(white: ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1) }
    }
    static let schemeKey = "ColorScheme"
    // (--colors NAME: a scheme for this run only, for snapshots.)
    var schemeIndex: Int = {
        let name = arg("--colors") ?? UserDefaults.standard.string(forKey: Controller.schemeKey) ?? ""
        return Controller.schemes.firstIndex { $0.name.lowercased() == name.lowercased() } ?? 0
    }()
    func cycleScheme() {
        schemeIndex = (schemeIndex + 1) % Self.schemes.count
        UserDefaults.standard.set(Self.schemes[schemeIndex].name, forKey: Self.schemeKey)
        sendPalette(announce: true)
    }

    func palette() -> [String: Any] {
        var p: [String: Any] = [:]
        let scheme = Self.schemes[schemeIndex]
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            let c = scheme.colors()
            p = ["fg": Self.hex(.labelColor), "bg": Self.hex(.windowBackgroundColor),
                 "dimText": Self.rgba(.secondaryLabelColor), "sep": Self.rgba(.separatorColor),
                 "accent": Self.hex(c.count > 3 ? c[3] : .controlAccentColor), "blue": Self.hex(c[0]),
                 "yellow": Self.hex(c[1]), "pink": Self.hex(c[2]), "red": Self.hex(.systemRed),
                 "scheme": scheme.name, "rainbow": scheme.name == "Rainbow", "schemeN": schemeIndex + 1, "schemes": Self.schemes.count,
                 "dark": NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua]
        }
        return p
    }
    func sendPalette(announce: Bool = false) {
        guard pageReady else { return }
        var p = palette()
        p["announce"] = announce
        js("MacMark.palette(\(Machine.json(p)))")
    }

    // MARK: page

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "ready":
            pageReady = true
            sendPalette()
            if let n = arg("--mode") { js("MacMark.lockMode(\(Machine.json([n]))[0])") }
            send()
        case "copy":
            if let text = message.body as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "regions":
            if let d = message.body as? [String: Any] {
                if let h = d["header"] as? NSNumber { web.headerHeight = CGFloat(h.doubleValue) }
                if let rs = d["noDrag"] as? [[String: Any]] {
                    web.noDrag = rs.map { r in
                        let n = { (k: String) in CGFloat((r[k] as? NSNumber)?.doubleValue ?? 0) }
                        return CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h"))
                    }
                }
            }
        case "close":
            window.performClose(nil)
        case "colors":
            cycleScheme()
        case "error", "log":
            FileHandle.standardError.write("MacMark page: \(message.body)\n".data(using: .utf8)!)
        default: break
        }
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    // MARK: snapshot (for checking the drawing without a screen)

    var shot = false
    func shoot() {
        guard !shot, let path = shotPath else { return }
        shot = true
        let wait = Double(arg("--wait") ?? "") ?? 2.0
        var steps: [String] = []
        if args.contains("--strip") { steps.append("MacMark.go(0)") }
        if let h = arg("--hover") { steps.append("MacMark.hover(\(Int(h) ?? 0))") }
        let extra = args.contains("--strip") ? 6.5 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            for s in steps { self.js(s) }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + extra) {
                let cfg = WKSnapshotConfiguration()
                self.web.takeSnapshot(with: cfg) { img, err in
                    guard let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else {
                        FileHandle.standardError.write("MacMark: snapshot failed: \(String(describing: err))\n".data(using: .utf8)!)
                        exit(1)
                    }
                    // The window's own background under the page.
                    try? png.write(to: URL(fileURLWithPath: path))
                    print(path)
                    exit(0)
                }
            }
        }
    }
}

// (IOKit's power-source callback is a C function: it can't hold the
// controller, so it calls this.)
var powerChanged: (() -> Void)?

// MARK: - main

if args.contains("--json") {
    _ = NSApplication.shared
    print(Machine.json(Machine.read()))
    exit(0)
}
if args.contains("--storage") {
    _ = NSApplication.shared
    let d = Machine.storage()
    print(Machine.json(Machine.storageParts(total: d["total"] as? Int ?? 0, used: d["used"] as? Int ?? 0)))
    exit(0)
}
if args.contains("--live") {
    print(Machine.json(Machine.live()))
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(arg("--shot") == nil ? .regular : .accessory)
let controller = Controller()

// A minimal menu: Close and Quit (so ⌘W and ⌘Q work; ⌘C is the page's own).
let menu = NSMenu()
let appItem = NSMenuItem()
menu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit MacMark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
let fileItem = NSMenuItem()
menu.addItem(fileItem)
let fileMenu = NSMenu(title: "File")
fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
fileItem.submenu = fileMenu
app.mainMenu = menu

controller.start()
app.run()
