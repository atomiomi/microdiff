import AppKit
import MicroDiffCore

/// Apple's text view, forced to TextKit 1 (it is always built on a buffer's own layout manager).
/// It holds the buffer it shows: the text view does not retain its text container, so the buffer that owns the
/// container must outlive the view, also while the window is torn down.
final class EditorTextView: NSTextView {
    fileprivate(set) var buffer: EditBuffer?

    /// Enter: the new line starts with the blanks the caret's line starts with (only those before the caret).
    override func insertNewline(_ sender: Any?) {
        guard let string = textStorage?.mutableString else { return super.insertNewline(sender) }
        let caret = selectedRange().location
        let start = string.lineRange(for: NSRange(location: caret, length: 0)).location
        var end = start
        while end < caret, string.character(at: end) == 0x20 || string.character(at: end) == 0x09 { end += 1 }
        insertText("\n" + string.substring(with: NSRange(location: start, length: end - start)), replacementRange: selectedRange())
    }

    /// Tab: a tab in a file indented with tabs; in one indented with spaces, spaces up to the next indent level.
    override func insertTab(_ sender: Any?) {
        guard case let .spaces(unit)? = buffer?.indentation, let string = textStorage?.mutableString else {
            return super.insertTab(sender)
        }
        let caret = selectedRange().location
        var column = 0
        for index in string.lineRange(for: NSRange(location: caret, length: 0)).location..<caret {
            // Tabs already in the line stop at every 4 columns, as they are drawn.
            column = string.character(at: index) == 0x09 ? (column / 4 + 1) * 4 : column + 1
        }
        insertText(String(repeating: " ", count: unit - column % unit), replacementRange: selectedRange())
    }
}

/// The plain-text editor of a window: the open tab's `EditBuffer` in a text view, a line-number gutter beside it and,
/// when the file changed on disk under unsaved edits, a strip on top. Made the first time a tab of the window enters
/// edit mode and kept with the window after that (empty while no tab is in edit mode).
final class EditorView: NSView {
    let scrollView = NSScrollView()
    let textView: EditorTextView
    let gutter = GutterView()
    private let strip = DiskChangeStrip()
    /// Set while a buffer is being put in, so the text view's own notifications do not overwrite its saved state.
    private var isSwapping = false

    /// The user changed the text (typing, paste, undo).
    var onTextChange: ((EditBuffer) -> Void)?
    var onReload: (() -> Void)? {
        get { strip.onReload }
        set { strip.onReload = newValue }
    }
    var onKeepMine: (() -> Void)? {
        get { strip.onKeepMine }
        set { strip.onKeepMine = newValue }
    }

    var buffer: EditBuffer? { textView.buffer }

    /// What the strip on top says; nil hides it.
    var conflict: DiskConflict? {
        didSet {
            guard conflict != oldValue else { return }
            strip.isHidden = conflict == nil
            if let conflict { strip.conflict = conflict }
            needsLayout = true
        }
    }

