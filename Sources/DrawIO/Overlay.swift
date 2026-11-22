import AppKit

/// A transparent, borderless window covering one display. Annotations are drawn into it.
/// When drawing mode is off it ignores the mouse, so clicks go through to the apps underneath.
final class OverlayWindow: NSWindow {
    let canvas: CanvasView

    init(screen: NSScreen) {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        canvas = CanvasView(screenID: id)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = overlayLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        contentView = canvas
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CanvasView: NSView, NSTextFieldDelegate {
    let screenID: CGDirectDisplayID
    private var c: Controller { .shared }
    private var textField: NSTextField?
    private var erasing = false

    init(screenID: CGDirectDisplayID) {
        self.screenID = screenID
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let now = Date()
        for shape in c.shapes where shape.screenID == screenID {
            Renderer.draw(shape, alpha: shape.opacity(at: now))
        }
    }

    // MARK: - Cursor

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { setCursor() }
    override func mouseMoved(with event: NSEvent) { setCursor() }

    private func setCursor() {
        guard c.drawing else { return }
        (c.tool == .text ? NSCursor.iBeam : c.tool == .eraser ? NSCursor.disappearingItem : NSCursor.crosshair).set()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let p = convert(event.locationInWindow, from: nil)
        let wasEditing = textField != nil
        commitText()

        switch c.tool {
        case .text:
            if !wasEditing { beginText(at: p) }
        case .eraser:
            erasing = true
            c.beginErasing()
            c.erase(at: p, screenID: screenID)
        default:
            guard let kind = c.tool.shapeKind else { return }
            c.begin(Shape(kind: kind, screenID: screenID, points: [p, p], color: c.color,
                          width: c.width, sketchy: c.sketchy))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        var p = convert(event.locationInWindow, from: nil)
        if erasing { c.erase(at: p, screenID: screenID); return }
        guard let last = c.shapes.last, last.finished == nil, last.screenID == screenID else { return }

        switch last.kind {
        case .pen, .highlighter:
            if let prev = last.points.last, hypot(p.x - prev.x, p.y - prev.y) < 1.5 { return }
            c.updateLast { $0.points.append(p) }
        case .rect, .ellipse, .arrow:
            if event.modifierFlags.contains(.shift) { p = constrain(last.kind, from: last.start, to: p) }
            c.updateLast { $0.points = [$0.start, p] }
        case .text:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if erasing { erasing = false; return }
        c.finishLast()
    }

    /// Shift: perfect squares and circles, arrows snap to 45°.
    private func constrain(_ kind: Shape.Kind, from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        if kind == .arrow {
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let len = hypot(dx, dy)
            return CGPoint(x: a.x + len * cos(angle), y: a.y + len * sin(angle))
        }
        let m = max(abs(dx), abs(dy))
        return CGPoint(x: a.x + (dx < 0 ? -m : m), y: a.y + (dy < 0 ? -m : m))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { c.setDrawing(false); return }  // Esc
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return super.keyDown(with: event) }

        if let tool = Tool.allCases.first(where: { $0.key == key }) {
            c.tool = tool
        } else if let n = Int(key), (1...strokeWidths.count).contains(n) {
            c.widthIndex = n - 1
        } else {
            switch key {
            case "s": c.sketchy.toggle()
            case "k": c.keepAll()
            case "x": c.clear()
            case "f": c.fontIndex = (c.fontIndex + 1) % FontChoice.all.count
            default: super.keyDown(with: event)
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if textField == nil, flags == .command, event.charactersIgnoringModifiers == "z" {
            c.undo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Text

    private func beginText(at p: CGPoint) {
        let field = NSTextField(string: "")
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = c.font
        field.textColor = c.color
        field.usesSingleLineMode = false
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.placeholderAttributedString = NSAttributedString(string: "Type…", attributes: [
            .font: c.font, .foregroundColor: c.color.withAlphaComponent(0.45),
        ])
        field.delegate = self
        field.sizeToFit()
        field.frame.size.width = max(field.frame.width, 60)
        field.setFrameOrigin(CGPoint(x: p.x - 2, y: p.y - field.frame.height / 2))
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue
        let origin = CGPoint(x: field.frame.minX + 2, y: field.frame.minY)
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            c.addText(text, at: origin, screenID: screenID)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        let origin = field.frame.origin
        field.sizeToFit()
        field.frame.size.width = max(field.frame.width + 8, 60)
        field.setFrameOrigin(origin)
    }

    /// Return finishes the text; Option-Return adds a new line; Esc finishes too.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)):
            commitText()
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            return true
        default:
            return false
        }
    }
}
