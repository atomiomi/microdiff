import AppKit
import MicroDiffCore

enum SidebarTab {
    case changes, files
}

/// The two tabs on top of the sidebar: "changes N" and "files".
/// The active tab has the same background as the list below it; the inactive one is darker and boxed in.
final class SidebarTabsView: NSView {
    var selected: SidebarTab = .changes {
        didSet { if selected != oldValue { needsDisplay = true } }
    }

    var changeCount = 0 {
        didSet { if changeCount != oldValue { needsDisplay = true } }
    }

    var onSelect: ((SidebarTab) -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let half = (bounds.width / 2).rounded()
        let textHeight = bounds.height - 1

        for (index, tab) in [SidebarTab.changes, .files].enumerated() {
            let rect = CGRect(x: index == 0 ? 0 : half, y: 0, width: index == 0 ? half : bounds.width - half, height: bounds.height)
            let isActive = tab == selected
            if !isActive {
                ctx.fill(rect, Theme.inactive)
                ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1), Theme.line)
                // The edge that touches the active tab.
                ctx.fill(CGRect(x: index == 0 ? rect.maxX - 1 : rect.minX, y: 0, width: 1, height: rect.height), Theme.line)
            }

            var runs = [TextRun(tab == .changes ? "changes" : "files", isActive ? .fg : .dim)]
            if tab == .changes {
                runs.append(TextRun(" \(changeCount)", .dim))
            }
            let face: Face = isActive ? .medium : .regular
            let line = TextCache.makeLine(runs, face)
            ctx.draw(line, x: (rect.midX - line.width / 2).rounded(), rowY: 0, rowHeight: textHeight, face: face)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onSelect?(point.x < bounds.width / 2 ? .changes : .files)
    }

    // Both tabs are buttons: show a pointing hand, unless another view (the resize handle) is on top.

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func updateCursor(_ event: NSEvent) {
        if isTopmost(atWindowPoint: event.locationInWindow) { NSCursor.pointingHand.set() }
    }

    override func mouseEntered(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
}

struct FileTab: Equatable {
    var title: String
    var kind: ChangeKind?
    /// A preview tab is replaced by the next file opened with a single click.
    var isPreview: Bool
    /// Unsaved edits: a dot sits where the close box is (until the pointer is over the tab).
    var isUnsaved = false
}

