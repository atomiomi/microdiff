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
    /// Entering edit mode failed while the file looked like this on disk (not UTF-8, for example). Until the file
    /// changes, `edit` is dimmed instead of reading the file again.
    var editBlockedAt: DiskObservation?
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
    /// Absolute path -> the text of a tab that is in edit mode, unsaved, or was edited (its undo history stays until the tab closes).
    private(set) var buffers: [String: EditBuffer] = [:]
    private(set) var content: DocumentContent?
    /// Path of the tab that `content` was loaded for.
    private var contentPath: String?

    var sidebarTab: SidebarTab = .changes

    var onSidebarChanged: (() -> Void)?
    var onTabsChanged: (() -> Void)?
    var onContentChanged: ((_ keepScroll: Bool) -> Void)?

    /// What there is to pull or push in the repositories; it only contacts a remote once enabled (live windows).
    let remote: RemoteMonitor

    private(set) var isScanning = false
    private var needsRescan = false
    private var scanStarted = ContinuousClock.now
    private(set) var loadGeneration = 0
    /// A background load for the current generation has not delivered yet.
    private(set) var isLoading = false

    init(path: String, remote: RemoteMonitor = RemoteMonitor()) {
        self.remote = remote
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        openedPath = standardized
        rootPath = standardized
        rootName = (standardized as NSString).lastPathComponent
        loader = DocumentLoader(scanner: scanner)
        fileTree = FileTree(rootPath: standardized, rootName: rootName)
        remote.onChange = { [weak self] in self?.onSidebarChanged?() }
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
        remote.update(repos: newSnapshot.allRepos)
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
                // A commit, a checkout or a new file: the base of the change bars may be another one now.
                buffers[tabs[index].path]?.marker?.setSource(markSource(tabs[index]))
            }
        }
        // Files may have appeared or gone even when git reports the same status.
        fileTree.invalidate()
        forgetVanishedFolders()
        let editsChanged = checkBuffersAgainstDisk()

        onSidebarChanged?()
        if changed || editsChanged { onTabsChanged?() }
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
        var rows: [TreeRow]
        switch sidebarTab {
        case .changes:
            rows = changesTree?.rows(collapsed: collapsed, listedQuiet: listedQuietRepos(snapshot)) ?? []
        case .files: rows = fileTree.rows(snapshot: snapshot)
        }
        let syncs = snapshot.allRepos.map(remote.sync(for:))
        guard syncs.contains(where: { $0 != nil }) else { return rows }
        for index in rows.indices where rows[index].kind == .repo && syncs.indices.contains(rows[index].repoIndex) {
            rows[index].sync = syncs[rows[index].repoIndex]
        }
        return rows
    }

    /// A repository without changes of its own is listed (as a header) while it has something to pull or push.
    private func listedQuietRepos(_ snapshot: WorkspaceSnapshot) -> Set<String> {
        Set(snapshot.quietRepos.filter { remote.sync(for: $0) != nil }.map(\.rootPath))
    }

    /// One quiet line for the empty states of the changes tab. "no changes" only when nothing but the main
    /// repository's row is listed: under rows of repositories to pull or push it would float in the empty space.
    var sidebarEmptyMessage: String? {
        guard sidebarTab == .changes, let snapshot else { return nil }
        if !snapshot.isGitRepo { return "not a git repository" }
        return snapshot.totalChangeCount == 0 && listedQuietRepos(snapshot).isEmpty ? "no changes" : nil
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
            // A header with nothing under it (a quiet nested repository) has nothing to fold, and its row comes and goes.
            if row.kind == .repo, row.repoIndex >= snapshot?.repos.count ?? 0 { return }
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
            openFile(rootPath + "/" + row.path, mode: EditByDefault.matches(fileName: row.name) ? .edit : .read, pin: pin)
        }
    }

    /// Opens a file in a tab. `mode` applies to a new tab; `.edit` opens it in the read view and then enters edit mode.
    func openFile(_ path: String, mode: ViewMode, pin: Bool, synchronously: Bool = false) {
        var isNew = false
        if let existing = tabs.firstIndex(where: { $0.path == path }) {
            if pin { tabs[existing].isPreview = false }
            activeTab = existing
        } else {
            isNew = true
            let info = changeIndex[path]
            let tab = OpenTab(
                path: path, title: (path as NSString).lastPathComponent,
                change: info?.change, repoIndex: info?.repoIndex, mode: mode == .edit ? .read : mode, isPreview: !pin)
            if !pin, let preview = tabs.firstIndex(where: \.isPreview) {
                dropBuffer(tabs[preview].path)
                tabs[preview] = tab
                activeTab = preview
            } else {
                tabs.append(tab)
                activeTab = tabs.count - 1
            }
        }
        onTabsChanged?()
        onSidebarChanged?()
        if isNew, mode == .edit {
            setMode(.edit, synchronously: synchronously)
            if activeTab.map({ tabs[$0].mode }) == .edit { return }
        }
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

    /// Closes a tab. Unsaved edits are thrown away: ask first (the window controller does).
    func closeTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let shownPath = activeTab.map { tabs[$0].path }
        dropBuffer(tabs[index].path)
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

    /// `synchronously`: entering edit mode computes the change bars right away (snapshots), not in the background.
    func setMode(_ mode: ViewMode, synchronously: Bool = false) {
        guard let activeTab, tabs[activeTab].mode != mode else { return }
        let path = tabs[activeTab].path
        let previous = tabs[activeTab].mode
        // The read view and the editor put every line at the same place: going between them keeps the scroll position.
        var scroll = CGPoint.zero
        if mode == .edit {
            guard let buffer = makeBuffer(activeTab) else {
                // Stays in its mode; the tab bar dims `edit`.
                onTabsChanged?()
                return
            }
            var shown: DiffDocument?
            if previous == .read, contentPath == path, case let .text(document)? = content, document.kind != .diff {
                buffer.scrollSpot = ScrollSpot(readViewOffset: tabs[activeTab].scroll)
                // The read view's marks are the editor's as long as the text is what is on disk.
                if document.kind == .file, !buffer.isUnsaved { shown = document.rows }
            }
            let marker = ChangeMarker(buffer: buffer, git: scanner.git, rows: shown)
            buffer.setMarker(marker)
            marker.setSource(markSource(tabs[activeTab]), synchronously: synchronously)
        } else if previous == .edit {
            if mode == .read { scroll = buffers[path]?.scrollSpot.readViewOffset ?? .zero }
            // The base text and the marks are only for edit mode, also when the buffer stays for its undo history.
            buffers[path]?.dropMarker()
        }
        tabs[activeTab].mode = mode
        tabs[activeTab].scroll = scroll
        if previous == .edit { releaseIdleBuffer(path) }
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

    // MARK: - Editing

    /// The buffer the editor shows: the open tab's, when it is in edit mode.
    var activeBuffer: EditBuffer? {
        guard let activeTab, tabs[activeTab].mode == .edit else { return nil }
        return buffers[tabs[activeTab].path]
    }

    func isUnsaved(_ path: String) -> Bool { buffers[path]?.isUnsaved ?? false }

    /// Paths of the tabs with unsaved edits, in tab order.
    var unsavedPaths: [String] { tabs.map(\.path).filter(isUnsaved) }

    var hasUnsavedTabs: Bool { buffers.values.contains { $0.isUnsaved } }

    /// Whether `edit` can be clicked for the open tab. Uses only what is already known (what the tab shows, an earlier
    /// failed try): switching tabs never reads a file. Whether it is UTF-8 is found out when edit mode is entered.
    var canEditActiveTab: Bool {
        guard let activeTab else { return false }
        let tab = tabs[activeTab]
        if tab.mode == .edit || buffers[tab.path] != nil { return true }
        if tab.change?.kind == .deleted { return false }
        if let blocked = tab.editBlockedAt, blocked == DiskObservation.observe(tab.path) ?? .missing { return false }
        guard contentPath == tab.path else { return true }
        switch content {
        case .message?: return false
        case let .text(document)?: return document.newText.byteCount <= EditFile.maxBytes
        case nil: return true
        }
    }

    /// Called by the editor after every change of a buffer's text.
    func textDidChange(in buffer: EditBuffer) {
        let wasUnsaved = buffer.isUnsaved
        buffer.noteTextChange()
        buffer.marker?.textDidChange()
        guard let index = tabs.firstIndex(where: { $0.path == buffer.path }) else { return }
        // Typing keeps a preview tab, like a double click.
        let pinned = tabs[index].isPreview
        tabs[index].isPreview = false
        if pinned || wasUnsaved != buffer.isUnsaved { onTabsChanged?() }
    }

    /// Writes a tab's text to its file. On failure the text stays as it is and the error says why.
    func save(_ path: String) throws(EditError) {
        guard let buffer = buffers[path] else { return }
        let text = buffer.storage.string
        let stamp = try EditFile.save(text, to: path, format: buffer.session.format)
        // Before the file watcher reports the write, so the app's own save is not taken for a change on disk.
        buffer.session.didSave(text: text, stamp: stamp)
        releaseIdleBuffer(path)
        onTabsChanged?()
        refresh()
    }

    /// The strip's "reload": the disk text replaces the unsaved edits.
    func reloadFromDisk(_ path: String) {
        guard let buffer = buffers[path], let text = buffer.session.reload() else { return }
        buffer.replaceText(text)
        onTabsChanged?()
    }

    /// The strip's "keep mine": the edits stay, the strip goes.
    func keepMine(_ path: String) {
        buffers[path]?.session.keepMine()
        onTabsChanged?()
    }

    private func makeBuffer(_ index: Int) -> EditBuffer? {
        let path = tabs[index].path
        if let buffer = buffers[path] { return buffer }
        let disk = DiskObservation.observe(path) ?? .missing
        guard let loaded = try? EditFile.load(path: path) else {
            tabs[index].editBlockedAt = disk
            return nil
        }
        tabs[index].editBlockedAt = nil
        let buffer = EditBuffer(path: path, loaded: loaded)
        buffers[path] = buffer
        return buffer
    }

    /// Lets go of a buffer that is no longer needed: its tab is not in edit mode, nothing is unsaved and it has no undo
    /// history. Once the text was changed, the history stays for as long as the tab is open, like in other editors.
    private func releaseIdleBuffer(_ path: String) {
        guard let buffer = buffers[path], !buffer.isUnsaved, !buffer.hasUndoHistory,
              tabs.first(where: { $0.path == path })?.mode != .edit else { return }
        dropBuffer(path)
    }

    private func dropBuffer(_ path: String) {
        buffers.removeValue(forKey: path)?.close()
    }

    /// Where the read view's base text for a tab comes from; nil when the read view shows no marks for it.
    private func markSource(_ tab: OpenTab) -> MarkSource? {
        guard let snapshot else { return nil }
        if let change = tab.change {
            guard let index = tab.repoIndex, snapshot.repos.indices.contains(index), snapshot.repos[index].hasHead,
                  !change.isUntracked, change.kind != .added else { return nil }
            return MarkSource(repoRoot: snapshot.repos[index].rootPath, headPath: change.oldPath ?? change.path)
        }
        // Unchanged: the repository it lies in (a file git does not track simply has no HEAD version).
        let repo = snapshot.allRepos.filter { tab.path.hasPrefix($0.rootPath + "/") }.max { $0.rootPath.count < $1.rootPath.count }
        guard let repo, repo.hasHead else { return nil }
        return MarkSource(repoRoot: repo.rootPath, headPath: String(tab.path.dropFirst(repo.rootPath.count + 1)))
    }

    /// After a scan: compares every buffer with its file. Returns true when a tab's look changed (dot, strip, mode).
    private func checkBuffersAgainstDisk() -> Bool {
        var changed = false
        for (path, buffer) in buffers {
            guard let disk = DiskObservation.observe(path) else { continue }
            let outcome = buffer.session.diskDidChange(
                disk, currentText: { buffer.storage.string }, readDisk: { try? EditFile.load(path: path) })
            switch outcome {
            case .nothing:
                break
            case let .reload(text):
                if tabs.first(where: { $0.path == path })?.mode == .edit {
                    buffer.replaceText(text)
                } else {
                    // Kept only for its undo history, which no longer fits the file.
                    dropBuffer(path)
                }
            case .becameClean, .conflict:
                changed = true
            case .fileDeleted:
                // Nothing unsaved and the file is gone: the tab shows it the way a missing or deleted file is shown.
                if let index = tabs.firstIndex(where: { $0.path == path }), tabs[index].mode == .edit {
                    tabs[index].mode = .diff
                    tabs[index].scroll = .zero
                }
                dropBuffer(path)
                changed = true
            }
        }
        return changed
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
        if tab.mode == .edit {
            // The editor shows the tab's buffer: nothing to load.
            content = nil
            contentPath = nil
            onContentChanged?(false)
            return
        }
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
