import AppKit
import MicroDiffCore

/// `--soak <n>`: drives the real window through a day's worth of activity n times, offscreen, then quits.
/// Used by `scripts/leaks.sh` under the `leaks` tool. The window is never shown and the app never activates.
@MainActor
enum Soak {
    static func run(_ controller: MainWindowController, iterations: Int) {
        Task { @MainActor in
            print(await drive(controller, iterations: iterations))
            exit(0)
        }
    }

    /// Runs the activity `iterations` times and returns the summary line. Progress lines are printed on the way.
    static func drive(_ controller: MainWindowController, iterations: Int) async -> String {
        do {
            let workspace = controller.workspace
            let root = controller.window.contentView ?? NSView()
            var reps: [String: NSBitmapImageRep] = [:]
            @MainActor func paint() {
                root.layoutSubtreeIfNeeded()
                let key = "\(Int(root.bounds.width))x\(Int(root.bounds.height))"
                if reps[key] == nil { reps[key] = root.bitmapImageRepForCachingDisplay(in: root.bounds) }
                if let rep = reps[key] { root.cacheDisplay(in: root.bounds, to: rep) }
            }
            @MainActor func idle() async {
                while isBusy(workspace) {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                paint()
            }

            // The real start: background scan and the file watcher.
            workspace.start()
            await idle()
            let heapStart = MemoryProbe.liveHeapBytes()
            let footprintStart = ProcessMetrics.footprintBytes()

            for i in 0..<iterations {
                let changed = (workspace.snapshot?.repos ?? []).flatMap { repo in
                    repo.changes.prefix(4).map { repo.rootPath + "/" + $0.path }
                }
                let steps: [() -> Void] = [
                    { workspace.refresh() },
                    { if let path = changed.first { workspace.openFile(path, mode: .diff, pin: false) } },
                    { if changed.count > 1 { workspace.openFile(changed[1], mode: .diff, pin: true) } },
                    { if changed.count > 2 { workspace.openFile(changed[2], mode: .file, pin: false) } },
                    { controller.toggleDiffFile(nil) },
                    { expandFirstFold(workspace) },
                    { scroll(controller, by: 5) },
                    { controller.nextTab(nil) },
                    { controller.showFiles(nil) },
                    { toggleFirstFolder(workspace) },
                    { toggleFirstFolder(workspace) },
                    { controller.showChanges(nil) },
                    { controller.window.setContentSize(i % 2 == 0 ? NSSize(width: 900, height: 560) : NSSize(width: 1180, height: 720)) },
                    { if i % 5 == 4 { while !workspace.tabs.isEmpty { workspace.closeActiveTab() } } },
                ]
                for step in steps {
                    autoreleasepool { step() }
                    await idle()
                }
                // Tabs were just closed: a comparable moment. Ten progress lines per run.
                if i % 5 == 4, (i + 1) % max(5, iterations / 10 / 5 * 5) == 0 {
                    TextCache.shared.removeAll()
                    MemoryProbe.relieve()
                    print("SOAK progress iteration=\(i + 1) heap_kb=\(MemoryProbe.liveHeapBytes() / 1024)")
                }
            }
            while !workspace.tabs.isEmpty { workspace.closeActiveTab() }
            await idle()
            TextCache.shared.removeAll()
            MemoryProbe.relieve()
            return String(
                format: "SOAK iterations=%d heap_start_kb=%d heap_end_kb=%d footprint_start_mb=%.1f footprint_end_mb=%.1f fds=%d threads=%d",
                iterations, heapStart / 1024, MemoryProbe.liveHeapBytes() / 1024, Double(footprintStart) / 1_048_576,
                Double(ProcessMetrics.footprintBytes()) / 1_048_576, MemoryProbe.openFileDescriptorCount(), MemoryProbe.threadCount())
        }
    }

    private static func isBusy(_ workspace: Workspace) -> Bool {
        workspace.isScanning || workspace.isLoading
    }

    private static func expandFirstFold(_ workspace: Workspace) {
        guard case let .text(document)? = workspace.content, document.kind == .diff else { return }
        for index in 0..<document.rows.rowCount where document.rows.row(at: index).kind == .fold {
            workspace.expandFold(startingAt: document.rows.row(at: index).line)
            return
        }
    }

    private static func toggleFirstFolder(_ workspace: Workspace) {
        if let row = workspace.sidebarRows().first(where: { $0.kind == .directory }) { workspace.toggle(row) }
    }

    private static func scroll(_ controller: MainWindowController, by pages: Int) {
        guard let root = controller.window.contentView as? RootView else { return }
        let view = root.codeView
        for _ in 0..<pages {
            view.scroll(by: CGPoint(x: 0, y: max(100, view.visibleContentRect.height - 40)))
        }
    }
}
