import AppKit
import MicroDiffCore

/// The text of one tab in edit mode: its own TextKit 1 stack (storage, layout manager, container), its own undo
/// history and the save state (`session`). It lives while its tab is in edit mode, has unsaved edits or has undo history (then until the tab closes).
///
/// The window's one editor view moves from buffer to buffer. Because every buffer keeps its own layout manager,
/// the undo steps of a buffer (which point at its layout manager) stay valid while another file or mode is shown.
final class EditBuffer: NSObject {
    let path: String
    var session: EditSession
    let storage: NSTextStorage
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(
        size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    let undoManager = UndoManager()
    /// What the Tab key inserts: found once from the file's first lines.
    let indentation: Indentation
    /// The change bars, while the tab is in edit mode.
    private(set) var marker: ChangeMarker?
    /// Called when the change bars changed (the editor redraws its gutter).
    var onMarksChanged: (() -> Void)?

    /// Caret and selection, and the scroll position; kept up to date by the editor view while it shows this buffer.
    var selectedRanges = [NSValue(range: NSRange(location: 0, length: 0))]
    var scrollSpot = ScrollSpot.top
    /// A known (character index, line) pair. Line numbers are counted from the nearest known spot, not from the top.
    private var lineMark = (index: 0, line: 0)

    /// The undo history is kept for the life of the tab: bounded, so a tab edited for days does not grow without end.
    static let undoLevels = 1000

    /// Code font and color, 22 pt lines and 4-column tabs: the same metrics as the read view.
    static let attributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = Theme.codeCharWidth * 4
        paragraph.minimumLineHeight = Theme.lineHeight
        paragraph.maximumLineHeight = Theme.lineHeight
        return [
            .font: Face.code.font as NSFont,
            .foregroundColor: NSColor(cgColor: Ink.code.cg) ?? .textColor,
            .paragraphStyle: paragraph,
        ]
    }()

    /// Where the baseline sits in a 22 pt line: exactly where the read view draws it (centered, on a half point).
    static let baselineOffset: CGFloat = {
        let font = Face.code.font
        let ascent = CTFontGetAscent(font)
        let centered = (Theme.lineHeight - (ascent + CTFontGetDescent(font))) / 2 + ascent
        return (centered * 2).rounded() / 2
    }()

    init(path: String, loaded: EditableText) {
        self.path = path
        session = EditSession(loaded: loaded)
        indentation = Indentation.detect(loaded.text)
        storage = NSTextStorage(string: loaded.text, attributes: Self.attributes)
        super.init()
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.delegate = self
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        storage.delegate = self
        undoManager.levelsOfUndo = Self.undoLevels
    }

    var isUnsaved: Bool { session.isDirty }

    /// The user changed the text and the steps can be undone or redone.
    var hasUndoHistory: Bool { undoManager.canUndo || undoManager.canRedo || undoManager.groupingLevel > 0 }

    /// Tells the session the text changed. The whole text is only looked at when its length is back to the saved one.
    func noteTextChange() {
        session.textDidChange(length: storage.length) { storage.string }
    }

    /// Puts another text in (a reload from disk), keeping the caret and selection where the new text allows.
    /// Undo steps of the old text do not fit the new one, so they are dropped.
    func replaceText(_ text: String) {
        let textView = container.textView
        let ranges = textView?.selectedRanges ?? selectedRanges
        storage.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
        undoManager.removeAllActions()
        selectedRanges = Self.clamp(ranges, to: storage.length)
        textView?.selectedRanges = selectedRanges
        marker?.textDidChange()
    }

    /// Whether the editor shows this buffer. Off screen it gives back its glyphs and line layout: for a file laid out
    /// to its end they are several times the text itself, and undo only needs the text. They are made again, for the
    /// part on screen first, when the buffer is shown.
    var isShown = true {
        didSet {
            guard isShown != oldValue else { return }
            layoutManager.backgroundLayoutEnabled = isShown
            guard !isShown else { return }
            let all = NSRange(location: 0, length: storage.length)
            layoutManager.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        }
    }

    func setMarker(_ marker: ChangeMarker) {
        self.marker?.stop()
        self.marker = marker
    }

