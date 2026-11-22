import AppKit
import Carbon.HIToolbox
import ServiceManagement

enum Tool: String, CaseIterable, Identifiable {
    case pen, highlighter, rect, ellipse, arrow, text, eraser
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .eraser: "eraser"
        }
    }

    var name: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .rect: "Box"
        case .ellipse: "Circle"
        case .arrow: "Arrow"
        case .text: "Text"
        case .eraser: "Eraser"
        }
    }

    var key: String {
        switch self {
        case .pen: "p"
        case .highlighter: "h"
        case .rect: "b"
        case .ellipse: "c"
        case .arrow: "a"
        case .text: "t"
        case .eraser: "e"
        }
    }

    var shapeKind: Shape.Kind? {
        switch self {
        case .pen: .pen
        case .highlighter: .highlighter
        case .rect: .rect
        case .ellipse: .ellipse
        case .arrow: .arrow
        case .text: .text
        case .eraser: nil
        }
    }
}

enum FadeOption: Double, CaseIterable, Identifiable {
    case keep = 0, two = 2, five = 5, ten = 10, thirty = 30
    var id: Double { rawValue }
    var short: String { self == .keep ? "Keep" : "\(Int(rawValue))s" }
    var long: String { self == .keep ? "Keep on screen" : "Fade after \(Int(rawValue)) seconds" }
}

struct FontChoice: Identifiable {
    let name: String
    let make: (CGFloat) -> NSFont
    var id: String { name }

    static func family(_ family: String, _ name: String) -> FontChoice {
        FontChoice(name: name) { size in
            NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
                ?? .systemFont(ofSize: size, weight: .semibold)
        }
    }
    static func system(_ name: String, _ design: NSFontDescriptor.SystemDesign, _ weight: NSFont.Weight) -> FontChoice {
        FontChoice(name: name) { size in
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        }
    }

    static let all: [FontChoice] = [
        .family("Chalkboard SE", "Hand"),
        .family("Marker Felt", "Marker"),
        .family("Bradley Hand", "Script"),
        .system("Sans", .default, .semibold),
        .system("Rounded", .rounded, .bold),
        .system("Serif", .serif, .semibold),
        .system("Mono", .monospaced, .medium),
    ]
}

let palette: [NSColor] = [
    NSColor(red: 0.96, green: 0.23, blue: 0.23, alpha: 1),  // red
    NSColor(red: 1.00, green: 0.58, blue: 0.10, alpha: 1),  // orange
    NSColor(red: 1.00, green: 0.85, blue: 0.10, alpha: 1),  // yellow
    NSColor(red: 0.20, green: 0.80, blue: 0.35, alpha: 1),  // green
    NSColor(red: 0.15, green: 0.55, blue: 1.00, alpha: 1),  // blue
    NSColor(red: 0.62, green: 0.35, blue: 0.96, alpha: 1),  // purple
    .white,
    .black,
]

let strokeWidths: [CGFloat] = [2, 4, 7, 11]
let textSizes: [CGFloat] = [18, 26, 36, 52]

/// Above normal windows and full-screen apps; below pop-up menus so the toolbar's menus still work.
let overlayLevel = NSWindow.Level.statusBar
let toolbarLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

@MainActor
final class Controller: NSObject, ObservableObject {
    static let shared = Controller()

    @Published private(set) var drawing = false
    @Published var tool: Tool = .pen { didSet { if oldValue != tool { commitText() } } }
    @Published var color: NSColor = palette[0]
    @Published var widthIndex = 1
    @Published var sketchy = true
    @Published var fontIndex = 0
    @Published var fade: FadeOption = .five
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private(set) var shapes: [Shape] = [] { didSet { redraw() } }
    private var history: [[Shape]] = []
    private var overlays: [OverlayWindow] = []
    private var toolbar: FloatingPanel?
    private var toolbarPlaced = false
    private var toast: FloatingPanel?
    private var toastToken = 0
    private var previousApp: NSRunningApplication?
    private var wasFading = false
    private var erasedThisStroke = false

    var width: CGFloat { strokeWidths[widthIndex] }
    var font: NSFont { FontChoice.all[fontIndex].make(textSizes[widthIndex]) }

