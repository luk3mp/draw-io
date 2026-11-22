import SwiftUI

@main
struct DrawIOApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var c = Controller.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            Image(systemName: c.drawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Controller.shared.start()
    }

    /// Opening the app again (from Applications, Spotlight or Launchpad) starts drawing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Controller.shared.setDrawing(true)
        return false
    }
}

struct MenuContent: View {
    @ObservedObject private var c = Controller.shared

    var body: some View {
        Button(c.drawing ? "Stop Drawing" : "Start Drawing") { c.toggleDrawing() }
            .keyboardShortcut("d", modifiers: [.control, .option])

        Divider()

        Button("Capture Area…") { c.screenshot(area: true) }
            .keyboardShortcut("s", modifiers: [.control, .option])
        Button("Capture Whole Screen") { c.screenshot(area: false) }
        Button("Open Screenshots Folder") {
            try? FileManager.default.createDirectory(at: c.screenshotFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(c.screenshotFolder)
        }

        Divider()

        Button("Keep Everything on Screen") { c.keepAll() }
        Button("Clear Everything") { c.clear() }
            .keyboardShortcut("c", modifiers: [.control, .option])

        Divider()

        Toggle("Open at Login", isOn: Binding(get: { c.launchAtLogin }, set: { c.setLaunchAtLogin($0) }))
        Button("Quit Draw IO") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