    init(buffer: EditBuffer) {
        textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: buffer.container)
        super.init(frame: .zero)
        textView.buffer = buffer
        configureTextView()
        buffer.onMarksChanged = { [weak self] in self?.gutter.invalidate() }

        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(cgColor: Theme.background) ?? .black
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = textView
        strip.isHidden = true
        gutter.editor = self
        for view in [scrollView, gutter, strip] as [NSView] { addSubview(view) }

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipChanged), name: NSView.boundsDidChangeNotification, object: clip)
        // Text can change without typing (a reload from disk): the line numbers must follow.
        NotificationCenter.default.addObserver(
            self, selector: #selector(storageEdited), name: NSTextStorage.didProcessEditingNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var isFlipped: Bool { true }

    /// Shows another buffer, with its caret, selection, scroll position and undo history.
    func show(_ buffer: EditBuffer) {
        guard buffer !== textView.buffer else { return }
        isSwapping = true
        // A typing run must not go on into another buffer's undo history.
        textView.breakUndoCoalescing()
        textView.buffer?.container.textView = nil
        textView.buffer?.onMarksChanged = nil
        textView.buffer?.isShown = false
        buffer.isShown = true
        buffer.container.textView = textView
        textView.buffer = buffer
        buffer.onMarksChanged = { [weak self] in self?.gutter.invalidate() }
        // Most text view settings live with the layout manager: set them again for this one.
        configureTextView()
        isSwapping = false
        restoreState()
    }

    /// Puts the caret, selection and scroll position of the shown buffer back (after a swap, or once laid out).
    func restoreState() {
        guard let buffer = textView.buffer else { return }
        isSwapping = true
        defer { isSwapping = false }
        textView.selectedRanges = EditBuffer.clamp(buffer.selectedRanges, to: buffer.storage.length)
        layoutSubtreeIfNeeded()
        scroll(to: buffer.scrollSpot)
        gutter.invalidate()
    }

    /// The line at the top edge and how far it is scrolled past.
    ///
    /// Scroll positions are kept as lines, not points: with non-contiguous layout TextKit only estimates where text it
    /// has not laid out yet will sit, so a point can mean other text later. A line always means the same text.
    func scrollSpot() -> ScrollSpot {
        let clip = scrollView.contentView.bounds
        let y = clip.minY - textView.textContainerOrigin.y
        guard let buffer, y > 0 else { return ScrollSpot(line: 0, offset: y, x: clip.minX) }
        let layoutManager = buffer.layoutManager
        let glyphs = layoutManager.glyphRange(
            forBoundingRect: CGRect(x: 0, y: y, width: CGFloat.greatestFiniteMagnitude, height: 1), in: buffer.container)
        guard glyphs.length > 0 else { return buffer.scrollSpot }
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let start = layoutManager.characterIndexForGlyph(at: glyphs.location)
        return ScrollSpot(line: buffer.line(at: start), offset: y - rect.minY, x: clip.minX)
    }

    /// Scrolls so that the spot's line is at the top edge (lays out only that part of the text).
    func scroll(to spot: ScrollSpot) {
        guard let buffer else { return }
        let layoutManager = buffer.layoutManager
        let start = buffer.characterIndex(ofLine: spot.line)
        var lineTop: CGFloat = 0
        if start < buffer.storage.length {
            lineTop = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil).minY
        } else if buffer.storage.length > 0 {
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: buffer.storage.length - 1, length: 1))
            lineTop = layoutManager.extraLineFragmentRect.minY
        }
        let height = scrollView.contentView.bounds.height
        layoutManager.ensureLayout(
            forBoundingRect: CGRect(x: 0, y: lineTop, width: CGFloat.greatestFiniteMagnitude, height: height + Theme.lineHeight * 2),
            in: buffer.container)
        textView.sizeToFit()
        scrollView.contentView.scroll(to: CGPoint(x: max(0, spot.x), y: max(0, lineTop + textView.textContainerOrigin.y + spot.offset)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Lets go of the buffer: no tab needs the editor right now.
    func detach() {
        textView.breakUndoCoalescing()
        textView.buffer?.onMarksChanged = nil
        textView.buffer?.container.textView = nil
        textView.buffer?.isShown = false
        textView.buffer = nil
    }

    private func configureTextView() {
        let view = textView
        view.delegate = self
        view.isEditable = true
        view.isSelectable = true
        view.allowsUndo = true
        view.isRichText = false
        view.importsGraphics = false
        view.usesFontPanel = false
        view.usesRuler = false
        view.isRulerVisible = false
        view.usesInspectorBar = false
        view.smartInsertDeleteEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.inlinePredictionType = .no
        if #available(macOS 15.0, *) { view.writingToolsBehavior = .none }
        view.displaysLinkToolTips = false
        view.drawsBackground = true
        view.backgroundColor = NSColor(cgColor: Theme.background) ?? .black
        view.insertionPointColor = NSColor(cgColor: Ink.fg.cg) ?? .white
        view.selectedTextAttributes = [.backgroundColor: NSColor(cgColor: Theme.textSelection) ?? .selectedTextBackgroundColor]
        view.typingAttributes = EditBuffer.attributes
        // Code starts at the same x as in the read view, 8 pt below the top, like the read view's first row.
        view.textContainerInset = NSSize(width: Theme.codeX, height: 8)
        // No wrapping: long lines scroll sideways.
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width, .height]
    }

    override func layout() {
        super.layout()
        let top = strip.isHidden ? 0 : Theme.foldHeight
        strip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Theme.foldHeight)
        scrollView.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        gutter.frame = CGRect(x: 0, y: top, width: Theme.codeX - 6, height: scrollView.frame.height)
        textView.minSize = scrollView.contentSize
    }

    @objc private func storageEdited(_ notification: Notification) {
        if let storage = textView.buffer?.storage, notification.object as AnyObject? === storage { gutter.invalidate() }
    }

    @objc private func clipChanged() {
        if !isSwapping, let buffer = textView.buffer { buffer.scrollSpot = scrollSpot() }
        gutter.invalidate()
    }

    /// The line numbers on screen, for tests: (line index, y of its row in this view, is the caret's line).
    func visibleLineNumbers() -> [(line: Int, y: CGFloat, isCaretLine: Bool)] {
        gutter.visibleLines()
    }
}

