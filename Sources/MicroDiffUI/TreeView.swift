import AppKit
import MicroDiffCore

/// How one tree row looks, decided without drawing anything: name color, icon, marker on the right, strikethrough.
struct TreeRowStyle: Equatable {
    enum Marker: Equatable {
        case none
        /// A dot for a folder with changes inside (files tab).
        case dot(Ink)
        /// A status letter on the right.
        case letter(String, Ink)
    }

    var nameInk: Ink
    var icon: FileIcon
    var iconAlpha: CGFloat
    var marker: Marker
    var strikethrough: Bool

    static let ignoredIconAlpha: CGFloat = 0.5

    /// The marker on the right of a row. Split out so the content width can ask for it without building a whole style.
    static func marker(of row: TreeRow, tab: TreeView.Style) -> Marker {
        switch row.kind {
        case .repo:
            return .none
        case .directory:
            guard tab == .files, let mark = row.dirMark else { return .none }
            return row.isSubmodule || row.isNestedRepo ? .letter(mark.letter, Ink.change(mark)) : .dot(Ink.change(mark))
        case .file:
            guard let kind = row.change?.kind else { return .none }
            return .letter(kind.letter, Ink.change(kind))
        }
    }

    /// `isSelected` only matters for file rows.
    init(row: TreeRow, tab: TreeView.Style, isSelected: Bool) {
        iconAlpha = row.isIgnored ? Self.ignoredIconAlpha : 1
        marker = Self.marker(of: row, tab: tab)
        strikethrough = false
        switch row.kind {
        case .repo:
            icon = row.isSubmodule ? .submodule : .repo
            nameInk = .fg
        case .directory:
            icon = row.isSubmodule ? .submodule : row.isNestedRepo ? .repo : (row.isExpanded ? .folderOpen : .folder)
            if tab == .files, let mark = row.dirMark {
                nameInk = Ink.change(mark)
            } else {
                nameInk = tab == .files && row.isIgnored ? .ignored : .mid
            }
        case .file:
            icon = FileIcon.forFile(named: row.name)
            if let kind = row.change?.kind {
                switch tab {
                case .files:
                    nameInk = Ink.change(kind)
                case .changes:
                    strikethrough = kind == .deleted
                    nameInk = isSelected ? .fg : (kind == .deleted ? .dim : .mid)
                }
            } else if isSelected {
                nameInk = .fg
            } else {
                nameInk = tab == .files && row.isIgnored ? .ignored : .mid
            }
        }
    }
}

/// The sidebar list: repository headers, folders and files, drawn row by row.
final class TreeView: CanvasScrollView {
    enum Style {
        /// "changes" tab: repo rows are section bands.
        case changes
        /// "files" tab: the root is a plain row.
        case files
    }

    var style: Style = .changes {
        didSet {
            guard style != oldValue else { return }
            measureContent()
            updateContentSize()
        }
    }

    /// Called when a repo or folder row is clicked.
    var onToggle: ((TreeRow) -> Void)?
    /// Called when a file row is activated. `pin` is true for a double click or Return.
    var onOpen: ((TreeRow, _ pin: Bool) -> Void)?

    /// Shown in the empty space below the rows ("no changes").
    var emptyMessage: String? {
        didSet { if emptyMessage != oldValue { setNeedsRedraw() } }
    }

    var selectedID: String? {
        didSet { if selectedID != oldValue { setNeedsRedraw() } }
    }

    private(set) var rows: [TreeRow] = []
    /// Top edge of every row, plus the bottom of the last one.
    private var tops: [CGFloat] = [0]
    private var hoverIndex: Int?
    /// What repository rows with a branch show for a name, branch and width (see `repoText`). Dropped with the rows.
    private var repoTexts: [RepoTextKey: RepoRowText.Fit] = [:]

    private static let topPadding: CGFloat = 8
    private static let bottomPadding: CGFloat = 8

