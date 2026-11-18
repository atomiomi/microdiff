import AppKit
import MicroDiffCore

/// Invisible strip over the sidebar edge: drag it to resize the sidebar.
private final class SidebarResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }
}

/// What a double click on a window's title bar does. The user picks it in System Settings
/// (Desktop & Dock > "Double-click a window's title bar to").
enum TitleBarDoubleClick: Equatable {
    case zoom, minimize, nothing

    /// `value` is the system's `AppleActionOnDoubleClick` setting.
    init(setting value: String?) {
        switch value {
        case "Minimize": self = .minimize
        case "None": self = .nothing
        // "Maximize" (zoom), the newer "Fill", and no setting at all (the default is zoom).
        default: self = .zoom
        }
    }

    static var systemSetting: TitleBarDoubleClick {
        TitleBarDoubleClick(setting: UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick"))
    }

    func perform(on window: NSWindow) {
        switch self {
        case .zoom: window.zoom(nil)
        case .minimize: window.miniaturize(nil)
        case .nothing: break
        }
    }
}

/// A solid-color view. It is only a layer color, so it costs no pixel buffer.
private final class FillView: NSView {
    init(_ color: CGColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }
}

/// One short line of quiet text, sized to fit it (the window title, "no file open", "binary file").
private final class LabelView: NSView {
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            superview?.needsLayout = true
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    // Clicks and window drags go through to whatever is behind.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var fittingWidth: CGFloat {
        text.isEmpty ? 0 : ceil(TextCache.shared.line(text, .regular, .dim).width) + 2
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(text, .regular, .dim, x: 1, rowY: 0, rowHeight: bounds.height)
    }
}

/// The whole window content: title strip, sidebar (tabs + tree), file tabs and the code view.
///
/// This view draws nothing itself: a view that draws gets a pixel buffer the size of the whole window.
/// Its background is the window color and its lines and labels are small views of their own.
final class RootView: NSView {
    let sidebarTabs = SidebarTabsView()
    let tree = TreeView()
    let tabBar = FileTabBarView()
    let codeView = CodeView()
    private let resizeHandle = SidebarResizeHandle()
    private let titleLabel = LabelView()
    private let messageLabel = LabelView()
    private let titleLine = FillView(Theme.line)
    private let sidebarLine = FillView(Theme.line)

    static let sidebarWidthKey = "sidebarWidth"

    var title: String {
        get { titleLabel.text }
        set { titleLabel.text = newValue }
    }

    /// Shown in place of the code view ("no file open", "binary file").
    var message: String? {
        didSet {
            codeView.isHidden = message != nil
            messageLabel.isHidden = message == nil
            messageLabel.text = message ?? ""
        }
    }

    private(set) var sidebarWidth: CGFloat

