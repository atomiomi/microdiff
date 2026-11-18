import AppKit
import CoreText

/// A piece of text in one color.
struct TextRun {
    var text: String
    var ink: Ink

    init(_ text: String, _ ink: Ink) {
        self.text = text
        self.ink = ink
    }
}

/// Laid-out text lines, cached so that redrawing a row never lays text out twice.
final class TextCache {
    static let shared = TextCache()

    private struct Key: Hashable {
        var text: String
        var face: Int
        var ink: Int
    }

    private var lines: [Key: CTLine] = [:]
    /// Enough for every row on screen many times over; emptied when full instead of tracking age.
    /// Names, titles and labels only (the code view keeps its own line numbers): ~1.4 KB each, so ~1.4 MB when full.
    let limit = 1000

    /// Lines held right now (never more than `limit`).
    var count: Int { lines.count }

    /// Drops every cached line (tests use it to compare memory with the cache in the same state).
    func removeAll() {
        lines.removeAll()
    }

    func line(_ text: String, _ face: Face, _ ink: Ink) -> CTLine {
        let key = Key(text: text, face: face.rawValue, ink: ink.rawValue)
        if let cached = lines[key] { return cached }
        if lines.count >= limit { lines.removeAll(keepingCapacity: true) }
        let line = Self.makeLine([TextRun(text, ink)], face)
        lines[key] = line
        return line
    }

    static func makeLine(_ runs: [TextRun], _ face: Face) -> CTLine {
        let attributed = NSMutableAttributedString()
        for run in runs {
            attributed.append(NSAttributedString(string: run.text, attributes: [
                .init(kCTFontAttributeName as String): face.font,
                .init(kCTForegroundColorAttributeName as String): run.ink.cg,
            ]))
        }
        return CTLineCreateWithAttributedString(attributed)
    }
}

extension CTLine {
    var width: CGFloat {
        CGFloat(CTLineGetTypographicBounds(self, nil, nil, nil))
    }

    /// The same line cut to `maxWidth` with "…" at the end, or itself when it fits.
    func truncated(to maxWidth: CGFloat, face: Face, ink: Ink) -> CTLine {
        guard width > maxWidth, maxWidth > 0 else { return self }
        let token = TextCache.shared.line("…", face, ink)
        return CTLineCreateTruncatedLine(self, Double(maxWidth), .end, token) ?? self
    }
}

extension CGContext {
    /// Draws `line` with its left edge at `x`, vertically centered in a row. The context is flipped (y grows down).
    func draw(_ line: CTLine, x: CGFloat, rowY: CGFloat, rowHeight: CGFloat, face: Face) {
        let font = face.font
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let baseline = rowY + (rowHeight - (ascent + descent)) / 2 + ascent
        textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // Half-point steps keep glyphs sharp on Retina screens.
        textPosition = CGPoint(x: x, y: (baseline * 2).rounded() / 2)
        CTLineDraw(line, self)
    }

    /// Draws text and returns its width.
    @discardableResult
    func draw(_ text: String, _ face: Face, _ ink: Ink, x: CGFloat, rowY: CGFloat, rowHeight: CGFloat) -> CGFloat {
        let line = TextCache.shared.line(text, face, ink)
        draw(line, x: x, rowY: rowY, rowHeight: rowHeight, face: face)
        return line.width
    }

    /// Draws text so that it ends at `right`. Returns its left edge.
    @discardableResult
    func drawRightAligned(_ text: String, _ face: Face, _ ink: Ink, right: CGFloat, rowY: CGFloat, rowHeight: CGFloat) -> CGFloat {
        let line = TextCache.shared.line(text, face, ink)
        let x = right - line.width
        draw(line, x: x, rowY: rowY, rowHeight: rowHeight, face: face)
        return x
    }

    func fill(_ rect: CGRect, _ color: CGColor) {
        setFillColor(color)
        fill(rect)
    }
}