    // Sideways scrolling. File and folder rows scroll; the marker on the right stays at the visible edge.
    /// Free space kept between the end of a name and its marker.
    private static let markerGap: CGFloat = 14
    /// The pinned marker's background starts this far left of the marker, and fades in over `fadeWidth` further left.
    private static let patchLead: CGFloat = 2
    private static let fadeWidth: CGFloat = 12
    private static let smallCharWidth: CGFloat = TextCache.shared.line("0", .small, .dim).width
    /// The 7x7 box of a folder dot.
    private static let dotBoxWidth: CGFloat = 7

    /// Width needed by the widest file or folder row (repository rows do not count); 0 without rows.
    private(set) var contentWidth: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.hasHorizontalScroller = true
        locksScrollAxis = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func setRows(_ newRows: [TreeRow]) {
        rows = newRows
        repoTexts.removeAll(keepingCapacity: true)
        tops.removeAll(keepingCapacity: true)
        tops.reserveCapacity(newRows.count + 1)
        var y = Self.topPadding
        for row in newRows {
            if row.gapBefore { y += Theme.repoGap }
            tops.append(y)
            y += height(of: row)
        }
        tops.append(y)
        measureContent()
        updateContentSize()
        // The rows changed under a pointer that may not have moved.
        hoverIndex = pointerLocation().flatMap { rowIndex(atY: $0.y) }
        refreshPointer()
        setNeedsRedraw()
    }

    override func visibleRectChanged() {
        setHover(pointerLocation().flatMap { rowIndex(atY: $0.y) })
    }

    /// Every row reacts to a click: files open, folders and repo rows fold.
    override func cursor(at point: CGPoint) -> NSCursor {
        rowIndex(atY: point.y) == nil ? .arrow : .pointingHand
    }

    override func layout() {
        super.layout()
        updateContentSize()
    }

    private func updateContentSize() {
        let width = max(bounds.width, contentWidth)
        contentSize = CGSize(width: width, height: (tops.last ?? 0) + Self.bottomPadding)
        // Narrower content (or a wider sidebar) moves the position back into range; it is 0 when everything fits.
        let maxX = max(0, width - bounds.width)
        if visibleContentRect.origin.x > maxX { scroll(to: CGPoint(x: maxX, y: visibleContentRect.origin.y)) }
    }

    /// Computes `contentWidth` once for the current rows. Names are monospaced, so ASCII names are
    /// counted, not laid out; only names with other characters are measured.
    private func measureContent() {
        let tab = style
        let base = Theme.treePadding + Theme.iconSize + 6
        var widest: CGFloat = 0
        rows.withUnsafeBufferPointer { buffer in
            for index in buffer.indices {
                let kind = buffer[index].kind
                if kind == .repo { continue }
                var needed = base + CGFloat(buffer[index].depth) * Theme.treeIndent + Self.nameWidth(of: buffer[index])
                let marker = Self.markerWidth(of: buffer[index], tab: tab)
                if marker > 0 { needed += Self.markerGap + marker }
                if needed > widest { widest = needed }
            }
        }
        contentWidth = widest > 0 ? widest + Theme.treePadding : 0
    }

    /// Width of the room a row's right marker takes (0 without one).
    static func markerWidth(of row: TreeRow, tab: Style) -> CGFloat {
        switch TreeRowStyle.marker(of: row, tab: tab) {
        case .none: 0
        case .dot: dotBoxWidth
        case let .letter(text, _): CGFloat(text.count) * smallCharWidth
        }
    }

    private static func nameWidth(of row: TreeRow) -> CGFloat {
        if row.kind == .file, row.change?.kind == .renamed {
            return measured(displayedName(of: row))
        }
        // Monospaced: an ASCII name is its length times one character.
        let ascii = row.name.utf8.withContiguousStorageIfAvailable { bytes in
            for byte in bytes where byte >= 0x80 { return CGFloat(-1) }
            return CGFloat(bytes.count)
        }
        if let ascii, ascii >= 0 { return ascii * Theme.charWidth }
        return measured(row.name)
    }