    override init(frame frameRect: NSRect) {
        let saved = UserDefaults.standard.double(forKey: Self.sidebarWidthKey)
        sidebarWidth = saved >= 160 ? CGFloat(saved) : Theme.defaultSidebarWidth
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.background
        messageLabel.isHidden = true
        for view in [sidebarTabs, tree, tabBar, codeView, messageLabel, titleLabel, titleLine, sidebarLine, resizeHandle] as [NSView] {
            addSubview(view)
        }
        resizeHandle.onDrag = { [weak self] x in self?.setSidebarWidth(x) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var isFlipped: Bool { true }

    /// Height of the system title bar that floats over the top of this view.
    private var titleBarHeight: CGFloat {
        guard let window else { return 28 }
        return max(0, window.frame.height - window.contentLayoutRect.height)
    }

    // MARK: - Title strip

    // With a transparent title bar the system's own title bar view no longer receives clicks in this strip:
    // they land here. So this view does what a title bar does: drag the window, and react to a double click.

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window, convert(event.locationInWindow, from: nil).y < titleBarHeight else {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2 {
            TitleBarDoubleClick.systemSetting.perform(on: window)
        } else {
            window.performDrag(with: event)
        }
    }

    private func setSidebarWidth(_ width: CGFloat) {
        let clamped = min(max(160, width.rounded()), max(160, bounds.width - 240))
        guard clamped != sidebarWidth else { return }
        sidebarWidth = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.sidebarWidthKey)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let titleHeight = titleBarHeight
        let top = titleHeight + 1
        let height = max(0, bounds.height - top)
        let sidebar = min(sidebarWidth, max(160, bounds.width - 240))
        let mainX = sidebar + 1
        let mainWidth = max(0, bounds.width - mainX)
        let codeFrame = CGRect(x: mainX, y: top + Theme.tabBarHeight, width: mainWidth, height: max(0, height - Theme.tabBarHeight))

        sidebarTabs.frame = CGRect(x: 0, y: top, width: sidebar, height: Theme.tabBarHeight)
        tree.frame = CGRect(x: 0, y: top + Theme.tabBarHeight, width: sidebar, height: max(0, height - Theme.tabBarHeight))
        tabBar.frame = CGRect(x: mainX, y: top, width: mainWidth, height: Theme.tabBarHeight)
        codeView.frame = codeFrame
        resizeHandle.frame = CGRect(x: sidebar - 2, y: top, width: 5, height: height)
        titleLine.frame = CGRect(x: 0, y: titleHeight, width: bounds.width, height: 1)
        sidebarLine.frame = CGRect(x: sidebar, y: top, width: 1, height: height)

        let titleWidth = min(titleLabel.fittingWidth, max(0, bounds.width - 160))
        titleLabel.frame = CGRect(x: ((bounds.width - titleWidth) / 2).rounded(), y: 0, width: titleWidth, height: titleHeight)
        let messageWidth = min(messageLabel.fittingWidth, mainWidth)
        messageLabel.frame = CGRect(
            x: (codeFrame.midX - messageWidth / 2).rounded(), y: (codeFrame.midY - Theme.lineHeight / 2).rounded(),
            width: messageWidth, height: Theme.lineHeight)
    }
}

/// Owns the window and connects the views to the workspace state.
final class MainWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let root = RootView()
    private(set) var workspace: Workspace
    private var sidebarScroll: [SidebarTab: CGPoint] = [:]
    /// Called once, after the first scan result is on screen.
    var onFirstSnapshot: (() -> Void)?
    /// The folder this window was opened on (standardized, symlinks resolved). The workspace's root may be above it.
    private(set) var folderPath: String
    /// Files to open once the first scan is in (`--open`, or a request from a later start).
    private var pendingFiles: [(path: String, mode: ViewMode?)] = []
    /// The window is closing (the window manager drops this controller).
    var onClose: ((MainWindowController) -> Void)?
    /// The window became the key window.
    var onBecomeKey: ((MainWindowController) -> Void)?

