import AppKit

/// One annotation on screen.
struct Shape: Identifiable {
    enum Kind { case pen, highlighter, rect, ellipse, arrow, text }

    let id = UUID()
    var kind: Kind
    var screenID: CGDirectDisplayID
    var points: [CGPoint]          // pen/highlighter: the stroke; shapes: [start, end]; text: [top-left]
    var color: NSColor
    var width: CGFloat
    var sketchy: Bool
    var seed = UInt64.random(in: 1...UInt64.max)
    var text = ""
    var font = NSFont.systemFont(ofSize: 24)
    var finished: Date?            // set when the user lets go; fading counts from here
    var fadeAfter: TimeInterval?   // nil = stays on screen until deleted

    static let fadeDuration: TimeInterval = 0.8

    var start: CGPoint { points.first ?? .zero }
    var end: CGPoint { points.last ?? .zero }

    func opacity(at now: Date) -> CGFloat {
        guard let fadeAfter, let finished else { return 1 }
        let t = now.timeIntervalSince(finished) - fadeAfter
        return t <= 0 ? 1 : CGFloat(max(0, 1 - t / Self.fadeDuration))
    }

    func isFading(at now: Date) -> Bool {
        guard let fadeAfter, let finished else { return false }
        return now.timeIntervalSince(finished) > fadeAfter
    }

    var attributedText: NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }
}

/// Deterministic random numbers, so a sketchy shape looks the same every time it's redrawn.
struct SeededRandom {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
    /// Uniform in -x...x
    mutating func spread(_ x: CGFloat) -> CGFloat { CGFloat(next() * 2 - 1) * x }
}

enum Renderer {
    static func draw(_ s: Shape, alpha: CGFloat) {
        guard alpha > 0 else { return }
        let color = s.color.withAlphaComponent(s.color.alphaComponent * alpha)

        switch s.kind {
        case .text:
            NSAttributedString(string: s.text, attributes: [.font: s.font, .foregroundColor: color])
                .draw(at: s.start)

        case .highlighter:
            let path = smoothPath(s.points)
            path.lineWidth = highlighterWidth(s.width)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.withAlphaComponent(0.35 * alpha).setStroke()
            path.stroke()

        case .pen:
            stroke(smoothPath(s.points), s.width, color)

        case .rect, .ellipse, .arrow:
            if s.sketchy {
                var rng = SeededRandom(state: s.seed)
                let path = NSBezierPath()
                let rough = 1 + s.width * 0.08
                for _ in 0..<2 { addSketch(s, &rng, rough, path) }
                stroke(path, max(1.5, s.width * 0.85), color)
            } else if s.kind == .arrow {
                let (shaft, head) = exactArrow(s)
                stroke(shaft, s.width, color)
                color.setFill()
                head.fill()
                stroke(head, s.width, color)
            } else {
                stroke(exactPath(s), s.width, color)
            }
        }
    }

    /// Whether a point is on (or near) the shape — used by the eraser.
    static func hits(_ s: Shape, _ p: CGPoint) -> Bool {
        if s.kind == .text { return textRect(s).insetBy(dx: -6, dy: -6).contains(p) }
        let width = s.kind == .highlighter ? highlighterWidth(s.width) : s.width
        let outline = exactPath(s).cgPath.copy(strokingWithWidth: width + 16, lineCap: .round,
                                               lineJoin: .round, miterLimit: 10)
        return outline.contains(p)
    }

    static func textRect(_ s: Shape) -> CGRect {
        CGRect(origin: s.start, size: s.attributedText.size())
    }

    // MARK: - Exact geometry

    static func rect(_ s: Shape) -> CGRect {
        CGRect(x: min(s.start.x, s.end.x), y: min(s.start.y, s.end.y),
               width: abs(s.end.x - s.start.x), height: abs(s.end.y - s.start.y))
    }

    static func exactPath(_ s: Shape) -> NSBezierPath {
        switch s.kind {
        case .pen, .highlighter, .text: return smoothPath(s.points)
        case .rect: return NSBezierPath(roundedRect: rect(s), xRadius: 2, yRadius: 2)
        case .ellipse: return NSBezierPath(ovalIn: rect(s))
        case .arrow:
            let (shaft, head) = exactArrow(s)
            shaft.append(head)
            return shaft
        }
    }

