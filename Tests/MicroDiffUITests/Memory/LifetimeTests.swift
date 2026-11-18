import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

/// Objects go away when they should. A cycle (a closure holding its owner, a task holding the workspace)
/// keeps a whole window's worth of state alive: these check with weak references that it is gone.
extension UITests {
    @MainActor
    @Suite(.serialized)
    struct MemoryLifetimeTests {
        private func aliveNames(_ refs: [(String, WeakRef<AnyObject>)]) -> [String] {
            refs.filter { !$0.1.isGone }.map(\.0)
        }

        @Test("the window controller, its window, views and workspace are freed after teardown")
        func windowTeardown() async {
            let soak = SoakRepo()
            var refs: [(String, WeakRef<AnyObject>)] = []
            withPool {
                let controller = makeController(soak.path)
                let workspace = controller.workspace
                workspace.scanNow()
                workspace.openFile(soak.absolute("src/app.swift"), mode: .diff, pin: true, synchronously: true)
                workspace.openFile(soak.absolute("src/mid.swift"), mode: .file, pin: false, synchronously: true)
                controller.showFiles(nil)
                OffscreenPainter().paint(controller.rootView)
                let root = controller.rootView
                refs = [
                    ("controller", WeakRef(controller)), ("window", WeakRef(controller.window)), ("root", WeakRef(root)),
                    ("codeView", WeakRef(root.codeView)), ("tree", WeakRef(root.tree)), ("tabBar", WeakRef(root.tabBar)),
                    ("sidebarTabs", WeakRef(root.sidebarTabs)), ("workspace", WeakRef(workspace)),
                ]
            }
            #expect(refs.count == 8)
            let gone = await eventually { aliveNames(refs).isEmpty }
            #expect(gone, "still alive: \(aliveNames(refs))")
        }

        @Test("a workspace with a running watcher, a scan in flight and a rescan queued is freed when dropped")
        func workspaceWithWorkInFlight() async {
            let soak = SoakRepo()
            var workspace: Workspace? = Workspace(path: soak.path)
            workspace?.start()
            await waitIdle(workspace!)
            let workspaceRef = WeakRef(workspace)
            let watcherRef = WeakRef(storedProperty(workspace!, "watcher") as FSWatcher?)
            #expect(!watcherRef.isGone)
            // One scan starts, the second call queues a rescan behind it.
            workspace?.refresh()
            workspace?.refresh()
            workspace = nil
            let gone = await eventually { workspaceRef.isGone && watcherRef.isGone }
            #expect(gone, "workspace gone: \(workspaceRef.isGone), watcher gone: \(watcherRef.isGone)")
        }

        @Test("opening another folder in the window frees the previous workspace")
        func replacedWorkspace() async {
            let first = SoakRepo()
            let second = TestRepo()
            second.write("b.txt", "b\n")
            second.commitAll("b")
            let controller = makeController(first.path)
            controller.workspace.start()
            await waitIdle(controller.workspace)
            controller.workspace.openFile(first.absolute("src/app.swift"), mode: .diff, pin: true, synchronously: true)
            let old = WeakRef(controller.workspace)
            let oldWatcher = WeakRef(storedProperty(controller.workspace, "watcher") as FSWatcher?)
            #expect(!oldWatcher.isGone)

            controller.open(path: second.path)
            await waitIdle(controller.workspace)
            let gone = await eventually { old.isGone && oldWatcher.isGone }
            #expect(gone)
            #expect(controller.workspace.rootPath == second.path)
        }
    }
}