    init(path: String) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        workspace = Workspace(path: path)
        folderPath = Self.canonical(path)
        super.init()

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(cgColor: Theme.background)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 560, height: 320)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.delegate = self
        window.center()

        connectViews()
        connect(workspace)
    }

    private func connectViews() {
        root.sidebarTabs.onSelect = { [weak self] tab in self?.selectSidebarTab(tab) }
        root.tree.onToggle = { [weak self] row in self?.workspace.toggle(row) }
        root.tree.onOpen = { [weak self] row, pin in self?.workspace.open(row, pin: pin) }
        root.tabBar.onSelect = { [weak self] index in self?.workspace.selectTab(index) }
        root.tabBar.onPin = { [weak self] index in self?.workspace.pinTab(index) }
        root.tabBar.onClose = { [weak self] index in self?.workspace.closeTab(index) }
        root.tabBar.onMode = { [weak self] mode in self?.workspace.setMode(mode) }
        root.codeView.onExpandFold = { [weak self] line in self?.workspace.expandFold(startingAt: line) }
        root.codeView.onScroll = { [weak self] offset in self?.workspace.rememberScroll(offset) }
    }

    private func connect(_ workspace: Workspace) {
        workspace.onSidebarChanged = { [weak self] in self?.refreshSidebar() }
        workspace.onTabsChanged = { [weak self] in self?.refreshTabs() }
        workspace.onContentChanged = { [weak self] keepScroll in self?.showContent(keepScroll: keepScroll) }
        refreshSidebar()
        refreshTabs()
        showContent(keepScroll: false)
    }

    /// The form folder paths are compared in: absolute, standardized, symlinks resolved (like the workspace root).
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Opens another folder in this window.
    func open(path: String) {
        workspace = Workspace(path: path)
        folderPath = Self.canonical(path)
        pendingFiles.removeAll()
        sidebarScroll.removeAll()
        connect(workspace)
        workspace.start()
    }

    /// Opens files as tabs: now when the first scan is in, otherwise as soon as it is.
    /// Relative paths are relative to the repository root.
    func open(files: [String], mode: ViewMode?) {
        pendingFiles += files.map { ($0, mode) }
        if workspace.snapshot != nil { openPendingFiles() }
    }

    private func openPendingFiles() {
        let files = pendingFiles
        pendingFiles.removeAll()
        for (file, mode) in files {
            let path = file.hasPrefix("/") ? file : workspace.rootPath + "/" + file
            workspace.openFile(path, mode: mode ?? .diff, pin: true)
        }
    }

    /// Puts the window on screen (or brings it back from the Dock) and makes it key.
    func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // Arrow keys work in the list right away.
        window.makeFirstResponder(root.tree)
    }

    // MARK: - Workspace -> views

    private func refreshSidebar() {
        let isFirst = root.tree.rows.isEmpty && workspace.snapshot != nil
        root.title = workspace.rootName
        // The Window menu lists windows by this title (the title bar itself hides it).
        if window.title != workspace.rootName { window.title = workspace.rootName }
        root.sidebarTabs.selected = workspace.sidebarTab
        root.sidebarTabs.changeCount = workspace.snapshot?.totalChangeCount ?? 0
        root.tree.style = workspace.sidebarTab == .changes ? .changes : .files
        root.tree.setRows(workspace.sidebarRows())
        root.tree.selectedID = workspace.selectedRowID
        root.tree.emptyMessage = workspace.sidebarEmptyMessage
        if isFirst, let onFirstSnapshot {
            self.onFirstSnapshot = nil
            onFirstSnapshot()
        }
        if !pendingFiles.isEmpty, workspace.snapshot != nil {
            // Not in the middle of this refresh: opening a file refreshes the sidebar again.
            DispatchQueue.main.async { [weak self] in self?.openPendingFiles() }
        }
    }

    private func refreshTabs() {
        let tabs = workspace.tabs.map { FileTab(title: $0.title, kind: $0.change?.kind, isPreview: $0.isPreview) }
        let mode = workspace.activeTab.map { workspace.tabs[$0].mode } ?? .diff
        root.tabBar.update(tabs: tabs, activeIndex: workspace.activeTab, mode: mode)
    }

    private func showContent(keepScroll: Bool) {
        switch workspace.content {
        case let .text(document)?:
            root.message = nil
            root.codeView.setDocument(document, keepScroll: keepScroll, scroll: workspace.activeScroll)
        case let .message(text)?:
            root.codeView.setDocument(nil, keepScroll: false)
            root.message = text
        case nil:
            root.codeView.setDocument(nil, keepScroll: false)
            // While a tab's file is still loading the area stays blank instead of flashing a message.
            root.message = workspace.activeTab == nil ? "no file open" : nil
        }
    }

    private func selectSidebarTab(_ tab: SidebarTab) {
        guard tab != workspace.sidebarTab else { return }
        sidebarScroll[workspace.sidebarTab] = root.tree.visibleContentRect.origin
        workspace.selectSidebarTab(tab)
        root.tree.scroll(to: sidebarScroll[tab] ?? .zero)
        if let selected = workspace.selectedRowID {
            root.tree.scrollRowToVisible(id: selected)
        }
    }

    // MARK: - Window events

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onBecomeKey?(self)
    }

    // MARK: - Menu actions

    @objc func closeTab(_ sender: Any?) {
        if workspace.activeTab != nil {
            workspace.closeActiveTab()
        } else {
            window.performClose(sender)
        }
    }

    @objc func showChanges(_ sender: Any?) { selectSidebarTab(.changes) }
    @objc func showFiles(_ sender: Any?) { selectSidebarTab(.files) }

    @objc func toggleDiffFile(_ sender: Any?) {
        guard let active = workspace.activeTab else { return }
        workspace.setMode(workspace.tabs[active].mode == .diff ? .file : .diff)
    }

    @objc func refresh(_ sender: Any?) { workspace.refresh() }

    @objc func nextTab(_ sender: Any?) { stepTab(1) }
    @objc func previousTab(_ sender: Any?) { stepTab(-1) }

    private func stepTab(_ step: Int) {
        let count = workspace.tabs.count
        guard count > 1, let active = workspace.activeTab else { return }
        workspace.selectTab((active + step + count) % count)
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(path: url.path)
    }

    // MARK: - Snapshots (for tests and visual checks)

    /// Loads everything on the calling thread and renders the window content to PNG data.
    func renderSnapshot(size: CGSize, sidebarTab: SidebarTab, open relativePaths: [String], mode: ViewMode?, scroll: CGFloat = 0) -> Data? {
        window.setContentSize(size)
        workspace.scanNow()
        for relativePath in relativePaths {
            let path = relativePath.hasPrefix("/") ? relativePath : workspace.rootPath + "/" + relativePath
            workspace.openFile(path, mode: mode ?? (sidebarTab == .changes ? .diff : .file), pin: true, synchronously: true)
        }
        if sidebarTab != workspace.sidebarTab { workspace.selectSidebarTab(sidebarTab) }
        root.layoutSubtreeIfNeeded()
        if scroll > 0 { root.codeView.scroll(to: CGPoint(x: 0, y: scroll)) }
        // The window's frame view also draws the title bar buttons, so the picture shows the whole window.
        let target: NSView = root.superview ?? root
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return nil }
        target.cacheDisplay(in: target.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