    var screenshotFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Draw IO", isDirectory: true)
    }

    // MARK: - Setup

    func start() {
        rebuildOverlays()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Controller.shared.rebuildOverlays() }
        }

        HotKeys.install()
        HotKeys.register(1, key: kVK_ANSI_D) { Controller.shared.toggleDrawing() }
        HotKeys.register(2, key: kVK_ANSI_C) { Controller.shared.clear() }
        HotKeys.register(3, key: kVK_ANSI_S) { Controller.shared.screenshot(area: true) }

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { Controller.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            showToast(Toast(title: "Draw IO is in your menu bar",
                            subtitle: "Press ⌃⌥D anywhere to start drawing, and Esc to stop.",
                            icon: "pencil.tip.crop.circle"))
        }
    }

    private func rebuildOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = NSScreen.screens.map { screen in
            let window = OverlayWindow(screen: screen)
            window.ignoresMouseEvents = !drawing
            window.orderFrontRegardless()
            return window
        }
    }

    // MARK: - Drawing mode

    func toggleDrawing() { setDrawing(!drawing) }

    func setDrawing(_ on: Bool) {
        guard on != drawing else { return }
        drawing = on
        if on {
            let front = NSWorkspace.shared.frontmostApplication
            if front != NSRunningApplication.current { previousApp = front }
            NSApp.activate(ignoringOtherApps: true)
            overlays.forEach { $0.ignoresMouseEvents = false }
            (overlays.first { $0.screen == screenUnderMouse } ?? overlays.first)?.makeKeyAndOrderFront(nil)
            showToolbar()
        } else {
            commitText()
            overlays.forEach { $0.ignoresMouseEvents = true }
            toolbar?.orderOut(nil)
            previousApp?.activate()
            previousApp = nil
        }
    }

    private func showToolbar() {
        if toolbar == nil {
            toolbar = FloatingPanel(content: FirstMouseHostingView(rootView: ToolbarView()))
        }
        guard let toolbar else { return }
        if !toolbarPlaced, let screen = screenUnderMouse {
            let f = screen.visibleFrame
            toolbar.setFrameOrigin(NSPoint(x: f.midX - toolbar.frame.width / 2,
                                           y: f.maxY - toolbar.frame.height - 16))
            toolbarPlaced = true
        }
        toolbar.orderFrontRegardless()
    }

    var screenUnderMouse: NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: - Editing shapes

    func begin(_ shape: Shape) {
        pushHistory()
        shapes.append(shape)
    }

    func updateLast(_ change: (inout Shape) -> Void) {
        guard !shapes.isEmpty else { return }
        change(&shapes[shapes.count - 1])
    }

    /// Called when the mouse is released. Drops accidental clicks with the shape tools.
    func finishLast() {
        guard var last = shapes.last, last.finished == nil else { return }
        if [.rect, .ellipse, .arrow].contains(last.kind), hypot(last.end.x - last.start.x, last.end.y - last.start.y) < 4 {
            shapes.removeLast()
            history.removeLast()
            return
        }
        last.finished = Date()
        last.fadeAfter = fade == .keep ? nil : fade.rawValue
        shapes[shapes.count - 1] = last
    }

    func addText(_ text: String, at origin: CGPoint, screenID: CGDirectDisplayID) {
        var shape = Shape(kind: .text, screenID: screenID, points: [origin], color: color, width: width, sketchy: false)
        shape.text = text
        shape.font = font
        shape.finished = Date()
        shape.fadeAfter = fade == .keep ? nil : fade.rawValue
        begin(shape)
    }

    func beginErasing() { erasedThisStroke = false }

    func erase(at point: CGPoint, screenID: CGDirectDisplayID) {
        guard let i = shapes.lastIndex(where: { $0.screenID == screenID && Renderer.hits($0, point) }) else { return }
        if !erasedThisStroke { pushHistory(); erasedThisStroke = true }
        shapes.remove(at: i)
    }

    func undo() {
        commitText()
        guard let previous = history.popLast() else { NSSound.beep(); return }
        shapes = previous
    }

    func clear() {
        commitText()
        guard !shapes.isEmpty else { return }
        pushHistory()
        shapes = []
    }

    /// Stops everything currently on screen from fading.
    func keepAll() {
        commitText()
        let now = Date()
        for i in shapes.indices where shapes[i].opacity(at: now) > 0 {
            shapes[i].fadeAfter = nil
        }
    }

    func commitText() { overlays.forEach { $0.canvas.commitText() } }

    private func pushHistory() {
        history.append(shapes)
        if history.count > 200 { history.removeFirst() }
    }

    private func redraw() { overlays.forEach { $0.canvas.needsDisplay = true } }

    private func tick() {
        let now = Date()
        let fading = shapes.contains { $0.isFading(at: now) }
        if fading || wasFading {
            shapes.removeAll { $0.finished != nil && $0.opacity(at: now) <= 0 }
            redraw()
        }
        wasFading = fading
    }

    // MARK: - Settings

    func pickCustomColor() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        panel.level = NSWindow.Level(rawValue: toolbarLevel.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        color = sender.color
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Draw IO: login item change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Screenshots

    /// Captures the screen with the annotations on it, copies it to the clipboard and saves a PNG.
    func screenshot(area: Bool) {
        commitText()
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            showToast(Toast(
                title: "Screen Recording permission needed",
                subtitle: "Turn on Draw IO in System Settings → Privacy & Security → Screen Recording, then quit and reopen Draw IO.",
                icon: "exclamationmark.triangle.fill",
                actionTitle: "Open Settings",
                action: {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }), seconds: 15)
            return
        }

        try? FileManager.default.createDirectory(at: screenshotFolder, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .dateSeparator(.dash).timeSeparator(.omitted).dateTimeSeparator(.space))
        let url = screenshotFolder.appendingPathComponent("Annotated \(stamp).png")

        var args = ["-x"]
        if area {
            args += ["-i", "-s"]
        } else if let screen = screenUnderMouse, let primary = NSScreen.screens.first {
            let f = screen.frame
            args += ["-R", "\(Int(f.minX)),\(Int(primary.frame.maxY - f.maxY)),\(Int(f.width)),\(Int(f.height))"]
        }
        args.append(url.path)

        // Get our own controls out of the way; the drawings stay.
        toolbar?.orderOut(nil)
        toast?.orderOut(nil)
        overlays.forEach { $0.ignoresMouseEvents = true }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = args
            process.terminationHandler = { _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { Controller.shared.screenshotDone(url) }
                }
            }
            do { try process.run() } catch { self.screenshotDone(url) }
        }
    }

    private func screenshotDone(_ url: URL) {
        overlays.forEach { $0.ignoresMouseEvents = !drawing }
        if drawing {
            showToolbar()
            (overlays.first { $0.screen == screenUnderMouse } ?? overlays.first)?.makeKey()
        }
        guard let image = NSImage(contentsOf: url) else { return }  // cancelled with Esc

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        if let png = try? Data(contentsOf: url) { pasteboard.setData(png, forType: .png) }
        if let tiff = image.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }

        showToast(Toast(title: "Copied to clipboard",
                        subtitle: "Paste it anywhere with ⌘V, or share it now.",
                        thumbnail: image, fileURL: url), seconds: 12)
    }

    // MARK: - Toasts

    func showToast(_ info: Toast, seconds: Double = 6) {
        toast?.orderOut(nil)
        toastToken += 1
        let token = toastToken
        let panel = FloatingPanel(content: FirstMouseHostingView(rootView: ToastView(toast: info) {
            Controller.shared.hideToast()
        }))
        if let screen = screenUnderMouse {
            let f = screen.visibleFrame
            var y = f.maxY - panel.frame.height - 16
            if let toolbar, toolbar.isVisible, toolbar.screen == screen { y = toolbar.frame.minY - panel.frame.height - 10 }
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: y))
        }
        panel.orderFrontRegardless()
        toast = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                if Controller.shared.toastToken == token { Controller.shared.hideToast() }
            }
        }
    }

    func hideToast() {
        toast?.orderOut(nil)
        toast = nil
    }
}

/// System-wide keyboard shortcuts (⌃⌥ + key). Uses Carbon hot keys, which need no extra permissions.
enum HotKeys {
    nonisolated(unsafe) private static var actions: [UInt32: @MainActor () -> Void] = [:]
    nonisolated(unsafe) private static var refs: [EventHotKeyRef?] = []

    static func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.actions[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func register(_ id: UInt32, key: Int, action: @escaping @MainActor () -> Void) {
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: OSType(0x4452_4157), id: id),
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}