/// The row of open files above the code, with the `diff / read / edit` switch pinned at the right.
final class FileTabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    /// Double click: keep the tab (stop it being a preview).
    var onPin: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onMode: ((ViewMode) -> Void)?

    private(set) var tabs: [FileTab] = []
    private(set) var activeIndex: Int?
    private(set) var mode: ViewMode = .diff
    /// False when the open file cannot be edited: `edit` is drawn dimmed and does not react.
    private(set) var canEdit = true

    private var scrollX: CGFloat = 0
    /// Bring the active tab into view on the next layout (after it changed), but not while the user scrolls.
    private var revealActive = true
    private var hoverTab: Int?
    private var hoverClose = false
    private var isHovering = false
    private var tracking: NSTrackingArea?

    // A tab is laid out as: [16] name + status letter [8] close box (18) [8].
    // Every tab keeps the room for the close box, shown or not, so nothing shifts on hover or when it becomes active.
    private static let leftPadding: CGFloat = 16
    private static let gap: CGFloat = 8
    private static let closeBox: CGFloat = 18
    private static let closeIcon: CGFloat = 10
    private static let rightPadding: CGFloat = 8
    private static let controlPadding: CGFloat = 16
    private static let dotSize: CGFloat = 8

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(tabs: [FileTab], activeIndex: Int?, mode: ViewMode, canEdit: Bool = true) {
        if tabs != self.tabs || activeIndex != self.activeIndex { revealActive = true }
        self.tabs = tabs
        self.activeIndex = activeIndex
        self.mode = mode
        self.canEdit = canEdit
        needsDisplay = true
    }

    /// Whether the open file can be edited is often known only once its content has arrived (a binary file).
    func setCanEdit(_ canEdit: Bool) {
        guard canEdit != self.canEdit else { return }
        self.canEdit = canEdit
        needsDisplay = true
    }

    // MARK: - Geometry

    private struct Geometry {
        var layout: TabBarLayout
        /// Width of the scrolling strip; the pinned controls start here.
        var viewport: CGFloat
        var menuRect: CGRect?
        var dividerX: CGFloat?
        var diffRect: CGRect
        var readRect: CGRect
        var editRect: CGRect

        /// The switch word under a point (with a little slack around each word).
        func mode(at point: CGPoint) -> ViewMode? {
            let words: [(CGRect, ViewMode)] = [(diffRect, .diff), (readRect, .read), (editRect, .edit)]
            return words.first { $0.0.insetBy(dx: -7, dy: 0).contains(point) }?.1
        }
    }

    private func titleFace(_ index: Int) -> Face {
        tabs[index].isPreview ? .italic : (index == activeIndex ? .medium : .regular)
    }

    private func titleLine(_ index: Int) -> CTLine {
        TextCache.shared.line(tabs[index].title, titleFace(index), index == activeIndex ? .fg : .dim)
    }

    private func letterLine(_ index: Int) -> CTLine? {
        tabs[index].kind.map { TextCache.shared.line($0.letter, .small, Ink.change($0)) }
    }

    /// Width of a tab's label: name plus status letter.
    private func labelWidth(_ index: Int) -> CGFloat {
        var width = titleLine(index).width
        if let letter = letterLine(index) { width += Self.gap + letter.width }
        return width
    }

    /// Narrowest a tab can be: its label plus the paddings and the close box.
    private func naturalWidth(_ index: Int) -> CGFloat {
        Self.leftPadding + labelWidth(index) + Self.gap + Self.closeBox + Self.rightPadding
    }

    private func geometry() -> Geometry {
        let diffWidth = TextCache.shared.line("diff", .regular, .fg).width
        let readWidth = TextCache.shared.line("read", .regular, .fg).width
        let editWidth = TextCache.shared.line("edit", .regular, .fg).width
        let toggleGap = Theme.charWidth * 2
        let toggleWidth = tabs.isEmpty ? 0 : Self.controlPadding * 2 + diffWidth + toggleGap + readWidth + toggleGap + editWidth
        let countWidth = TextCache.shared.line("\(tabs.count)", .regular, .dim).width
        let menuWidth = Self.controlPadding * 2 + countWidth + 4 + 13

        let natural = tabs.indices.map { Double(naturalWidth($0)) }
        func layout(_ viewport: CGFloat) -> TabBarLayout {
            TabBarLayout.compute(
                naturalWidths: natural, viewportWidth: Double(viewport), fixedWidth: Double(Theme.fixedTabWidth),
                activeIndex: revealActive ? activeIndex : nil, scrollX: Double(scrollX))
        }

        var viewport = max(0, bounds.width - toggleWidth)
        var result = layout(viewport)
        var menuRect: CGRect?
        var dividerX: CGFloat?
        if result.overflows {
            // Overflow adds the "12 ⌄" button, which takes room from the strip.
            viewport = max(0, bounds.width - toggleWidth - menuWidth - 1)
            result = layout(viewport)
            menuRect = CGRect(x: viewport, y: 0, width: menuWidth, height: bounds.height)
            dividerX = viewport + menuWidth
        }

        let toggleX = bounds.width - toggleWidth + Self.controlPadding
        let diffRect = CGRect(x: toggleX, y: 0, width: diffWidth, height: bounds.height - 1)
        let readRect = CGRect(x: diffRect.maxX + toggleGap, y: 0, width: readWidth, height: bounds.height - 1)
        let editRect = CGRect(x: readRect.maxX + toggleGap, y: 0, width: editWidth, height: bounds.height - 1)
        return Geometry(
            layout: result, viewport: viewport, menuRect: menuRect, dividerX: dividerX, diffRect: diffRect, readRect: readRect,
            editRect: editRect)
    }

    /// The close box of a tab, in view coordinates: pinned to the tab's right edge, centered vertically.
    private func closeRect(_ index: Int, _ geo: Geometry) -> CGRect {
        let frame = geo.layout.frames[index]
        let right = CGFloat(frame.maxX) - CGFloat(geo.layout.scrollX)
        return CGRect(
            x: right - Self.rightPadding - Self.closeBox, y: ((bounds.height - 1 - Self.closeBox) / 2).rounded(),
            width: Self.closeBox, height: Self.closeBox)
    }

    /// The open tab always shows its close box; other tabs show it while the pointer is over them.
    private func showsClose(_ index: Int) -> Bool {
        index == activeIndex || index == hoverTab
    }

    /// Left edge of a tab's label: centered in the tab, but never under the close box.
    private func labelX(_ index: Int, _ geo: Geometry) -> CGFloat {
        let frame = geo.layout.frames[index]
        let left = CGFloat(frame.x) - CGFloat(geo.layout.scrollX)
        let label = labelWidth(index)
        let centered = left + (CGFloat(frame.width) - label) / 2
        return min(centered, closeRect(index, geo).minX - Self.gap - label)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let geo = geometry()
        scrollX = CGFloat(geo.layout.scrollX)
        revealActive = false
        let height = bounds.height
        let textHeight = height - 1

        // The bar itself: dark strip with a line under it. Tabs are painted on top.
        ctx.fill(bounds, Theme.inactive)
        ctx.fill(CGRect(x: 0, y: height - 1, width: bounds.width, height: 1), Theme.line)

        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: geo.viewport, height: height))
        for index in tabs.indices {
            let frame = geo.layout.frames[index]
            let left = CGFloat(frame.x) - scrollX
            let width = CGFloat(frame.width)
            guard left < geo.viewport, left + width > 0 else { continue }
            let isActive = index == activeIndex

            if isActive {
                ctx.fill(CGRect(x: left, y: 0, width: width, height: height), Theme.background)
            } else if index > 0 {
                ctx.fill(CGRect(x: left, y: 0, width: 1, height: height), Theme.line)
            }

            var x = labelX(index, geo)
            let title = titleLine(index)
            ctx.draw(title, x: x, rowY: 0, rowHeight: textHeight, face: titleFace(index))
            x += title.width
            if let letter = letterLine(index) {
                x += Self.gap
                ctx.saveGState()
                if !isActive { ctx.setAlpha(0.6) }
                ctx.draw(letter, x: x, rowY: 0, rowHeight: textHeight, face: .small)
                ctx.restoreGState()
            }
            if tabs[index].isUnsaved, index != hoverTab {
                let box = closeRect(index, geo)
                let dot = CGRect(x: box.midX - Self.dotSize / 2, y: box.midY - Self.dotSize / 2, width: Self.dotSize, height: Self.dotSize)
                ctx.setFillColor((isActive ? Ink.fg : Ink.dim).cg)
                ctx.fillEllipse(in: dot)
            } else if showsClose(index) {
                let box = closeRect(index, geo)
                let isHot = hoverClose && hoverTab == index
                if isHot {
                    ctx.setFillColor(Theme.closeHover)
                    ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
                    ctx.fillPath()
                }
                let inset = (Self.closeBox - Self.closeIcon) / 2
                Icon.close.draw(
                    in: ctx, x: box.minX + inset, y: box.minY + inset, size: Self.closeIcon,
                    color: (isHot ? Ink.fg : Ink.icon).cg, weight: 2.6)
            }
        }
        ctx.restoreGState()

        if geo.layout.overflows {
            let maxScroll = CGFloat(geo.layout.contentWidth) - geo.viewport
            if scrollX > 0.5 { drawFade(ctx, x: 0, toRight: true, height: height - 1) }
            if scrollX < maxScroll - 0.5 { drawFade(ctx, x: geo.viewport - 32, toRight: false, height: height - 1) }
            if isHovering, geo.layout.contentWidth > 0 {
                let ratio = geo.viewport / CGFloat(geo.layout.contentWidth)
                let thumb = CGRect(x: scrollX * ratio, y: height - 3, width: geo.viewport * ratio, height: 2)
                ctx.setFillColor(Theme.scrollThumb)
                ctx.addPath(CGPath(roundedRect: thumb, cornerWidth: 1, cornerHeight: 1, transform: nil))
                ctx.fillPath()
            }
        }

        guard !tabs.isEmpty else { return }

        // Pinned controls.
        if let menuRect = geo.menuRect, let dividerX = geo.dividerX {
            ctx.fill(CGRect(x: menuRect.minX, y: 0, width: 1, height: height), Theme.line)
            let count = TextCache.shared.line("\(tabs.count)", .regular, .dim)
            let x = menuRect.minX + Self.controlPadding
            ctx.draw(count, x: x, rowY: 0, rowHeight: textHeight, face: .regular)
            Icon.chevronDown.draw(in: ctx, x: x + count.width + 4, y: ((textHeight - 13) / 2).rounded(), size: 13, color: Ink.icon.cg, weight: 2)
            ctx.fill(CGRect(x: dividerX, y: 0, width: 1, height: height), Theme.line)
        } else {
            ctx.fill(CGRect(x: geo.viewport, y: 0, width: 1, height: height), Theme.line)
        }
        ctx.draw("diff", .regular, mode == .diff ? .fg : .dim, x: geo.diffRect.minX, rowY: 0, rowHeight: textHeight)
        ctx.draw("read", .regular, mode == .read ? .fg : .dim, x: geo.readRect.minX, rowY: 0, rowHeight: textHeight)
        let editInk: Ink = mode == .edit ? .fg : canEdit ? .dim : .lineNumber
        ctx.draw("edit", .regular, editInk, x: geo.editRect.minX, rowY: 0, rowHeight: textHeight)
    }

    /// Tabs cut off at an edge fade into the bar color.
    private func drawFade(_ ctx: CGContext, x: CGFloat, toRight: Bool, height: CGFloat) {
        let solid = Theme.inactive
        let clear = solid.copy(alpha: 0) ?? solid
        guard let gradient = CGGradient(colorsSpace: nil, colors: [solid, clear] as CFArray, locations: [0, 1]) else { return }
        let rect = CGRect(x: x, y: 0, width: 32, height: height)
        ctx.saveGState()
        ctx.clip(to: rect)
        let start = CGPoint(x: toRight ? rect.minX : rect.maxX, y: 0)
        let end = CGPoint(x: toRight ? rect.maxX : rect.minX, y: 0)
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
        ctx.restoreGState()
    }

    // MARK: - Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func cursorUpdate(with event: NSEvent) { updateHover(event) }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        hoverTab = nil
        hoverClose = false
        needsDisplay = true
        NSCursor.arrow.set()
    }

    /// A pointing hand over everything that reacts to a click: tabs, close boxes, the tab list button and the switch
    /// (not over a dimmed `edit`).
    func cursor(at point: CGPoint) -> NSCursor {
        let geo = geometry()
        if point.x < geo.viewport {
            return geo.layout.index(atViewportX: Double(point.x)) == nil ? .arrow : .pointingHand
        }
        guard !tabs.isEmpty else { return .arrow }
        let word = geo.mode(at: point)
        let onControl = geo.menuRect?.contains(point) == true || (word != nil && (word != .edit || canEdit))
        return onControl ? .pointingHand : .arrow
    }

    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isTopmost(atWindowPoint: event.locationInWindow) { cursor(at: point).set() }
        let geo = geometry()
        let tab = point.x < geo.viewport ? geo.layout.index(atViewportX: Double(point.x)) : nil
        let overClose = tab.map { closeRect($0, geo).contains(point) } ?? false
        if tab != hoverTab || overClose != hoverClose || !isHovering {
            hoverTab = tab
            hoverClose = overClose
            isHovering = true
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let geo = geometry()
        if point.x >= geo.viewport {
            guard !tabs.isEmpty else { return }
            if let menuRect = geo.menuRect, menuRect.contains(point) {
                showMenu(at: CGPoint(x: menuRect.minX, y: bounds.height + 2))
            } else if let word = geo.mode(at: point), word != .edit || canEdit {
                onMode?(word)
            }
            return
        }
        guard let index = geo.layout.index(atViewportX: Double(point.x)) else { return }
        // A tab under the pointer always shows its close box, so a click at that spot is a click on it.
        if closeRect(index, geo).contains(point) {
            onClose?(index)
        } else if event.clickCount >= 2 {
            onPin?(index)
        } else {
            onSelect?(index)
        }
    }

    /// Middle click closes a tab.
    override func otherMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let geo = geometry()
        guard event.buttonNumber == 2, point.x < geo.viewport, let index = geo.layout.index(atViewportX: Double(point.x)) else {
            super.otherMouseDown(with: event)
            return
        }
        onClose?(index)
    }

    override func scrollWheel(with event: NSEvent) {
        let geo = geometry()
        guard geo.layout.overflows else {
            super.scrollWheel(with: event)
            return
        }
        // A vertical wheel also moves the strip sideways.
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let step = event.hasPreciseScrollingDeltas ? delta : delta * 12
        let maxScroll = max(0, CGFloat(geo.layout.contentWidth) - geo.viewport)
        scrollX = min(max(0, scrollX - step), maxScroll)
        needsDisplay = true
    }

    private func showMenu(at point: CGPoint) {
        let menu = NSMenu()
        for (index, tab) in tabs.enumerated() {
            let item = NSMenuItem(title: tab.title, action: #selector(menuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == activeIndex ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func menuPicked(_ sender: NSMenuItem) {
        onSelect?(sender.tag)
    }
}
