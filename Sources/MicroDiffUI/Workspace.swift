import AppKit
import MicroDiffCore

/// One open file tab.
struct OpenTab {
    /// Absolute path. A file is open in at most one tab.
    var path: String
    var title: String
    var change: FileChange?
    /// Index into the snapshot's repos of the repository the change belongs to.
    var repoIndex: Int?
    var mode: ViewMode
    /// A preview tab is reused by the next single-clicked file.
    var isPreview: Bool
    var expandedFolds: Set<Int> = []
    var scroll: CGPoint = .zero
}

/// The state of one opened folder: git snapshot, sidebar trees, tabs and the loaded document.
/// Git and file work runs off the main thread; everything here is touched on the main thread only.
final class Workspace {
    private(set) var rootPath: String
    private(set) var rootName: String
    private let openedPath: String
    private let scanner = RepoScanner()
    private let loader: DocumentLoader
    private var watcher: FSWatcher?

    /// Nil until the first scan finished.
    private(set) var snapshot: WorkspaceSnapshot?
    private var changesTree: ChangesTree?
    private var fileTree: FileTree
    private var collapsed: Set<String> = []
    /// Absolute path -> the change of that file.
    private var changeIndex: [String: (repoIndex: Int, change: FileChange)] = [:]

    private(set) var tabs: [OpenTab] = []
    private(set) var activeTab: Int?
    private(set) var content: DocumentContent?
    /// Path of the tab that `content` was loaded for.
    private var contentPath: String?

    var sidebarTab: SidebarTab = .changes

    var onSidebarChanged: (() -> Void)?
    var onTabsChanged: (() -> Void)?
    var onContentChanged: ((_ keepScroll: Bool) -> Void)?

    private(set) var isScanning = false
    private var needsRescan = false
    private var scanStarted = ContinuousClock.now
    private var loadGeneration = 0
    /// A background load for the current generation has not delivered yet.
    private(set) var isLoading = false

