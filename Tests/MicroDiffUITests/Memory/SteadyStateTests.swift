import CoreGraphics
import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

/// Tests that measure the whole process (live heap, footprint, file descriptors, threads). They only mean something
/// when nothing else runs, so `scripts/test.sh` runs them in a second pass of their own (MICRODIFF_ISOLATED=1),
/// one at a time. `MICRODIFF_SOAK=<n>` makes them n times longer.
@Suite(.serialized, .enabled(if: MemoryEnv.isolated, "process-wide numbers: scripts/test.sh runs these in a pass of their own"))
enum IsolatedMemory {}

/// The window never closes. Whatever the user does all day must leave memory where it was:
/// warm up, repeat an activity many times, and the live heap must not keep growing.
///
/// Budgets: the live heap slope must stay under a few hundred bytes per iteration. Measured noise is far
/// below that (see the MEM lines), and a real leak of an object or a string per iteration is caught.
/// The footprint (what Activity Monitor shows) gets a looser total budget: it moves in 16 KB pages.
extension IsolatedMemory {
    @MainActor
    @Suite(.serialized)
    struct SteadyState {
        private let n = MemoryEnv.soak

        @Test("rescans: git runs, parsing, tree rebuilds and reloading the open file")
        func rescans() async {
            let soak = SoakRepo()
            let controller = makeController(soak.path)
            let workspace = controller.workspace
            workspace.scanNow()
            workspace.openFile(soak.absolute("notes.txt"), mode: .diff, pin: true, synchronously: true)
            workspace.openFile(soak.absolute("src/app.swift"), mode: .diff, pin: true, synchronously: true)
            let painter = OffscreenPainter()
            let before = ResourceCounts.now()

            let report = await measureSteadyState(
                "rescan", warmup: 20, perRound: 12 * n, heapBudget: 512,
                flush: { TextCache.shared.removeAll() },
                settle: { await waitIdle(workspace) },
                step: { i in
                    // Something changes every time, so trees, the change index and the tab really get rebuilt.
                    soak.repo.write("notes.txt", i % 2 == 0 ? "one\ntwo\n" : "one\n")
                    soak.repo.write("src/app.swift", SoakRepo.swiftSource(lines: 400, salt: 1 + i % 3))
                    if i % 2 == 0 { soak.repo.write("tmp/new\(i % 4).txt", "x\n") } else { soak.repo.remove("tmp") }
                    workspace.scanNow()
                },
                wait: {
                    await waitIdle(workspace)
                    painter.paint(controller.rootView)
                })
            #expect(report.holds(footprintMB: 2))
            #expect(await ResourceCounts.settle(to: before).holds())
        }

        @Test("tabs: open, preview replaced, switch, diff/read toggle, folds, close")
        func tabs() async throws {
            let soak = SoakRepo()
            let controller = makeController(soak.path)
            let workspace = controller.workspace
            workspace.scanNow()
            let painter = OffscreenPainter()
            let app = soak.absolute("src/app.swift")
            let notes = soak.absolute("notes.txt")
            let mid = soak.absolute("src/mid.swift")

            func fold() -> Int? {
                guard case let .text(document)? = workspace.content else { return nil }
                return (0..<document.rows.rowCount).lazy.map { document.rows.row(at: $0) }.first { $0.kind == .fold }?.line
            }
            let steps: [() -> Void] = [
                { workspace.openFile(app, mode: .diff, pin: false) },
                { workspace.openFile(notes, mode: .diff, pin: false) }, // replaces the preview
                { workspace.openFile(mid, mode: .read, pin: true) },
                { workspace.openFile(app, mode: .diff, pin: true) },
                { if let line = fold() { workspace.expandFold(startingAt: line) } },
                { workspace.setMode(.read) },
                { controller.rootView.codeView.scroll(to: CGPoint(x: 0, y: 3000)) },
                { workspace.setMode(.diff) },
                { workspace.selectTab(0) },
                { controller.nextTab(nil) },
                { controller.showRead(nil) },
                { while !workspace.tabs.isEmpty { workspace.closeActiveTab() } },
            ]

            // One-time costs here level off slowly (about 60 KB over the first ~300 steps, flat for 2000 after it
            // in a 15x soak): a longer warm-up.
            let report = await measureSteadyState(
                "tabs", warmup: steps.count * 12, perRound: steps.count * 3 * n, heapBudget: 256,
                flush: { TextCache.shared.removeAll() },
                settle: { await waitIdle(workspace) },
                step: { i in steps[i % steps.count]() },
                wait: {
                    await waitIdle(workspace)
                    painter.paint(controller.rootView)
                })
            #expect(report.holds(footprintMB: 2))
        }

