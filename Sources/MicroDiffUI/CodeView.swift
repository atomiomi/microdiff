import AppKit
import CoreText
import MicroDiffCore

/// Shows one file: a unified diff, the whole file, or a deleted file. Only visible rows are laid out and drawn.
final class CodeView: CanvasScrollView {
    /// Called with the fold's first hidden line when a fold row is clicked.
    var onExpandFold: ((Int) -> Void)?
    /// Called when the scroll position changes (so it can be remembered per tab).
    var onScroll: ((CGPoint) -> Void)?

    private struct TextPosition: Comparable {
        var row: Int
        /// UTF-16 offset inside the row's text.
        var offset: Int

        static func < (a: TextPosition, b: TextPosition) -> Bool {
            a.row != b.row ? a.row < b.row : a.offset < b.offset
        }
    }

    private struct LaidOutLine {
        var line: CTLine
        /// Length of the text in UTF-16 units.
        var length: Int
        var width: CGFloat
        /// The gutter's line number, laid out with the line (kept out of the shared text cache, which
        /// scrolling through a long file would otherwise fill with numbers).
        var number: CTLine?
    }

    /// Laid-out lines kept per view: about six screens. A highlighted line costs ~6 KB, so this stays near 1 MB.
    static let lineCacheLimit = 200
    /// Changed-word ranges kept per view (small arrays).
    static let wordRangesLimit = 2000

    private var document: TextDocument?
    private var topPadding: CGFloat = 0
    private var lineCache: [Int: LaidOutLine] = [:]
    /// Changed-word ranges per row, filled in lazily. An empty array means "nothing to highlight".
    private var wordRanges: [Int: [Range<Int>]] = [:]
    private var anchor: TextPosition?
    private var head: TextPosition?
    /// Widest line drawn so far; the horizontal scroll range grows to fit it.
    private var measuredWidth: CGFloat = 0

    private static let bottomPadding: CGFloat = 8
    /// Lines longer than this are cut for display: laying out megabyte-long lines would stall drawing.
    private static let maxDisplayLength = 4000

