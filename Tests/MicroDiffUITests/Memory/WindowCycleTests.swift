import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

/// One app for all windows: a window that opens and closes all day must give everything back
/// (controller, views, workspace, watcher, the git and file work it started).
///
/// Budget: AppKit itself keeps a few hundred bytes per window ever made. Measured on macOS 26: a plain `NSWindow`
/// created and closed 240 times grows the live heap by 300-800 B per window, the app's window by about 800 B, a full
/// cycle here by about 900 B (`MICRODIFF_SOAK=10`). A leaked window (views, workspace, trees) is hundreds of KB, and
/// every closed window is also checked with a weak reference.
extension IsolatedMemory {
    @MainActor
    @Suite(.serialized)
    struct WindowCycle {
        private let n = MemoryEnv.soak

        /// Waits until the window's scan and file are in, paints it, closes it. Returns a weak reference only,
        /// so nothing here keeps the window alive afterwards.
        private func finishAndClose(_ current: WeakRef<MainWindowController>, _ painter: OffscreenPainter) async -> WeakRef<MainWindowController>? {
            guard let window = current.object else { return nil }
            _ = await waitUntil { !window.workspace.tabs.isEmpty && !window.workspace.isScanning && !window.workspace.isLoading }
            painter.paint(window.rootView)
            withPool { window.window.close() }
            return WeakRef(window)
        }

        @Test("windows: open a folder in a new window (scan, watcher, a file tab), paint, close it")
        func openAndCloseWindows() async throws {
            let soak = SoakRepo()
            let other = SoakRepo()
            let manager = WindowManager(showsWindows: false)
            manager.markReady()
            // The first window stays open the whole time, like in the app.
            var first: MainWindowController?
            manager.open(folder: other.path) { if case let .opened(controller) = $0 { first = controller } }
            let staying = try #require(first)
            await waitIdle(staying.workspace)
            let painter = OffscreenPainter()
            // Weak: the window manager is what keeps an open window alive, nothing in this test.
            let current = WeakRef<MainWindowController>(nil)
            var closed: WeakRef<MainWindowController>?
            var lingering = 0
            let before = ResourceCounts.now()

            let report = await measureSteadyState(
                "windows", warmup: 30, perRound: 10 * n, heapBudget: 2048,
                flush: { TextCache.shared.removeAll() },
                settle: { await waitIdle(staying.workspace) },
                step: { _ in
                    manager.open(folder: soak.path, files: [soak.absolute("src/app.swift")]) { result in
                        if case let .opened(controller) = result { current.object = controller }
                    }
                },
                wait: {
                    guard let ref = await finishAndClose(current, painter) else { return }
                    closed = ref
                    if !(await eventually { ref.isGone }) { lingering += 1 }
                })
            #expect(lingering == 0, "\(lingering) closed windows stayed alive")
            #expect(manager.controllers.count == 1)
            #expect(closed?.isGone ?? false, "the last closed window is still alive")
            #expect(report.holds(footprintMB: 3))
            #expect(await ResourceCounts.settle(to: before).holds())
        }
    }
}