    private static func arrowGeometry(_ s: Shape) -> (tip: CGPoint, left: CGPoint, right: CGPoint, base: CGPoint) {
        let a = s.start, b = s.end
        let angle = atan2(b.y - a.y, b.x - a.x)
        let length = hypot(b.x - a.x, b.y - a.y)
        let head = min(max(16, s.width * 4.5), length * 0.6)
        let spread = CGFloat.pi / 7
        func back(_ off: CGFloat, _ len: CGFloat) -> CGPoint {
            CGPoint(x: b.x - len * cos(angle + off), y: b.y - len * sin(angle + off))
        }
        return (b, back(-spread, head), back(spread, head), back(0, head * cos(spread)))
    }

    private static func exactArrow(_ s: Shape) -> (NSBezierPath, NSBezierPath) {
        let g = arrowGeometry(s)
        let shaft = NSBezierPath()
        shaft.move(to: s.start)
        shaft.line(to: g.base)
        let head = NSBezierPath()
        head.move(to: g.tip)
        head.line(to: g.left)
        head.line(to: g.right)
        head.close()
        return (shaft, head)
    }

    // MARK: - Hand-drawn geometry

    private static func addSketch(_ s: Shape, _ rng: inout SeededRandom, _ rough: CGFloat, _ path: NSBezierPath) {
        switch s.kind {
        case .rect:
            let r = rect(s)
            let c = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                     CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            for i in 0..<4 { roughLine(c[i], c[(i + 1) % 4], &rng, rough, path) }
        case .ellipse:
            roughEllipse(rect(s), &rng, rough, path)
        case .arrow:
            let g = arrowGeometry(s)
            roughLine(s.start, g.tip, &rng, rough, path, bow: 1.3)
            roughLine(g.left, g.tip, &rng, rough * 0.6, path)
            roughLine(g.right, g.tip, &rng, rough * 0.6, path)
        default:
            break
        }
    }

    private static func roughLine(_ a: CGPoint, _ b: CGPoint, _ rng: inout SeededRandom,
                                  _ rough: CGFloat, _ path: NSBezierPath, bow: CGFloat = 1) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 0.001)
        let nx = -dy / len, ny = dx / len
        let off = min(len * 0.02, 2.5) * rough
        func at(_ t: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: a.x + dx * t + nx * side, y: a.y + dy * t + ny * side)
        }
        let bend = rng.spread(off * 1.5) * bow
        let start = CGPoint(x: a.x + rng.spread(off * 0.6), y: a.y + rng.spread(off * 0.6))
        let end = CGPoint(x: b.x + rng.spread(off * 0.6), y: b.y + rng.spread(off * 0.6))
        path.move(to: start)
        path.curve(to: end,
                   controlPoint1: at(0.3 + rng.spread(0.08), bend + rng.spread(off * 0.5)),
                   controlPoint2: at(0.7 + rng.spread(0.08), bend + rng.spread(off * 0.5)))
    }

    private static func roughEllipse(_ r: CGRect, _ rng: inout SeededRandom, _ rough: CGFloat, _ path: NSBezierPath) {
        let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
        let count = min(40, max(12, Int((rx + ry) / 10)))
        let startAngle = rng.next() * 2 * .pi
        let sweep = 2 * Double.pi + 0.25 + rng.next() * 0.35   // overshoot like a real pen
        let jitter = (min(rx, ry) * 0.02 + 1) * rough
        var pts: [CGPoint] = []
        for i in 0...count {
            let t = startAngle + sweep * Double(i) / Double(count)
            let j = rng.spread(jitter)
            pts.append(CGPoint(x: cx + (rx + j) * cos(t), y: cy + (ry + j) * sin(t)))
        }
        catmullRom(pts, into: path)
    }

    // MARK: - Helpers

    static func highlighterWidth(_ w: CGFloat) -> CGFloat { w * 3 + 10 }

    private static func stroke(_ path: NSBezierPath, _ width: CGFloat, _ color: NSColor) {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    static func smoothPath(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        if points.count < 3 {
            path.move(to: first)
            let last = points.last!
            path.line(to: last == first ? CGPoint(x: first.x + 0.01, y: first.y) : last)  // a click draws a dot
            return path
        }
        catmullRom(points, into: path)
        return path
    }

    private static func catmullRom(_ pts: [CGPoint], into path: NSBezierPath) {
        path.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            path.curve(to: p2,
                       controlPoint1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                       controlPoint2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
    }
}