extension EditorView: NSTextViewDelegate {
    func undoManager(for view: NSTextView) -> UndoManager? {
        textView.buffer?.undoManager
    }

    func textDidChange(_ notification: Notification) {
        guard let buffer = textView.buffer else { return }
        onTextChange?(buffer)
        gutter.invalidate()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if !isSwapping, let buffer = textView.buffer { buffer.selectedRanges = textView.selectedRanges }
        gutter.invalidate()
    }
}

/// The line numbers left of the text: only the lines on screen, at the rows the read view puts them.
final class GutterView: NSView {
    weak var editor: EditorView?
    /// How often a redraw was asked for (tests check it: an offscreen window never draws, so `needsDisplay` stays set).
    private(set) var invalidations = 0

    func invalidate() {
        invalidations += 1
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    func visibleLines() -> [(line: Int, y: CGFloat, isCaretLine: Bool)] {
        guard let editor, let buffer = editor.buffer else { return [] }
        let textView = editor.textView
        let layoutManager = buffer.layoutManager
        let origin = textView.textContainerOrigin
        let clip = editor.scrollView.contentView.bounds
        let visible = clip.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: buffer.container)
        let caret = textView.selectedRanges.count == 1 ? textView.selectedRange() : nil
        let caretIndex = caret.flatMap { $0.length == 0 ? $0.location : nil }

        var lines: [(Int, CGFloat, Bool)] = []
        var first: (index: Int, line: Int)?
        var lastEnd = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
            let chars = layoutManager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            // No wrapping: every line fragment is one line of the text.
            let line: Int
            if let first {
                line = first.line + lines.count
            } else {
                line = buffer.line(at: chars.location)
                first = (chars.location, line)
            }
            let isCaret = caretIndex.map { $0 >= chars.location && $0 < NSMaxRange(chars) } ?? false
            lines.append((line, rect.minY + origin.y - clip.minY, isCaret))
            lastEnd = NSMaxRange(chars)
        }
        // The glyph range can reach a little past the edges.
        lines.removeAll { $0.1 + Theme.lineHeight <= 0 || $0.1 >= clip.height }
        // The empty line after a final line break (or of an empty file).
        let extra = layoutManager.extraLineFragmentRect
        if layoutManager.extraLineFragmentTextContainer === buffer.container, extra.maxY + origin.y > clip.minY, extra.minY + origin.y < clip.maxY {
            let line = first.map { $0.line + lines.count } ?? buffer.line(at: buffer.storage.length)
            lines.append((line, extra.minY + origin.y - clip.minY, caretIndex == buffer.storage.length))
        } else if let last = lines.indices.last, caretIndex == buffer.storage.length, lastEnd == buffer.storage.length {
            lines[last].2 = true
        }
        return lines
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.fill(bounds, Theme.background)
        let right = Theme.gutterBarWidth + Theme.gutterNumberWidth
        let marks = editor?.buffer?.marker?.rows
        for (line, y, isCaretLine) in visibleLines() {
            // The change bar, like the read view's: green for an added line, yellow for a modified one.
            if let marks, line < marks.rowCount, let ink = Self.barInk(marks.row(at: line).mark) {
                ctx.fill(CGRect(x: 0, y: y, width: Theme.gutterBarWidth, height: Theme.lineHeight), ink.cg)
            }
            let digits = TextCache.makeLine([TextRun(String(line + 1), isCaretLine ? .mid : .lineNumber)], .regular)
            // Sitting on the code's baseline, like in the read view.
            ctx.draw(digits, x: right - digits.width, rowY: y, rowHeight: Theme.lineHeight, face: .code)
        }
    }

    static func barInk(_ mark: LineMark) -> Ink? {
        switch mark {
        case .added: .green
        case .modified: .yellow
        case .none: nil
        }
    }
}