    private static let baseAttributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = Theme.codeCharWidth * 4
        return [
            .init(kCTFontAttributeName as String): Face.code.font,
            .init(kCTForegroundColorAttributeName as String): Ink.code.cg,
            .paragraphStyle: paragraph,
        ]
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.hasHorizontalScroller = true
    }

    override var acceptsFirstResponder: Bool { true }

    /// A hand over fold rows (a click opens them), a text cursor over code, an arrow over the gutter and empty space.
    override func cursor(at point: CGPoint) -> NSCursor {
        guard let document, document.rows.rowCount > 0 else { return .arrow }
        let y = Double(point.y - topPadding)
        guard y >= 0, y < document.rows.contentHeight else { return .arrow }
        if document.rows.row(at: document.rows.rowIndex(atY: y)).kind == .fold { return .pointingHand }
        return point.x - visibleContentRect.minX < Theme.codeX - 6 ? .arrow : .iBeam
    }

    var scrollOffset: CGPoint { visibleContentRect.origin }

    /// Shows a document. With `keepScroll` the view stays where it is (used when the same file is reloaded).
    func setDocument(_ newDocument: TextDocument?, keepScroll: Bool, scroll: CGPoint = .zero) {
        document = newDocument
        lineCache.removeAll(keepingCapacity: true)
        wordRanges.removeAll(keepingCapacity: true)
        anchor = nil
        head = nil
        measuredWidth = 0
        if let rows = newDocument?.rows, rows.rowCount > 0, rows.row(at: 0).kind == .fold {
            // A fold band at the very top sits flush with the tab bar.
            topPadding = 0
        } else {
            topPadding = 8
        }
        updateContentSize()
        if !keepScroll { self.scroll(to: scroll) }
        refreshPointer()
        setNeedsRedraw()
    }

    override func layout() {
        super.layout()
        updateContentSize()
    }

    private func updateContentSize() {
        guard let document else {
            contentSize = .zero
            return
        }
        let estimated = Theme.codeX + CGFloat(min(document.maxLineByteLength, Self.maxDisplayLength)) * Theme.codeCharWidth + 32
        contentSize = CGSize(
            width: max(bounds.width, estimated, measuredWidth),
            height: topPadding + CGFloat(document.rows.contentHeight) + Self.bottomPadding)
    }

    override func visibleRectChanged() {
        onScroll?(scrollOffset)
    }

    // MARK: - Text

    private func text(forRow row: DiffRow, in document: TextDocument) -> String {
        let buffer = row.kind == .deleted ? document.oldText : document.newText
        guard row.kind != .fold, row.line >= 0, row.line < buffer.lineCount else { return "" }
        return buffer.line(row.line)
    }

    private func laidOutLine(_ index: Int, _ row: DiffRow, _ document: TextDocument) -> LaidOutLine {
        if let cached = lineCache[index] { return cached }
        if lineCache.count >= Self.lineCacheLimit {
            // Keep the lines around this one (what is on screen now, up to ~65 rows each way), forget the far ones.
            let keep = Self.lineCacheLimit / 3
            lineCache = lineCache.filter { abs($0.key - index) < keep }
        }

        var text = text(forRow: row, in: document)
        if text.utf16.count > Self.maxDisplayLength {
            text = String(text.prefix(Self.maxDisplayLength))
        }
        let attributed = NSMutableAttributedString(string: text, attributes: Self.baseAttributes)
        let length = attributed.length
        if let lexer = document.lexer {
            let isOld = row.kind == .deleted
            let tokens = lexer.tokens(
                forLine: row.line, in: isOld ? document.oldText : document.newText,
                states: isOld ? document.oldStates : document.newStates)
            let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
            for token in tokens where token.kind != .plain && token.start < length {
                let range = NSRange(location: token.start, length: min(token.length, length - token.start))
                attributed.addAttribute(colorKey, value: Ink.syntax(token.kind).cg, range: range)
            }
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let number = row.number.map { TextCache.makeLine([TextRun(String($0), .lineNumber)], .regular) }
        let result = LaidOutLine(line: line, length: length, width: line.width, number: number)
        lineCache[index] = result

        let needed = Theme.codeX + result.width + 32
        if needed > measuredWidth, needed > contentSize.width {
            measuredWidth = needed
            // Not while drawing: changing the size re-enters layout.
            DispatchQueue.main.async { [weak self] in self?.updateContentSize() }
        }
        return result
    }

    /// The parts of this row that differ from its partner row (deleted <-> added), as UTF-16 ranges.
    private func changedRanges(_ index: Int, _ row: DiffRow, _ document: TextDocument) -> [Range<Int>] {
        guard document.kind == .diff, row.kind == .added || row.kind == .deleted else { return [] }
        if let cached = wordRanges[index] { return cached }
        if wordRanges.count > Self.wordRangesLimit { wordRanges.removeAll(keepingCapacity: true) }
        wordRanges[index] = []
        guard let other = document.rows.counterpart(ofRow: index) else { return [] }
        let otherRow = document.rows.row(at: other)
        let (oldRow, newRow) = row.kind == .deleted ? (row, otherRow) : (otherRow, row)
        guard let diff = WordDiff.changedRanges(old: text(forRow: oldRow, in: document), new: text(forRow: newRow, in: document)) else {
            wordRanges[other] = []
            return []
        }
        wordRanges[index] = row.kind == .deleted ? diff.old : diff.new
        wordRanges[other] = row.kind == .deleted ? diff.new : diff.old
        return wordRanges[index] ?? []
    }

    private func xOffset(_ line: LaidOutLine, _ offset: Int) -> CGFloat {
        CGFloat(CTLineGetOffsetForStringIndex(line.line, min(max(0, offset), line.length), nil))
    }

    // MARK: - Drawing

    override func draw(in ctx: CGContext, visible: CGRect) {
        guard let document else { return }
        let rows = document.rows
        guard rows.rowCount > 0 else { return }
        let selection = orderedSelection

        var index = rows.rowIndex(atY: Double(visible.minY - topPadding))
        while index < rows.rowCount {
            let y = topPadding + CGFloat(rows.y(ofRow: index))
            if y >= visible.maxY { break }
            drawRow(index, rows.row(at: index), y: y, height: CGFloat(rows.height(ofRow: index)), document, selection, in: ctx, visible: visible)
            index += 1
        }
    }

    private func drawRow(
        _ index: Int, _ row: DiffRow, y: CGFloat, height: CGFloat, _ document: TextDocument,
        _ selection: (start: TextPosition, end: TextPosition)?, in ctx: CGContext, visible: CGRect
    ) {
        // The gutter stays put while the code scrolls sideways under it.
        let gutterX = visible.minX
        let fullRow = CGRect(x: visible.minX, y: y, width: visible.width, height: height)

        if row.kind == .fold {
            ctx.fill(fullRow, Theme.band)
            let iconSize: CGFloat = 13
            Icon.unfold.draw(
                in: ctx, x: gutterX + Theme.gutterBarWidth + Theme.gutterNumberWidth - iconSize,
                y: y + ((height - iconSize) / 2).rounded(), size: iconSize, color: Ink.icon.cg, weight: 2)
            let label = row.count == 1 ? "1 unchanged line" : "\(row.count) unchanged lines"
            ctx.draw(label, .regular, .dim, x: gutterX + Theme.codeX, rowY: y, rowHeight: height)
            return
        }

        let tint: CGColor? = row.kind == .added ? Theme.addedRow : row.kind == .deleted ? Theme.deletedRow : nil
        if let tint { ctx.fill(fullRow, tint) }

        let line = laidOutLine(index, row, document)

        let ranges = changedRanges(index, row, document)
        if !ranges.isEmpty {
            ctx.setFillColor(row.kind == .added ? Theme.addedWord : Theme.deletedWord)
            for range in ranges {
                let x0 = xOffset(line, range.lowerBound)
                let x1 = xOffset(line, range.upperBound)
                let rect = CGRect(x: Theme.codeX + x0 - 1, y: y + 2, width: x1 - x0 + 2, height: height - 4)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            }
            ctx.fillPath()
        }

        if let selection, index >= selection.start.row, index <= selection.end.row {
            let x0 = index == selection.start.row ? xOffset(line, selection.start.offset) : 0
            // Rows fully inside the selection extend a little past their end to show the line break is included.
            let x1 = index == selection.end.row ? xOffset(line, selection.end.offset) : line.width + Theme.codeCharWidth
            if x1 > x0 {
                ctx.fill(CGRect(x: Theme.codeX + x0, y: y, width: x1 - x0, height: height), Theme.textSelection)
            }
        }

        ctx.draw(line.line, x: Theme.codeX, rowY: y, rowHeight: height, face: .code)

        if visible.minX > 0 {
            // Cover code that scrolled under the gutter.
            let cover = CGRect(x: gutterX, y: y, width: Theme.codeX - 6, height: height)
            ctx.fill(cover, Theme.background)
            if let tint { ctx.fill(cover, tint) }
        }

        let barInk: Ink? = switch row.kind {
        case .added: .green
        case .deleted: .red
        default: GutterView.barInk(row.mark)
        }
        if let barInk {
            ctx.fill(CGRect(x: gutterX, y: y, width: Theme.gutterBarWidth, height: height), barInk.cg)
        }
        if let digits = line.number {
            // Smaller and quieter than the code, but sitting on the code's baseline.
            let right = gutterX + Theme.gutterBarWidth + Theme.gutterNumberWidth
            ctx.draw(digits, x: right - digits.width, rowY: y, rowHeight: height, face: .code)
        }
    }

    // MARK: - Selection

    private var orderedSelection: (start: TextPosition, end: TextPosition)? {
        guard let anchor, let head, anchor != head else { return nil }
        return anchor < head ? (anchor, head) : (head, anchor)
    }

    /// `underPointer` is the offset of the character the pointer is over, while `position` is the nearest caret
    /// position (which is the next character when the pointer is on the right half of one).
    private func position(at point: CGPoint) -> (position: TextPosition, row: DiffRow, underPointer: Int)? {
        guard let document, document.rows.rowCount > 0 else { return nil }
        let index = document.rows.rowIndex(atY: Double(point.y - topPadding))
        let row = document.rows.row(at: index)
        guard row.kind != .fold else { return (TextPosition(row: index, offset: 0), row, 0) }
        let line = laidOutLine(index, row, document)
        let x = point.x - Theme.codeX
        let found = CTLineGetStringIndexForPosition(line.line, CGPoint(x: x, y: 0))
        let offset = found == kCFNotFound ? 0 : min(max(0, found), line.length)
        // The caret landed after the pointer: the pointer is on the right half of the character before it.
        let under = offset > 0 && x < CTLineGetOffsetForStringIndex(line.line, offset, nil) ? offset - 1 : offset
        return (TextPosition(row: index, offset: offset), row, under)
    }

    override func mouse(_ phase: MousePhase, at point: CGPoint, event: NSEvent) {
        guard let document else { return }
        switch phase {
        case .down:
            guard let hit = position(at: point) else { return }
            if hit.row.kind == .fold {
                onExpandFold?(hit.row.line)
                return
            }
            if event.clickCount == 2 {
                selectWord(at: TextPosition(row: hit.position.row, offset: hit.underPointer), hit.row, document)
            } else if event.clickCount >= 3 {
                let length = laidOutLine(hit.position.row, hit.row, document).length
                anchor = TextPosition(row: hit.position.row, offset: 0)
                head = TextPosition(row: hit.position.row, offset: length)
            } else if event.modifierFlags.contains(.shift), anchor != nil {
                head = hit.position
            } else {
                anchor = hit.position
                head = hit.position
            }
            setNeedsRedraw()
        case .dragged:
            guard anchor != nil, let hit = position(at: point) else { return }
            if head != hit.position {
                head = hit.position
                setNeedsRedraw()
            }
        case .up, .moved, .exited:
            break
        }
    }

    private func selectWord(at position: TextPosition, _ row: DiffRow, _ document: TextDocument) {
        let units = Array(text(forRow: row, in: document).utf16)
        func isWord(_ unit: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return true }
            return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
        }
        var start = min(position.offset, units.count)
        var end = start
        if start < units.count, isWord(units[start]) {
            while start > 0, isWord(units[start - 1]) { start -= 1 }
            while end < units.count, isWord(units[end]) { end += 1 }
        } else if start < units.count {
            end = start + 1
        }
        anchor = TextPosition(row: position.row, offset: start)
        head = TextPosition(row: position.row, offset: end)
    }

    /// The selected text as copy puts it on the pasteboard: rows joined by newlines, fold rows left out.
    var selectedText: String? {
        guard let document, let selection = orderedSelection else { return nil }
        var parts: [String] = []
        for index in selection.start.row...selection.end.row {
            let row = document.rows.row(at: index)
            guard row.kind != .fold else { continue }
            let text = text(forRow: row, in: document) as NSString
            let from = index == selection.start.row ? min(selection.start.offset, text.length) : 0
            let to = index == selection.end.row ? min(selection.end.offset, text.length) : text.length
            parts.append(text.substring(with: NSRange(location: from, length: max(0, to - from))))
        }
        return parts.joined(separator: "\n")
    }

    @objc func copy(_ sender: Any?) {
        guard let selectedText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard let document, document.rows.rowCount > 0 else { return }
        let last = document.rows.rowCount - 1
        let lastRow = document.rows.row(at: last)
        anchor = TextPosition(row: 0, offset: 0)
        head = TextPosition(row: last, offset: (text(forRow: lastRow, in: document) as NSString).length)
        setNeedsRedraw()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let page = max(Theme.lineHeight, visibleContentRect.height - Theme.lineHeight * 2)
        switch event.keyCode {
        case 125: scroll(by: CGPoint(x: 0, y: Theme.lineHeight)) // down
        case 126: scroll(by: CGPoint(x: 0, y: -Theme.lineHeight)) // up
        case 123: scroll(by: CGPoint(x: -Theme.codeCharWidth * 4, y: 0)) // left
        case 124: scroll(by: CGPoint(x: Theme.codeCharWidth * 4, y: 0)) // right
        case 121, 49: scroll(by: CGPoint(x: 0, y: page)) // page down, space
        case 116: scroll(by: CGPoint(x: 0, y: -page)) // page up
        case 115: scroll(to: CGPoint(x: 0, y: 0)) // home
        case 119: scroll(to: CGPoint(x: 0, y: contentSize.height)) // end
        default: super.keyDown(with: event)
        }
    }
}