    private static func measured(_ text: String) -> CGFloat {
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return CGFloat(text.utf8.count) * Theme.charWidth }
        return TextCache.makeLine([TextRun(text, .fg)], .regular).width
    }

    /// The text drawn for a file or folder row.
    private static func displayedName(of row: TreeRow) -> String {
        if row.kind == .file, row.change?.kind == .renamed, let old = row.change?.oldPath {
            return ((old as NSString).lastPathComponent) + " → " + row.name
        }
        return row.name
    }

    private func height(of row: TreeRow) -> CGFloat {
        // The root row has the same height in both tabs (band or not), so the rows below stay put when switching.
        row.kind == .repo ? Theme.repoBandHeight : Theme.treeRowHeight
    }

    /// Index of the row at a vertical position, or nil between rows / outside.
    private func rowIndex(atY y: CGFloat) -> Int? {
        guard !rows.isEmpty, y >= tops[0], y < tops[rows.count] else { return nil }
        var low = 0
        var high = rows.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if tops[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return y < tops[low] + height(of: rows[low]) ? low : nil
    }

    func scrollRowToVisible(id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let visible = visibleContentRect
        let top = tops[index]
        let bottom = top + height(of: rows[index])
        if top < visible.minY {
            scroll(to: CGPoint(x: visible.minX, y: top - Self.topPadding))
        } else if bottom > visible.maxY {
            scroll(to: CGPoint(x: visible.minX, y: bottom - visible.height + Self.bottomPadding))
        }
    }

    // MARK: - Drawing

    override func draw(in ctx: CGContext, visible: CGRect) {
        if !rows.isEmpty {
            // First row whose bottom is below the top of the visible area.
            var first = 0
            var high = rows.count - 1
            while first < high {
                let mid = (first + high) / 2
                if tops[mid + 1] <= visible.minY { first = mid + 1 } else { high = mid }
            }
            var index = first
            while index < rows.count, tops[index] < visible.maxY {
                drawRow(index, in: ctx, visible: visible)
                index += 1
            }
        }

        if let emptyMessage {
            let top = tops.last ?? 0
            let areaHeight = max(Theme.lineHeight, visible.height - top)
            let line = TextCache.shared.line(emptyMessage, .regular, .dim)
            ctx.draw(line, x: visible.minX + ((visible.width - line.width) / 2).rounded(), rowY: top, rowHeight: areaHeight, face: .regular)
        }
    }

    private func drawRow(_ index: Int, in ctx: CGContext, visible: CGRect) {
        let row = rows[index]
        let y = tops[index]
        let h = height(of: row)
        let isSelected = row.kind == .file && row.id == selectedID
        let isHover = !isSelected && hoverIndex == index
        // Fills always cover what is on screen. Repository rows do not scroll: everything on them is
        // laid out from the visible left edge.
        let isRepo = row.kind == .repo
        let originX = isRepo ? visible.minX : 0
        let edge = visible.maxX - Theme.treePadding

        if isRepo, style == .changes {
            ctx.fill(CGRect(x: visible.minX, y: y, width: visible.width, height: h), Theme.band)
        }
        if isSelected {
            ctx.fill(CGRect(x: visible.minX, y: y, width: visible.width, height: h), Theme.rowSelected)
        } else if isHover {
            ctx.fill(CGRect(x: visible.minX, y: y, width: visible.width, height: h), Theme.rowHover)
        }

        // Indent guides: one thin line per ancestor level, under that ancestor's icon.
        for level in 0..<row.depth {
            let x = Theme.treePadding + CGFloat(level) * Theme.treeIndent + 7
            ctx.fill(CGRect(x: x, y: y, width: 1, height: h), Theme.guide)
        }

        let style = TreeRowStyle(row: row, tab: self.style, isSelected: isSelected)
        let iconX = originX + Theme.treePadding + CGFloat(row.depth) * Theme.treeIndent
        let iconY = y + ((h - Theme.iconSize) / 2).rounded()
        let textX = iconX + Theme.iconSize + 6

        style.icon.draw(in: ctx, x: iconX, y: iconY, alpha: style.iconAlpha)

        if isRepo {
            drawRepoName(row, style: style, in: ctx, textX: textX, right: edge, rowY: y, rowHeight: h)
            return
        }

        // Names are drawn in full; the marker sits on top at the visible right edge.
        let line = nameLine(for: row, ink: style.nameInk)
        ctx.draw(line, x: textX, rowY: y, rowHeight: h, face: .regular)
        if style.strikethrough {
            let strikeY = y + (h / 2).rounded() + 0.5
            ctx.fill(CGRect(x: textX, y: strikeY, width: line.width, height: 1), style.nameInk.cg)
        }

        let markerLeft: CGFloat
        switch style.marker {
        case .none:
            return
        case let .dot(ink):
            markerLeft = edge - Self.dotBoxWidth
            // A 5x5 dot centered in a 7x7 box that ends 14 pt from the right edge.
            let dot = CGRect(x: edge - 6, y: y + (h - 5) / 2, width: 5, height: 5)
            drawMarkerBackground(ctx, nameEnd: textX + line.width, markerLeft: markerLeft, visible: visible, y: y, h: h, isSelected: isSelected, isHover: isHover)
            ctx.setFillColor(ink.cg.copy(alpha: 0.85) ?? ink.cg)
            ctx.fillEllipse(in: dot)
        case let .letter(letter, ink):
            let marker = TextCache.shared.line(letter, .small, ink)
            markerLeft = edge - marker.width
            drawMarkerBackground(ctx, nameEnd: textX + line.width, markerLeft: markerLeft, visible: visible, y: y, h: h, isSelected: isSelected, isHover: isHover)
            ctx.drawRightAligned(letter, .small, ink, right: edge, rowY: y, rowHeight: h)
        }
    }

    /// Hides what scrolled under the marker: a patch in the row's own background with a short fade on its left.
    /// Only drawn when the name actually reaches that far, so rows that fit look exactly as before.
    private func drawMarkerBackground(
        _ ctx: CGContext, nameEnd: CGFloat, markerLeft: CGFloat, visible: CGRect, y: CGFloat, h: CGFloat,
        isSelected: Bool, isHover: Bool
    ) {
        guard nameEnd > markerLeft - Self.markerGap else { return }
        let background = Self.rowBackground(selected: isSelected, hover: isHover)
        let patchLeft = markerLeft - Self.patchLead
        ctx.fill(CGRect(x: patchLeft, y: y, width: visible.maxX - patchLeft, height: h), background.solid)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: patchLeft - Self.fadeWidth, y: y, width: Self.fadeWidth, height: h))
        ctx.drawLinearGradient(
            background.fade, start: CGPoint(x: patchLeft - Self.fadeWidth, y: 0), end: CGPoint(x: patchLeft, y: 0), options: [])
        ctx.restoreGState()
    }

    private struct RowBackground {
        var solid: CGColor
        var fade: CGGradient
    }

    /// The sidebar color with the selection or hover fill already on it, plus a transparent-to-solid gradient of it.
    private static let rowBackgrounds: [RowBackground] = [Theme.background, blend(Theme.rowSelected, over: Theme.background),
                                                          blend(Theme.rowHover, over: Theme.background)].map { solid in
        let clear = solid.copy(alpha: 0) ?? solid
        let gradient = CGGradient(colorsSpace: solid.colorSpace, colors: [clear, solid] as CFArray, locations: nil)!
        return RowBackground(solid: solid, fade: gradient)
    }

    private static func rowBackground(selected: Bool, hover: Bool) -> RowBackground {
        rowBackgrounds[selected ? 1 : (hover ? 2 : 0)]
    }

    private static func blend(_ top: CGColor, over base: CGColor) -> CGColor {
        let t = top.components ?? [0, 0, 0, 1]
        let b = base.components ?? [0, 0, 0, 1]
        let alpha = top.alpha
        func mix(_ i: Int) -> CGFloat { b[i] * (1 - alpha) + t[i] * alpha }
        return CGColor(colorSpace: base.colorSpace ?? CGColorSpaceCreateDeviceRGB(), components: [mix(0), mix(1), mix(2), 1])!
    }

    // Repository rows: the name on the left, then 8 pt, the 12 pt branch icon, 4 pt and the branch, which ends at the
    // right edge, or 8 pt before the marks when there is something to pull (down arrow) or push (up arrow); one space
    // between the arrows.
    private static let branchIconSize: CGFloat = 12
    private static let repoFixedWidth: CGFloat = 8 + branchIconSize + 4
    private static let marksGap: CGFloat = 8
    private static let pullArrowWidth: CGFloat = TextCache.shared.line("↓", .small, .red).width
    private static let pushArrowWidth: CGFloat = TextCache.shared.line("↑", .small, .green).width
    private static let markSpaceWidth: CGFloat = TextCache.shared.line(" ", .small, .dim).width
    private static let repoTextMemoLimit = 64

    /// Room the marks of a repository row take at its right end, the gap before them included. 0 without marks.
    private static func marksWidth(of sync: RepoSync?) -> CGFloat {
        guard let sync, sync.pull || sync.push else { return 0 }
        var width = marksGap
        if sync.pull { width += pullArrowWidth }
        if sync.push { width += pushArrowWidth }
        if sync.pull, sync.push { width += markSpaceWidth }
        return width
    }

    private struct RepoTextKey: Hashable {
        var name: String
        var branch: String
        var budget: CGFloat
    }

    /// Width of the room for a repository row's name and branch text together, in a tree `width` wide.
    private static func repoTextBudget(of row: TreeRow, width: CGFloat) -> CGFloat {
        let textLeft = Theme.treePadding + CGFloat(row.depth) * Theme.treeIndent + Theme.iconSize + 6
        return max(0, width - Theme.treePadding - textLeft - repoFixedWidth - marksWidth(of: row.sync))
    }

    /// What a repository row with a branch shows in `budget` points. Worked out once per name, branch and width.
    private func repoText(of row: TreeRow, branch: String, budget: CGFloat) -> RepoRowText.Fit {
        let key = RepoTextKey(name: row.name, branch: branch, budget: budget)
        if let fit = repoTexts[key] { return fit }
        if repoTexts.count >= Self.repoTextMemoLimit { repoTexts.removeAll(keepingCapacity: true) }
        let fit = RepoRowText.fit(
            name: row.name, branch: branch, budget: Double(budget),
            measureName: { Double(TextCache.makeLine([TextRun($0, .fg)], .regular).width) },
            measureBranch: { Double(TextCache.makeLine([TextRun($0, .dim)], .small).width) })
        repoTexts[key] = fit
        return fit
    }

    override func toolTip(at point: CGPoint) -> String? {
        toolTip(at: point, now: Date())
    }

    /// The tooltip of a repository row, in content coordinates; nil for every other row and when there is nothing to say.
    /// Lines, those that apply: the full `name  ·  branch` when what is drawn is shortened, what there is to pull,
    /// what there is to push. Worked out when asked, so "checked 2 minutes ago" is right when it is shown.
    func toolTip(at point: CGPoint, now: Date) -> String? {
        guard let index = rowIndex(atY: point.y), rows[index].kind == .repo else { return nil }
        let row = rows[index]
        var lines: [String] = []
        if let branch = row.branch {
            let budget = Self.repoTextBudget(of: row, width: visibleContentRect.width)
            if repoText(of: row, branch: branch, budget: budget).isShortened { lines.append("\(row.name)  ·  \(branch)") }
        }
        lines += row.sync?.toolTipLines(now: now) ?? []
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Repository rows: name on the left, branch on the right. When both do not fit, each is shortened in the middle.
    private func drawRepoName(
        _ row: TreeRow, style: TreeRowStyle, in ctx: CGContext, textX: CGFloat, right edge: CGFloat, rowY y: CGFloat, rowHeight h: CGFloat
    ) {
        let name: CTLine
        if let branch = row.branch {
            let budget = Self.repoTextBudget(of: row, width: visibleContentRect.width)
            let fit = repoText(of: row, branch: branch, budget: budget)
            let branchLine = TextCache.shared.line(fit.branch, .small, .dim)
            let textLeft = edge - Self.marksWidth(of: row.sync) - branchLine.width
            if let sync = row.sync { drawMarks(sync, in: ctx, right: edge, rowY: y, rowHeight: h) }
            if !fit.branch.isEmpty { ctx.draw(branchLine, x: textLeft, rowY: y, rowHeight: h, face: .small) }
            if budget > 0 {
                let size = Self.branchIconSize
                Icon.branch.draw(in: ctx, x: textLeft - 4 - size, y: y + ((h - size) / 2).rounded(), size: size, color: Ink.icon.cg)
            }
            name = TextCache.shared.line(fit.name, .regular, style.nameInk)
        } else {
            name = nameLine(for: row, ink: style.nameInk).truncated(to: max(0, edge - textX), face: .regular, ink: style.nameInk)
        }
        ctx.draw(name, x: textX, rowY: y, rowHeight: h, face: .regular)
        if style.strikethrough {
            let strikeY = y + (h / 2).rounded() + 0.5
            ctx.fill(CGRect(x: textX, y: strikeY, width: name.width, height: 1), style.nameInk.cg)
        }
    }

    /// The arrows at the right end of a repository row: push on the edge, then a space, then pull.
    private func drawMarks(_ sync: RepoSync, in ctx: CGContext, right: CGFloat, rowY y: CGFloat, rowHeight h: CGFloat) {
        var x = right
        if sync.push {
            x -= Self.pushArrowWidth
            ctx.draw("↑", .small, .green, x: x, rowY: y, rowHeight: h)
            if sync.pull { x -= Self.markSpaceWidth }
        }
        if sync.pull {
            x -= Self.pullArrowWidth
            ctx.draw("↓", .small, .red, x: x, rowY: y, rowHeight: h)
        }
    }

    private func nameLine(for row: TreeRow, ink: Ink) -> CTLine {
        if row.kind == .file, let old = row.change?.oldPath, row.change?.kind == .renamed {
            // "old.rs → new.rs": the old name is quieter.
            let oldName = (old as NSString).lastPathComponent
            return TextCache.makeLine([TextRun(oldName + " → ", .dim), TextRun(row.name, ink)], .regular)
        }
        if row.kind == .directory, row.name.contains("/") {
            // Compacted folders: dim the separators.
            var runs: [TextRun] = []
            for (i, part) in row.name.split(separator: "/", omittingEmptySubsequences: false).enumerated() {
                if i > 0 { runs.append(TextRun("/", .lineNumber)) }
                runs.append(TextRun(String(part), ink))
            }
            return TextCache.makeLine(runs, .regular)
        }
        return TextCache.shared.line(row.name, .regular, ink)
    }

    // MARK: - Mouse and keyboard

    override func mouse(_ phase: MousePhase, at point: CGPoint, event: NSEvent) {
        switch phase {
        case .moved:
            setHover(rowIndex(atY: point.y))
        case .exited:
            setHover(nil)
        case .down:
            guard let index = rowIndex(atY: point.y) else { return }
            activate(rows[index], pin: event.clickCount >= 2)
        case .dragged, .up:
            break
        }
    }

    private func setHover(_ index: Int?) {
        guard hoverIndex != index else { return }
        hoverIndex = index
        setNeedsRedraw()
    }

    private func activate(_ row: TreeRow, pin: Bool) {
        switch row.kind {
        case .repo, .directory:
            onToggle?(row)
        case .file:
            selectedID = row.id
            onOpen?(row, pin)
        }
    }

    override func keyDown(with event: NSEvent) {
        let current = selectedID.flatMap { id in rows.firstIndex { $0.id == id } }
        switch event.keyCode {
        case 125: moveSelection(from: current, step: 1) // down
        case 126: moveSelection(from: current, step: -1) // up
        case 36, 76: // return, enter
            if let current { onOpen?(rows[current], true) }
        default:
            super.keyDown(with: event)
        }
    }

    /// Moves to the next file row in a direction, opening it as a preview.
    private func moveSelection(from current: Int?, step: Int) {
        var index = current.map { $0 + step } ?? (step > 0 ? 0 : rows.count - 1)
        while rows.indices.contains(index) {
            if rows[index].kind == .file {
                selectedID = rows[index].id
                scrollRowToVisible(id: rows[index].id)
                onOpen?(rows[index], false)
                return
            }
            index += step
        }
    }
}