/// "this file changed on disk   reload  keep mine": shown on top of the editor when the file changed (or was
/// deleted) on disk while the tab has unsaved edits.
final class DiskChangeStrip: NSView {
    var conflict: DiskConflict = .changed {
        didSet {
            guard conflict != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    var onReload: (() -> Void)?
    var onKeepMine: (() -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static let gap = Theme.charWidth * 2
    private static let padding: CGFloat = 16

    var message: String {
        conflict == .deleted ? "this file was deleted on disk" : "this file changed on disk"
    }

    var keepMineRect: CGRect {
        let width = TextCache.shared.line("keep mine", .regular, .fg).width
        return CGRect(x: bounds.width - Self.padding - width, y: 0, width: width, height: bounds.height)
    }

    /// Only for a changed file: a deleted one has nothing to reload.
    var reloadRect: CGRect? {
        guard conflict == .changed else { return nil }
        let width = TextCache.shared.line("reload", .regular, .fg).width
        return CGRect(x: keepMineRect.minX - Self.gap - width, y: 0, width: width, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.fill(bounds, Theme.background)
        ctx.fill(bounds, Theme.band)
        ctx.fill(CGRect(x: 0, y: 0, width: Theme.gutterBarWidth, height: bounds.height), Ink.yellow.cg)
        ctx.draw(message, .regular, .dim, x: Theme.codeX, rowY: 0, rowHeight: bounds.height)
        if let reloadRect { ctx.draw("reload", .regular, .fg, x: reloadRect.minX, rowY: 0, rowHeight: bounds.height) }
        ctx.draw("keep mine", .regular, .fg, x: keepMineRect.minX, rowY: 0, rowHeight: bounds.height)
    }

    private func hitRects() -> [(CGRect, () -> Void)] {
        var rects: [(CGRect, () -> Void)] = [(keepMineRect.insetBy(dx: -7, dy: 0), { [weak self] in self?.onKeepMine?() })]
        if let reloadRect { rects.append((reloadRect.insetBy(dx: -7, dy: 0), { [weak self] in self?.onReload?() })) }
        return rects
    }

    func cursor(at point: CGPoint) -> NSCursor {
        hitRects().contains { $0.0.contains(point) } ? .pointingHand : .arrow
    }

    override func resetCursorRects() {
        for (rect, _) in hitRects() { addCursorRect(rect, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hitRects().first { $0.0.contains(point) }?.1()
    }
}
