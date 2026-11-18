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
    static let sidebarHiddenKey = "sidebarHidden"

    var title: String {
        get { titleLabel.text }
        set { titleLabel.text = newValue }
    }

    /// Shown in place of the code view ("no file open", "binary file").
    var message: String? {
        didSet {
            messageLabel.text = message ?? ""
            updateVisibility()
        }
    }

    /// The editor: made the first time a tab enters edit mode, then kept (hidden and empty when no tab is in edit mode).
    private(set) var editor: EditorView?

    /// The editor is shown in place of the code view.
    var showsEditor = false {
        didSet { updateVisibility() }
    }

    func makeEditor(_ buffer: EditBuffer) -> EditorView {
        if let editor { return editor }
        let editor = EditorView(buffer: buffer)
        addSubview(editor, positioned: .above, relativeTo: codeView)
        self.editor = editor
        updateVisibility()
        needsLayout = true
        return editor
    }

    private func updateVisibility() {
        codeView.isHidden = showsEditor || message != nil
        messageLabel.isHidden = showsEditor || message == nil
        editor?.isHidden = !showsEditor
    }

    private(set) var sidebarWidth: CGFloat
    private(set) var sidebarHidden: Bool
    /// Where "sidebar hidden" is remembered. Nil: neither read nor written (snapshots, benchmarks, soaks).
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        let saved = UserDefaults.standard.double(forKey: Self.sidebarWidthKey)
        sidebarWidth = saved >= 160 ? CGFloat(saved) : Theme.defaultSidebarWidth
        sidebarHidden = defaults?.bool(forKey: Self.sidebarHiddenKey) ?? false
        self.defaults = defaults
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background
        messageLabel.isHidden = true
        for view in [sidebarTabs, tree, tabBar, codeView, messageLabel, titleLabel, titleLine, sidebarLine, resizeHandle] as [NSView] {
            addSubview(view)
        }
        resizeHandle.onDrag = { [weak self] x in self?.setSidebarWidth(x) }
        for view in sidebarViews { view.isHidden = sidebarHidden }
    }

    private var sidebarViews: [NSView] { [sidebarTabs, tree, resizeHandle, sidebarLine] }

    /// The view that takes the keyboard when the sidebar goes away.
    var mainResponder: NSView { showsEditor ? editor?.textView ?? codeView : codeView }

    func setSidebarHidden(_ hidden: Bool) {
        guard hidden != sidebarHidden else { return }
        sidebarHidden = hidden
        defaults?.set(hidden, forKey: Self.sidebarHiddenKey)
        for view in sidebarViews { view.isHidden = hidden }
        needsLayout = true
        layoutSubtreeIfNeeded()
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

    private func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(max(160, width.rounded()), max(160, bounds.width - 240))
    }

    private func setSidebarWidth(_ width: CGFloat) {
        let clamped = clampedSidebarWidth(width)
        guard clamped != sidebarWidth else { return }
        sidebarWidth = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.sidebarWidthKey)
        needsLayout = true
    }

    /// Sets the width like a drag would, without remembering it (for snapshots).
    func setSidebarWidthTemporarily(_ width: CGFloat) {
        sidebarWidth = clampedSidebarWidth(width)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let titleHeight = titleBarHeight
        let top = titleHeight + 1
        let height = max(0, bounds.height - top)
        let sidebar = sidebarHidden ? 0 : min(sidebarWidth, max(160, bounds.width - 240))
        let mainX = sidebarHidden ? 0 : sidebar + 1
        let mainWidth = max(0, bounds.width - mainX)
        let codeFrame = CGRect(x: mainX, y: top + Theme.tabBarHeight, width: mainWidth, height: max(0, height - Theme.tabBarHeight))

        if !sidebarHidden {
            sidebarTabs.frame = CGRect(x: 0, y: top, width: sidebar, height: Theme.tabBarHeight)
            tree.frame = CGRect(x: 0, y: top + Theme.tabBarHeight, width: sidebar, height: max(0, height - Theme.tabBarHeight))
            resizeHandle.frame = CGRect(x: sidebar - 2, y: top, width: 5, height: height)
            sidebarLine.frame = CGRect(x: sidebar, y: top, width: 1, height: height)
        }
        tabBar.frame = CGRect(x: mainX, y: top, width: mainWidth, height: Theme.tabBarHeight)
        codeView.frame = codeFrame
        editor?.frame = codeFrame
        titleLine.frame = CGRect(x: 0, y: titleHeight, width: bounds.width, height: 1)

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
    private let root: RootView
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
    /// How questions about unsaved edits are asked (tests answer them without a dialog).
    var prompts = Prompts.alerts
    /// Live windows ask the remotes where their branches are; snapshots, benchmarks and soaks never do.
    private var checksRemotes = false

    init(path: String, remote: RemoteMonitor = RemoteMonitor(), defaults: UserDefaults? = .standard) {
        root = RootView(defaults: defaults)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        workspace = Workspace(path: path, remote: remote)
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
        root.tabBar.onClose = { [weak self] index in self?.requestCloseTab(index) }
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

    /// Opens another folder in this window (after asking about unsaved edits).
    func open(path: String) {
        confirmUnsaved { [weak self] ok in
            if ok { self?.replaceWorkspace(path: path) }
        }
    }

    /// From now on this window (and the folders opened in it) checks its repositories against their remotes.
    func enableRemoteChecks() {
        checksRemotes = true
        startRemoteChecks()
    }

    private func startRemoteChecks() {
        workspace.remote.enable()
        workspace.remote.setVisible(window.occlusionState.contains(.visible))
    }

    private func replaceWorkspace(path: String) {
        workspace.remote.stop()
        workspace = Workspace(path: path)
        folderPath = Self.canonical(path)
        pendingFiles.removeAll()
        sidebarScroll.removeAll()
        connect(workspace)
        if checksRemotes { startRemoteChecks() }
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
        window.makeFirstResponder(root.sidebarHidden ? root.mainResponder : root.tree)
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
        let tabs = workspace.tabs.map {
            FileTab(title: $0.title, kind: $0.change?.kind, isPreview: $0.isPreview, isUnsaved: workspace.isUnsaved($0.path))
        }
        let mode = workspace.activeTab.map { workspace.tabs[$0].mode } ?? .diff
        root.tabBar.update(tabs: tabs, activeIndex: workspace.activeTab, mode: mode, canEdit: workspace.canEditActiveTab)
        let unsaved = workspace.hasUnsavedTabs
        if window.isDocumentEdited != unsaved { window.isDocumentEdited = unsaved }
        updateEditor(contentArrived: false)
    }

    /// Shows the open tab's buffer in the editor when it is in edit mode.
    ///
    /// Leaving edit mode, the editor's text stays on screen (read-only, not first responder) until what replaces it
    /// has arrived (`contentArrived`), so there is never a blank frame. Then the editor is hidden and lets go of the
    /// buffer. Once made, the editor stays with the window: making text views again and again leaves memory behind
    /// in AppKit that never comes back.
    private func updateEditor(contentArrived: Bool) {
        guard let buffer = workspace.activeBuffer else {
            guard let editor = root.editor, root.showsEditor else { return }
            editor.textView.isEditable = false
            if window.firstResponder === editor.textView { window.makeFirstResponder(root.codeView) }
            guard contentArrived else { return }
            root.showsEditor = false
            editor.detach()
            return
        }
        let isNew = root.editor == nil
        let editor = root.makeEditor(buffer)
        if isNew {
            editor.onTextChange = { [weak self] buffer in self?.workspace.textDidChange(in: buffer) }
            editor.onReload = { [weak self, weak editor] in
                if let path = editor?.buffer?.path { self?.workspace.reloadFromDisk(path) }
            }
            editor.onKeepMine = { [weak self, weak editor] in
                if let path = editor?.buffer?.path { self?.workspace.keepMine(path) }
            }
        }
        let shown = root.showsEditor && editor.buffer === buffer && editor.textView.isEditable
        editor.show(buffer)
        editor.textView.isEditable = true
        editor.conflict = buffer.session.conflict
        root.message = nil
        root.showsEditor = true
        if !shown {
            root.layoutSubtreeIfNeeded()
            if isNew { editor.restoreState() }
            window.makeFirstResponder(editor.textView)
        }
    }

    private func showContent(keepScroll: Bool) {
        updateEditor(contentArrived: true)
        root.tabBar.setCanEdit(workspace.canEditActiveTab)
        if workspace.activeBuffer != nil {
            // The hidden code view lets go of its document while the editor is up.
            root.codeView.setDocument(nil, keepScroll: false)
            return
        }
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard workspace.hasUnsavedTabs else { return true }
        confirmUnsaved { [weak self] ok in
            if ok { self?.window.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        workspace.remote.stop()
        // Lets the text system go before the views do.
        root.editor?.detach()
        onClose?(self)
    }

    // MARK: - Unsaved edits

    /// Saves one tab. A failure is shown to the user and returns false (the text stays).
    @discardableResult
    func save(_ path: String) -> Bool {
        do {
            try workspace.save(path)
            return true
        } catch {
            prompts.tell(error.message, window)
            return false
        }
    }

    /// Closes a tab, asking first when it has unsaved edits.
    func requestCloseTab(_ index: Int) {
        guard workspace.tabs.indices.contains(index) else { return }
        let tab = workspace.tabs[index]
        guard workspace.isUnsaved(tab.path) else { return workspace.closeTab(index) }
        prompts.ask(.closeTab(name: tab.title), window) { [weak self] answer in
            // The tab may have moved while the question was open.
            guard let self, let index = workspace.tabs.firstIndex(where: { $0.path == tab.path }) else { return }
            switch answer {
            case .save: if save(tab.path) { workspace.closeTab(index) }
            case .dontSave: workspace.closeTab(index)
            case .cancel: break
            }
        }
    }

    /// Before the window's tabs go away (closing the window, quitting, opening another folder): asks once about all
    /// unsaved tabs. `completion(true)` means go ahead.
    func confirmUnsaved(_ completion: @escaping (Bool) -> Void) {
        let paths = workspace.unsavedPaths
        guard !paths.isEmpty else { return completion(true) }
        prompts.ask(.closeWindow(fileCount: paths.count), window) { [weak self] answer in
            guard let self else { return completion(false) }
            switch answer {
            case .save: completion(workspace.unsavedPaths.allSatisfy { self.save($0) })
            case .dontSave: completion(true)
            case .cancel: completion(false)
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onBecomeKey?(self)
        workspace.remote.windowBecameKey()
    }

    /// Minimized, hidden or covered windows are not visible: the remote timer rests.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        workspace.remote.setVisible(window.occlusionState.contains(.visible))
    }

    // MARK: - Menu actions

    @objc func closeTab(_ sender: Any?) {
        if let active = workspace.activeTab {
            requestCloseTab(active)
        } else {
            window.performClose(sender)
        }
    }

    @objc func showChanges(_ sender: Any?) { showSidebar(.changes) }
    @objc func showFiles(_ sender: Any?) { showSidebar(.files) }

    private func showSidebar(_ tab: SidebarTab) {
        root.setSidebarHidden(false)
        selectSidebarTab(tab)
    }

    var sidebarHidden: Bool { root.sidebarHidden }

    /// `⌘B`. Everything that feeds the sidebar keeps running while it is hidden: only the views go.
    @objc func toggleSidebar(_ sender: Any?) {
        let hide = !root.sidebarHidden
        if hide, let focused = window.firstResponder as? NSView, focused.isDescendant(of: root.tree) {
            window.makeFirstResponder(root.mainResponder)
        }
        root.setSidebarHidden(hide)
    }

    /// `⌘D`, `⌘R`, `⌘E`: straight to a mode (the mode the tab is in already: nothing). A file that cannot be edited
    /// stays as it is, and `edit` is dimmed.
    @objc func showDiff(_ sender: Any?) { workspace.setMode(.diff) }
    @objc func showRead(_ sender: Any?) { workspace.setMode(.read) }
    @objc func showEdit(_ sender: Any?) {
        // Like a click on the word: a file known not to be editable is left alone, not read again.
        if workspace.canEditActiveTab { workspace.setMode(.edit) }
    }

    /// `⌘S`: saves the open tab when it has unsaved edits.
    @objc func saveDocument(_ sender: Any?) {
        guard let active = workspace.activeTab, workspace.isUnsaved(workspace.tabs[active].path) else { return }
        save(workspace.tabs[active].path)
    }

    @objc func refresh(_ sender: Any?) {
        workspace.refresh()
        workspace.remote.refresh()
    }

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
    func renderSnapshot(
        size: CGSize, sidebarTab: SidebarTab, open relativePaths: [String], mode: ViewMode?, scroll: CGFloat = 0, sidebarWidth: CGFloat? = nil,
        sidebarHidden: Bool = false
    ) -> Data? {
        window.setContentSize(size)
        root.layoutSubtreeIfNeeded()
        if sidebarHidden { root.setSidebarHidden(true) }
        if let sidebarWidth { root.setSidebarWidthTemporarily(sidebarWidth) }
        workspace.scanNow()
        for relativePath in relativePaths {
            let path = relativePath.hasPrefix("/") ? relativePath : workspace.rootPath + "/" + relativePath
            workspace.openFile(path, mode: mode ?? (sidebarTab == .changes ? .diff : .read), pin: true, synchronously: true)
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
