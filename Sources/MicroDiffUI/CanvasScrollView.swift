import AppKit

enum MousePhase {
    case down, dragged, up, moved, exited
}

/// An `NSScrollView` that, when asked to, scrolls along one axis at a time and maps shift + wheel to sideways.
///
/// The axis is chosen from the first movement of a gesture (a trackpad swipe, or one wheel notch) and kept until
/// the gesture and its momentum end, so a mostly vertical swipe never drifts sideways and the other way around.
/// Vertical movement is left to AppKit (physics, rubber band) with the sideways part removed from the event;
/// sideways movement is applied here, because it must also work for events that no window delivered.
final class AxisLockedScrollView: NSScrollView {
    var locksAxis = false
    private var lockedAxis: Axis?

    private enum Axis { case horizontal, vertical }

    override func scrollWheel(with event: NSEvent) {
        guard locksAxis else {
            super.scrollWheel(with: event)
            return
        }
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        let canScrollSideways = (documentView?.frame.width ?? 0) > contentView.bounds.width + 0.5
        // Shift + wheel: the vertical wheel moves sideways (when there is somewhere to go).
        let swapped = canScrollSideways && event.modifierFlags.contains(.shift) && dx == 0
        if swapped { (dx, dy) = (dy, 0) }

        let isGestureStart = event.phase.contains(.began) || event.phase.contains(.mayBegin)
        let isLoose = event.phase.isEmpty && event.momentumPhase.isEmpty // a plain wheel notch
        if isGestureStart || isLoose { lockedAxis = nil }
        if lockedAxis == nil, dx != 0 || dy != 0 { lockedAxis = abs(dx) > abs(dy) ? .horizontal : .vertical }

        if lockedAxis == .horizontal {
            guard canScrollSideways, dx != 0 else { return }
            let step = event.hasPreciseScrollingDeltas ? dx : dx * 10
            let origin = contentView.bounds.origin
            let maxX = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
            contentView.scroll(to: CGPoint(x: min(max(0, origin.x - step), maxX), y: origin.y))
            reflectScrolledClipView(contentView)
            flashScrollers()
        } else if event.scrollingDeltaX == 0 {
            super.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: Self.withoutSidewaysPart(event) ?? event)
        }
    }

    /// A copy of the event with no sideways movement.
    private static func withoutSidewaysPart(_ event: NSEvent) -> NSEvent? {
        guard let cg = event.cgEvent?.copy() else { return nil }
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
        return NSEvent(cgEvent: cg)
    }
}