        @Test("editing: enter edit mode, type, undo, save, leave, switch tabs")
        func editing() async throws {
            let soak = SoakRepo()
            let controller = makeController(soak.path)
            let workspace = controller.workspace
            workspace.scanNow()
            let painter = OffscreenPainter()
            let app = soak.absolute("src/app.swift")
            let mid = soak.absolute("src/mid.swift")
            let original = try #require(fileText(app))

            let steps: [() -> Void] = [
                { workspace.openFile(app, mode: .read, pin: true) },
                { controller.showEdit(nil) },
                { controller.setCaret(0); controller.type("// typed\n") },
                { controller.undo() },
                { controller.setCaret(0); controller.type("// saved\n") },
                { controller.saveDocument(nil) },
                { controller.setCaret(0, length: 9); controller.deleteBackward() },
                { controller.saveDocument(nil) },
                { controller.scrollEditor(toLine: 300) },
                { workspace.openFile(mid, mode: .read, pin: true) },
                { controller.showEdit(nil) },
                { controller.setCaret(100); controller.type("x") },
                { workspace.selectTab(0) },
                { controller.showRead(nil) },
                { workspace.selectTab(1) },
                { controller.deleteBackward() },
                { controller.showRead(nil) },
            ]

            let report = await measureSteadyState(
                "editing", warmup: steps.count * 6, perRound: steps.count * 3 * n, heapBudget: 512,
                flush: { TextCache.shared.removeAll() },
                settle: { await waitIdle(workspace) },
                step: { i in steps[i % steps.count]() },
                wait: {
                    await waitIdle(workspace)
                    await turnRunLoop()
                    painter.paint(controller.rootView)
                })
            #expect(fileText(app) == original)
            #expect(workspace.buffers.count == 2, "both tabs were edited: they keep their undo history, nothing more")
            #expect(controller.editorIsIdle)
            #expect(report.holds(footprintMB: 2))
        }

        @Test("scrolling a long file (line layout caches fill and empty again)")
        func scrolling() async throws {
            let soak = SoakRepo()
            // A smaller window: fewer rows per frame, the same churn through the caches.
            let controller = makeController(soak.path, width: 800, height: 400)
            let workspace = controller.workspace
            workspace.scanNow()
            workspace.openFile(soak.absolute("src/big.swift"), mode: .read, pin: true, synchronously: true)
            let codeView = controller.rootView.codeView
            let document = try #require(workspace.content?.document)
            let painter = OffscreenPainter()
            painter.paint(codeView)
            let height = Double(document.rows.contentHeight)
            let page = Double(codeView.visibleContentRect.height)
            #expect(height > page * 100)

            let report = await measureSteadyState(
                "scroll", warmup: 120, perRound: 40 * n, heapBudget: 256,
                flush: {
                    // Both line caches are bounded on purpose; empty them so every sample sees them alike.
                    TextCache.shared.removeAll()
                    codeView.setDocument(document, keepScroll: true)
                },
                step: { i in
                    // Jumps around the whole file: a different page almost every time.
                    let y = (Double(i) * page * 7.3).truncatingRemainder(dividingBy: height - page)
                    codeView.scroll(to: CGPoint(x: 0, y: y))
                    painter.paint(codeView)
                })
            #expect(report.holds(footprintMB: 2))
        }

