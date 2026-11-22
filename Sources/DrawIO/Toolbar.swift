import SwiftUI
import AppKit

/// A borderless floating panel that never steals focus from the app you're presenting.
/// `sharingType = .none` keeps it out of screen shares and screenshots, so viewers only see your drawings.
final class FloatingPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: content.fittingSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = toolbarLevel
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none
        contentView = content
    }

    override var canBecomeKey: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Toolbar

struct ToolbarView: View {
    @ObservedObject private var c = Controller.shared

    var body: some View {
        HStack(spacing: 4) {
            DragHandle()
                .frame(width: 14, height: 28)
                .overlay(Image(systemName: "line.3.horizontal").rotationEffect(.degrees(90))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).allowsHitTesting(false))

            ForEach(Tool.allCases) { tool in
                IconButton(icon: tool.icon, selected: c.tool == tool,
                           help: "\(tool.name) (\(tool.key.uppercased()))") { c.tool = tool }
            }

            separator

            ForEach(palette.indices, id: \.self) { i in
                Swatch(color: palette[i], selected: c.color == palette[i]) { c.color = palette[i] }
            }
            Swatch(color: nil, selected: !palette.contains(c.color)) { c.pickCustomColor() }
                .help("Custom colour")

            separator

            ForEach(strokeWidths.indices, id: \.self) { i in
                Button { c.widthIndex = i } label: {
                    Circle()
                        .frame(width: 3 + strokeWidths[i] * 1.1, height: 3 + strokeWidths[i] * 1.1)
                        .frame(width: 22, height: 28)
                        .foregroundStyle(c.widthIndex == i ? Color.accentColor : Color.primary.opacity(0.7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Thickness \(i + 1) — also sets text size (\(i + 1))")
            }

            separator

            IconButton(icon: "scribble.variable", selected: c.sketchy, help: "Hand-drawn boxes, circles & arrows (S)") {
                c.sketchy = true
            }
            IconButton(icon: "ruler", selected: !c.sketchy, help: "Exact boxes, circles & arrows (S)") {
                c.sketchy = false
            }

            Menu {
                ForEach(FontChoice.all.indices, id: \.self) { i in
                    Toggle(FontChoice.all[i].name, isOn: Binding(get: { c.fontIndex == i }, set: { _ in c.fontIndex = i }))
                }
            } label: {
                Text("Aa").font(Font(FontChoice.all[c.fontIndex].make(15)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 34, height: 28)
            .help("Text font: \(FontChoice.all[c.fontIndex].name) (F)")

            separator

            Menu {
                ForEach(FadeOption.allCases) { option in
                    Toggle(option.long, isOn: Binding(get: { c.fade == option }, set: { _ in c.fade = option }))
                }
            } label: {
                Label(c.fade.short, systemImage: c.fade == .keep ? "pin.fill" : "timer")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 58, height: 28)
            .help("When new drawings fade away")

            IconButton(icon: "pin", help: "Keep everything on screen — stop it fading (K)") { c.keepAll() }
            IconButton(icon: "arrow.uturn.backward", help: "Undo (⌘Z)") { c.undo() }
            IconButton(icon: "trash", help: "Clear everything (X  or  ⌃⌥C)") { c.clear() }

            separator

            Menu {
                Button("Capture Area…  ⌃⌥S") { c.screenshot(area: true) }
                Button("Capture Whole Screen") { c.screenshot(area: false) }
                Divider()
                Button("Open Screenshots Folder") {
                    try? FileManager.default.createDirectory(at: c.screenshotFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(c.screenshotFolder)
                }
            } label: {
                Image(systemName: "camera").font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 30, height: 28)
            .help("Screenshot with your drawings — copied to the clipboard")

            IconButton(icon: "xmark", help: "Stop drawing (Esc) — drawings stay on screen") { c.setDrawing(false) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)))
        .fixedSize()
    }

    private var separator: some View {
        Divider().frame(height: 20).padding(.horizontal, 3)
    }
}

struct IconButton: View {
    let icon: String
    var selected = false
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct Swatch: View {
    let color: NSColor?   // nil = custom colour picker
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let color {
                    Circle().fill(Color(nsColor: color))
                } else {
                    Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple, .red], center: .center))
                }
                Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1)
            }
            .frame(width: 16, height: 16)
            .padding(2)
            .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
            .frame(width: 22, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Drag this to move the toolbar.
struct DragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
    func makeNSView(context: Context) -> NSView { HandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Toast

struct Toast {
    var title: String
    var subtitle: String
    var icon = "checkmark.circle.fill"
    var thumbnail: NSImage?
    var fileURL: URL?
    var actionTitle: String?
    var action: (() -> Void)?
}

struct ToastView: View {
    let toast: Toast
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let image = toast.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.15)))
            } else {
                Image(systemName: toast.icon).font(.system(size: 22)).foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.system(size: 13, weight: .semibold))
                Text(toast.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let url = toast.fileURL {
                ShareButton(url: url).fixedSize()
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .controlSize(.small)
            }
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) { action(); close() }.controlSize(.small)
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)))
    }
}

/// Opens the macOS share menu (Messages, Mail, AirDrop, Slack…) for the screenshot.
struct ShareButton: NSViewRepresentable {
    let url: URL

    final class Coordinator: NSObject {
        var url: URL
        init(url: URL) { self.url = url }
        @MainActor @objc func share(_ sender: NSButton) {
            NSApp.activate(ignoringOtherApps: true)
            NSSharingServicePicker(items: [url]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Share…", target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.url = url }
}