    init(path: String) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        openedPath = standardized
        rootPath = standardized
        rootName = (standardized as NSString).lastPathComponent
        loader = DocumentLoader(scanner: scanner)
        fileTree = FileTree(rootPath: standardized, rootName: rootName)
    }

    // MARK: - Scanning

    /// Scans in the background and keeps watching the folder for changes.
    /// `prescan` is a scan that was started earlier (at process start): its result is used instead of scanning again.
    func start(prescan: BackgroundScan? = nil) {
        guard let prescan else {
            refresh()
            return
        }
        // Usually done long before the window exists; then the very first frame has content.
        if let ready = prescan.wait(timeout: 0.03) {
            apply(ready, watch: true)
            return
        }
        isScanning = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { prescan.waitUntilDone() }.value
            self?.apply(result, watch: true)
        }
    }

    /// Scans right now on the calling thread (used for snapshots and benchmarks).
    func scanNow() {
        apply(scanner.scan(root: scanner.resolveRoot(for: openedPath).root), watch: false)
    }

    func refresh() {
        guard !isScanning else {
            needsRescan = true
            return
        }
        isScanning = true
        scanStarted = .now
        let scanner = scanner
        let path = openedPath
        let knownRoot = snapshot == nil ? nil : rootPath
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                scanner.scan(root: knownRoot ?? scanner.resolveRoot(for: path).root)
            }.value
            self?.apply(result, watch: true)
        }
    }

    private func apply(_ newSnapshot: WorkspaceSnapshot, watch: Bool) {
        isScanning = false
        if snapshot == nil || newSnapshot.rootPath != rootPath {
            rootPath = newSnapshot.rootPath
            rootName = (rootPath as NSString).lastPathComponent
            fileTree = FileTree(rootPath: rootPath, rootName: rootName)
            // A watcher on the old root is of no use.
            watcher?.stop()
            watcher = nil
        }
        if watch, watcher == nil { startWatching() }

        let changed = newSnapshot != snapshot
        snapshot = newSnapshot
        if changed {
            changesTree = ChangesTree(snapshot: newSnapshot)
            changeIndex.removeAll(keepingCapacity: true)
            for (repoIndex, repo) in newSnapshot.repos.enumerated() {
                for change in repo.changes {
                    changeIndex[repo.rootPath + "/" + change.path] = (repoIndex, change)
                }
            }
            for index in tabs.indices {
                let info = changeIndex[tabs[index].path]
                tabs[index].change = info?.change
                tabs[index].repoIndex = info?.repoIndex
            }
        }
        // Files may have appeared or gone even when git reports the same status.
        fileTree.invalidate()
        forgetVanishedFolders()

        onSidebarChanged?()
        if changed { onTabsChanged?() }
        if activeTab != nil { loadContent(keepScroll: true) }

        if needsRescan {
            needsRescan = false
            // Something changed while scanning. Scan again, but leave room to breathe: when files change
            // non-stop (a build, an install) the app must not run git back to back. Slow repos wait longer.
            let lastScan = ContinuousClock.now - scanStarted
            let pause = max(.milliseconds(250), lastScan * 2)
            isScanning = true
            Task { [weak self] in
                try? await Task.sleep(for: pause)
                guard let self else { return }
                // Requests that arrived during the pause are covered by the scan that starts now.
                isScanning = false
                needsRescan = false
                refresh()
            }
        }
    }

    /// Above this many remembered folders, the ones that are gone are forgotten.
    static let folderStateLimit = 256

    /// Open/closed folders are remembered by path. Over days of branch switches the paths of folders that no
    /// longer exist would pile up: past a limit, keep only the ones still there. Below it, a folder that
    /// disappears for a moment (a checkout) keeps its state.
    private func forgetVanishedFolders() {
        if collapsed.count > Self.folderStateLimit {
            let present = Set((changesTree?.rows() ?? []).map(\.id))
            collapsed.formIntersection(present)
        }
        if fileTree.expanded.count > Self.folderStateLimit {
            for path in fileTree.expanded where !path.isEmpty {
                var isDirectory: ObjCBool = false
                if !FileManager.default.fileExists(atPath: rootPath + "/" + path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                    fileTree.setExpanded(false, path: path)
                }
            }
        }
    }

    private func startWatching() {
        let watcher = FSWatcher(path: rootPath) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        watcher.start()
        self.watcher = watcher
    }

    // MARK: - Sidebar

    func sidebarRows() -> [TreeRow] {
        guard let snapshot else { return [] }
        switch sidebarTab {
        case .changes: return changesTree?.rows(collapsed: collapsed) ?? []
        case .files: return fileTree.rows(snapshot: snapshot)
        }
    }

    /// One quiet line for the empty states of the changes tab.
    var sidebarEmptyMessage: String? {
        guard sidebarTab == .changes, let snapshot else { return nil }
        if !snapshot.isGitRepo { return "not a git repository" }
        return snapshot.totalChangeCount == 0 ? "no changes" : nil
    }

    /// The sidebar row of the active tab's file, in the current sidebar tab.
    var selectedRowID: String? {
        guard let activeTab else { return nil }
        let tab = tabs[activeTab]
        switch sidebarTab {
        case .changes:
            guard let change = tab.change, let repoIndex = tab.repoIndex else { return nil }
            return TreeRow.makeID(repoIndex: repoIndex, kind: .file, path: change.path)
        case .files:
            return relativePath(tab.path).map { TreeRow.makeID(repoIndex: 0, kind: .file, path: $0) }
        }
    }

    private func relativePath(_ absolute: String) -> String? {
        absolute.hasPrefix(rootPath + "/") ? String(absolute.dropFirst(rootPath.count + 1)) : nil
    }

    func toggle(_ row: TreeRow) {
        switch sidebarTab {
        case .changes:
            if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
        case .files:
            fileTree.setExpanded(!row.isExpanded, path: row.path)
        }
        onSidebarChanged?()
    }

    func selectSidebarTab(_ tab: SidebarTab) {
        guard tab != sidebarTab else { return }
        sidebarTab = tab
        if tab == .files, let activeTab, let relative = relativePath(tabs[activeTab].path) {
            // Open the folders above the active file so its row can be shown selected.
            fileTree.reveal(path: relative)
        }
        onSidebarChanged?()
    }

    // MARK: - Tabs

    func open(_ row: TreeRow, pin: Bool) {
        guard row.kind == .file, let snapshot else { return }
        switch sidebarTab {
        case .changes:
            guard let change = row.change, snapshot.repos.indices.contains(row.repoIndex) else { return }
            openFile(snapshot.repos[row.repoIndex].rootPath + "/" + change.path, mode: .diff, pin: pin)
        case .files:
            openFile(rootPath + "/" + row.path, mode: .file, pin: pin)
        }
    }

    func openFile(_ path: String, mode: ViewMode, pin: Bool, synchronously: Bool = false) {
        if let existing = tabs.firstIndex(where: { $0.path == path }) {
            if pin { tabs[existing].isPreview = false }
            activeTab = existing
        } else {
            let info = changeIndex[path]
            let tab = OpenTab(
                path: path, title: (path as NSString).lastPathComponent,
                change: info?.change, repoIndex: info?.repoIndex, mode: mode, isPreview: !pin)
            if !pin, let preview = tabs.firstIndex(where: \.isPreview) {
                tabs[preview] = tab
                activeTab = preview
            } else {
                tabs.append(tab)
                activeTab = tabs.count - 1
            }
        }
        onTabsChanged?()
        onSidebarChanged?()
        loadContent(keepScroll: false, synchronously: synchronously)
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index), index != activeTab else { return }
        activeTab = index
        onTabsChanged?()
        onSidebarChanged?()
        loadContent(keepScroll: false)
    }

    func pinTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].isPreview = false
        if index != activeTab {
            selectTab(index)
        } else {
            onTabsChanged?()
        }
    }

    func closeTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let shownPath = activeTab.map { tabs[$0].path }
        tabs.remove(at: index)
        if let active = activeTab {
            if tabs.isEmpty {
                activeTab = nil
            } else if index < active || (index == active && active >= tabs.count) {
                activeTab = active - 1
            }
        }
        onTabsChanged?()
        onSidebarChanged?()
        // Closing a background tab must not disturb the document on screen (its scroll position, a selection).
        if activeTab.map({ tabs[$0].path }) != shownPath {
            loadContent(keepScroll: false)
        }
    }

    func closeActiveTab() {
        if let activeTab { closeTab(activeTab) }
    }

    func setMode(_ mode: ViewMode) {
        guard let activeTab, tabs[activeTab].mode != mode else { return }
        tabs[activeTab].mode = mode
        tabs[activeTab].scroll = .zero
        onTabsChanged?()
        loadContent(keepScroll: false)
    }

    func expandFold(startingAt line: Int) {
        guard let activeTab, case let .text(document)? = content, document.kind == .diff else { return }
        tabs[activeTab].expandedFolds.insert(line)
        content = .text(document.withExpandedFolds(tabs[activeTab].expandedFolds))
        onContentChanged?(true)
        // A reload that started before this click does not know about it and would close the fold again:
        // replace it with one that does.
        if isLoading { loadContent(keepScroll: true) }
    }

    func rememberScroll(_ offset: CGPoint) {
        // Ignore scroll positions of a document that belongs to another tab (while a tab switch is loading).
        guard let activeTab, tabs[activeTab].path == contentPath else { return }
        tabs[activeTab].scroll = offset
    }

    var activeScroll: CGPoint {
        activeTab.map { tabs[$0].scroll } ?? .zero
    }

    // MARK: - Loading

    private func loadContent(keepScroll: Bool, synchronously: Bool = false) {
        loadGeneration += 1
        isLoading = false
        guard let activeTab else {
            content = nil
            contentPath = nil
            onContentChanged?(false)
            return
        }
        let tab = tabs[activeTab]
        let repo = tab.repoIndex.flatMap { index in snapshot.flatMap { $0.repos.indices.contains(index) ? $0.repos[index] : nil } }
        let request = DocumentRequest(
            path: tab.path, repo: repo, change: tab.change, mode: tab.mode, expandedFolds: tab.expandedFolds, metrics: Theme.rowMetrics)
        let generation = loadGeneration

        if synchronously {
            finishLoad(loader.load(request), generation: generation, path: tab.path, keepScroll: keepScroll)
            return
        }
        let loader = loader
        isLoading = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { loader.load(request) }.value
            self?.finishLoad(result, generation: generation, path: tab.path, keepScroll: keepScroll)
        }
    }

    private func finishLoad(_ result: DocumentContent, generation: Int, path: String, keepScroll: Bool) {
        // A newer load was started meanwhile: drop this one.
        guard generation == loadGeneration else { return }
        isLoading = false
        let sameTab = contentPath == path
        if keepScroll, sameTab, let content, Self.isSame(content, result) { return }
        content = result
        contentPath = path
        onContentChanged?(keepScroll && sameTab)
    }

    /// True when a reload produced exactly what is already on screen, so the view can be left alone.
    private static func isSame(_ a: DocumentContent, _ b: DocumentContent) -> Bool {
        switch (a, b) {
        case let (.message(x), .message(y)):
            return x == y
        case let (.text(x), .text(y)):
            return x.kind == y.kind && x.rows.rowCount == y.rows.rowCount && x.patch.hunks == y.patch.hunks
                && x.newText.data == y.newText.data && x.oldText.data == y.oldText.data
        default:
            return false
        }
    }
}