        @Test("sidebar: changes/files switch, folders open and close, window resizes")
        func sidebar() async throws {
            let soak = SoakRepo()
            let controller = makeController(soak.path)
            let workspace = controller.workspace
            workspace.scanNow()
            workspace.openFile(soak.absolute("src/app.swift"), mode: .diff, pin: true, synchronously: true)
            let painter = OffscreenPainter()

            func toggle(_ path: String) {
                if let row = workspace.sidebarRows().first(where: { $0.kind == .directory && $0.path == path }) {
                    workspace.toggle(row)
                }
            }
            var folder = 0
            let steps: [() -> Void] = [
                { controller.showFiles(nil) },
                { toggle("pkg") },
                { folder = (folder + 1) % 12; toggle("pkg/m\(folder)") },
                { toggle("pkg/m\(folder)/sub") },
                { toggle("pkg/m\(folder)/sub") },
                { toggle("pkg/m\(folder)") },
                { toggle("pkg") },
                { controller.showChanges(nil) },
                { toggle("src") },
                { toggle("src") },
                { controller.resize(width: 900, height: 560) },
                { controller.resize(width: 1180, height: 720) },
            ]

            let report = await measureSteadyState(
                "sidebar", warmup: steps.count * 3, perRound: steps.count * 6 * n, heapBudget: 256,
                flush: { TextCache.shared.removeAll() },
                step: { i in steps[i % steps.count]() },
                wait: { painter.paint(controller.rootView) })
            #expect(report.holds(footprintMB: 2))
        }

        @Test("the repository changes under the window: branch switch, bulk add/delete, a submodule comes and goes")
        func repositoryChurn() async throws {
            let soak = SoakRepo()
            let library = TestRepo()
            library.write("lib.c", "int lib(void) { return 1; }\n")
            library.commitAll("lib")
            // A branch with 40 more files, a folder fewer and a submodule.
            soak.repo.git("checkout", "-q", "-b", "feature")
            for k in 0..<40 { soak.repo.write("feature/f\(k).txt", "feature \(k)\n") }
            soak.repo.remove("pkg/m0")
            soak.repo.addSubmodule(from: library, at: "vendor/lib")
            soak.repo.commitAll("feature")
            // Untracked content inside the submodule: the scanner then scans it as a repository of its own.
            soak.repo.write("vendor/lib/scratch.txt", "dirty\n")
            soak.repo.git("checkout", "-q", "main")

            let controller = makeController(soak.path)
            let workspace = controller.workspace
            workspace.scanNow()
            workspace.openFile(soak.absolute("src/app.swift"), mode: .diff, pin: true, synchronously: true)
            let painter = OffscreenPainter()
            var switches = 0

            let report = await measureSteadyState(
                "repo-churn", warmup: 6, rounds: 5, perRound: 5 * n, heapBudget: 2048,
                flush: { TextCache.shared.removeAll() },
                settle: { await waitIdle(workspace) },
                step: { i in
                    if i % 2 == 0 {
                        if soak.repo.tryGit("checkout", "-q", "feature") { switches += 1 }
                        for k in 0..<60 { soak.repo.write("bulk/b\(k).txt", "\(k)\n") }
                    } else {
                        if soak.repo.tryGit("checkout", "-q", "main") { switches += 1 }
                        soak.repo.remove("bulk")
                    }
                    workspace.scanNow()
                },
                wait: {
                    await waitIdle(workspace)
                    painter.paint(controller.rootView)
                })
            #expect(switches > report.measuredIterations)
            // Fewer, much bigger iterations (a git checkout, ~100 files, submodule scans): a looser slope budget.
            #expect(report.holds(footprintMB: 3))
        }
    }
}