    func dropMarker() {
        marker?.stop()
        marker = nil
    }

    /// The tab closed or stopped needing the buffer.
    func close() {
        dropMarker()
        undoManager.removeAllActions()
    }

    static func clamp(_ ranges: [NSValue], to length: Int) -> [NSValue] {
        let clamped = ranges.map { value -> NSValue in
            let range = value.rangeValue
            let location = min(max(0, range.location), length)
            return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
        }
        return clamped.isEmpty ? [NSValue(range: NSRange(location: length, length: 0))] : clamped
    }

    // MARK: - Line numbers

    /// 0-based line of the character at `index`. Counts line breaks from the last answer, so the gutter asking about
    /// the lines on screen costs only what lies between them.
    func line(at index: Int) -> Int {
        let target = min(max(0, index), storage.length)
        let mark = lineMark
        let line = target >= mark.index
            ? mark.line + newlines(from: mark.index, to: target)
            : mark.line - newlines(from: target, to: mark.index)
        lineMark = (target, line)
        return line
    }

    /// Where line `line` (0-based) starts; the end of the text when there are fewer lines.
    func characterIndex(ofLine line: Int) -> Int {
        guard line > 0 else { return 0 }
        let string = storage.mutableString
        let length = storage.length
        // Count on from the known spot when it is above the line, else from the top.
        var (index, current) = lineMark.line < line ? lineMark : (0, 0)
        withUnsafeTemporaryAllocation(of: unichar.self, capacity: 4096) { buffer in
            guard let base = buffer.baseAddress else { return }
            while index < length, current < line {
                let count = min(buffer.count, length - index)
                string.getCharacters(base, range: NSRange(location: index, length: count))
                var i = 0
                while i < count, current < line {
                    if base[i] == 0x0A { current += 1 }
                    i += 1
                }
                index += i
            }
        }
        if current == line { lineMark = (index, line) }
        return current == line ? index : length
    }

    private func newlines(from start: Int, to end: Int) -> Int {
        guard end > start else { return 0 }
        let string = storage.mutableString
        var count = 0
        withUnsafeTemporaryAllocation(of: unichar.self, capacity: 4096) { buffer in
            guard let base = buffer.baseAddress else { return }
            var location = start
            while location < end {
                let length = min(buffer.count, end - location)
                string.getCharacters(base, range: NSRange(location: location, length: length))
                for i in 0..<length where base[i] == 0x0A { count += 1 }
                location += length
            }
        }
        return count
    }
}

/// A scroll position as a line: `offset` points of line `line` are above the top edge (negative in the top padding).
struct ScrollSpot: Equatable {
    var line = 0
    var offset: CGFloat = 0
    var x: CGFloat = 0

    /// The read view puts line n at y = 8 + 22 n, like the editor: the same spot there.
    init(readViewOffset point: CGPoint) {
        let row = max(0, ((point.y - 8) / Theme.lineHeight).rounded(.down))
        self.init(line: Int(row), offset: point.y - 8 - row * Theme.lineHeight, x: point.x)
    }

    init(line: Int = 0, offset: CGFloat = 0, x: CGFloat = 0) {
        self.line = line
        self.offset = offset
        self.x = x
    }

    var readViewOffset: CGPoint { CGPoint(x: x, y: 8 + CGFloat(line) * Theme.lineHeight + offset) }

    /// Scrolled all the way up: the 8 pt padding above the first line is showing.
    static let top = ScrollSpot(readViewOffset: .zero)
}

extension EditBuffer: @preconcurrency NSTextStorageDelegate {
    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // Text before the mark changed: the line count up to it may be different now.
        if editedMask.contains(.editedCharacters), editedRange.location < lineMark.index { lineMark = (0, 0) }
    }
}

extension EditBuffer: @preconcurrency NSLayoutManagerDelegate {
    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange
    ) -> Bool {
        lineFragmentRect.pointee.size.height = Theme.lineHeight
        lineFragmentUsedRect.pointee.size.height = Theme.lineHeight
        baselineOffset.pointee = Self.baselineOffset
        return true
    }
}