/// A scroll view whose content is drawn by code, and only the part that is on screen.
///
/// The scroll view owns an empty document view that is as large as the content (so scrollers and
/// scroll physics are native). A single canvas view is kept exactly over the visible rectangle and
/// redrawn on every scroll step. Memory use is one viewport of pixels no matter how long the content is.
class CanvasScrollView: NSView {
    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
        // Scrolling must happen on the main thread, step by step, so the canvas can follow it.
        override class var isCompatibleWithResponsiveScrolling: Bool { false }
    }

    private final class Canvas: NSView {
        weak var owner: CanvasScrollView?
        private var tracking: NSTrackingArea?

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) { owner?.drawCanvas() }

        override func mouseDown(with event: NSEvent) { owner?.forward(.down, event) }
        override func mouseDragged(with event: NSEvent) { owner?.forward(.dragged, event) }
        override func mouseUp(with event: NSEvent) { owner?.forward(.up, event) }

        override func mouseMoved(with event: NSEvent) {
            owner?.forward(.moved, event)
            owner?.updateCursor(windowPoint: event.locationInWindow)
        }

        override func mouseEntered(with event: NSEvent) { owner?.updateCursor(windowPoint: event.locationInWindow) }
        override func cursorUpdate(with event: NSEvent) { owner?.updateCursor(windowPoint: event.locationInWindow) }

        override func mouseExited(with event: NSEvent) {
            owner?.forward(.exited, event)
            NSCursor.arrow.set()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }
    }

    let scrollView = AxisLockedScrollView()
    private let documentView = DocumentView()
    private let canvas = Canvas()
    private var isSyncing = false

    /// Scroll along one axis at a time, and shift + wheel sideways (see `AxisLockedScrollView`). Off for the code view.
    var locksScrollAxis: Bool {
        get { scrollView.locksAxis }
        set { scrollView.locksAxis = newValue }
    }

    /// Size of everything that can be scrolled to.
    var contentSize: CGSize = .zero {
        didSet { if contentSize != oldValue { syncCanvas() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = documentView
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        addSubview(scrollView)

        canvas.owner = self
        documentView.addSubview(canvas)

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipChanged), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(clipChanged), name: NSView.frameDidChangeNotification, object: clip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var isFlipped: Bool { true }

    @objc private func clipChanged() {
        syncCanvas()
        visibleRectChanged()
        // Scrolling moves the content under a pointer that stands still.
        refreshPointer()
    }

    // MARK: - Pointer

    /// The pointer position in content coordinates, when it is over the canvas itself
    /// (not over a scroller or another view on top) in the key window. Nil otherwise.
    func pointerLocation() -> CGPoint? {
        guard let window, window.isKeyWindow else { return nil }
        return contentPoint(windowPoint: window.mouseLocationOutsideOfEventStream)
    }

    private func contentPoint(windowPoint: CGPoint) -> CGPoint? {
        guard canvas.isTopmost(atWindowPoint: windowPoint) else { return nil }
        let local = canvas.convert(windowPoint, from: nil)
        let visible = visibleContentRect
        return CGPoint(x: local.x + visible.minX, y: local.y + visible.minY)
    }

    fileprivate func updateCursor(windowPoint: CGPoint) {
        if let point = contentPoint(windowPoint: windowPoint) {
            cursor(at: point).set()
        } else if let hit = window?.topmostView(atWindowPoint: windowPoint), hit !== canvas, hit.isDescendant(of: scrollView) {
            // Over one of our own scrollers.
            NSCursor.arrow.set()
        }
        // Anything else on top (the sidebar resize handle) sets its own cursor.
    }

    /// Re-evaluates the cursor for where the pointer is now. Call after the content under it changed.
    func refreshPointer() {
        guard let window, window.isKeyWindow else { return }
        updateCursor(windowPoint: window.mouseLocationOutsideOfEventStream)
    }

    /// Keeps the document size and the canvas position in step with the scroll position.
    private func syncCanvas() {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let clip = scrollView.contentView
        let size = NSSize(width: max(contentSize.width, clip.bounds.width), height: max(contentSize.height, clip.bounds.height))
        if documentView.frame.size != size { documentView.setFrameSize(size) }
        let visible = clip.bounds
        if canvas.frame != visible { canvas.frame = visible }
        canvas.needsDisplay = true
    }

    private func drawCanvas() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let visible = visibleContentRect
        ctx.saveGState()
        ctx.translateBy(x: -visible.minX, y: -visible.minY)
        draw(in: ctx, visible: visible)
        ctx.restoreGState()
    }

    private func forward(_ phase: MousePhase, _ event: NSEvent) {
        if phase == .down { window?.makeFirstResponder(self) }
        if phase == .dragged { canvas.autoscroll(with: event) }
        let local = canvas.convert(event.locationInWindow, from: nil)
        let visible = visibleContentRect
        mouse(phase, at: CGPoint(x: local.x + visible.minX, y: local.y + visible.minY), event: event)
    }

    // MARK: - For subclasses

    /// The part of the content that is on screen, in content coordinates.
    var visibleContentRect: CGRect { scrollView.contentView.bounds }

    func setNeedsRedraw() {
        canvas.needsDisplay = true
    }

    func scroll(to point: CGPoint) {
        let clip = scrollView.contentView
        let maxX = max(0, documentView.frame.width - clip.bounds.width)
        let maxY = max(0, documentView.frame.height - clip.bounds.height)
        let target = CGPoint(x: min(max(0, point.x), maxX), y: min(max(0, point.y), maxY))
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
    }

    func scroll(by delta: CGPoint) {
        let origin = visibleContentRect.origin
        scroll(to: CGPoint(x: origin.x + delta.x, y: origin.y + delta.y))
    }

    /// Draw the content that intersects `visible`. Coordinates are content coordinates, y grows down.
    func draw(in ctx: CGContext, visible: CGRect) {}

    /// `point` is in content coordinates.
    func mouse(_ phase: MousePhase, at point: CGPoint, event: NSEvent) {}

    func visibleRectChanged() {}

    /// The cursor for a point in content coordinates: a pointing hand over things that react to a click.
    func cursor(at point: CGPoint) -> NSCursor { .arrow }

    /// Renders the visible part into any context (used for snapshots and tests).
    func render(in ctx: CGContext) {
        let visible = visibleContentRect
        ctx.saveGState()
        ctx.translateBy(x: -visible.minX, y: -visible.minY)
        draw(in: ctx, visible: visible)
        ctx.restoreGState()
    }
}

extension NSWindow {
    /// The frontmost view at a point given in window coordinates.
    func topmostView(atWindowPoint point: CGPoint) -> NSView? {
        // The frame view has no superview, so its own coordinates are window coordinates.
        contentView?.superview?.hitTest(point) ?? contentView?.hitTest(point)
    }
}

extension NSView {
    /// True when this view itself is the frontmost view at the point: nothing lies on top of it there.
    func isTopmost(atWindowPoint point: CGPoint) -> Bool {
        window?.topmostView(atWindowPoint: point) === self
    }
}
