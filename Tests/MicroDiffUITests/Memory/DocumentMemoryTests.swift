import CoreGraphics
import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

/// Documents are value types (no weak references possible), so their lifetime is checked by the live heap:
/// open a big file and the heap grows by about its size; close, replace or reload it and that memory is back.
extension IsolatedMemory {
    @MainActor
    @Suite(.serialized)
    struct Documents {
        private static let megabytes = 6
        private static let size = megabytes * 1_048_576
        /// What may stay behind after a document went away (caches, the tab title, allocator slack).
        private static let slack = 512 * 1024

        private func setUp() -> (SoakRepo, MainWindowController, OffscreenPainter) {
            let soak = SoakRepo()
            writeBigFile(soak.repo, "huge.txt", megabytes: Self.megabytes)
            let controller = makeController(soak.path)
            controller.workspace.scanNow()
            let painter = OffscreenPainter()
            // Warm up: the paths below run once before measuring.
            controller.workspace.openFile(soak.absolute("notes.txt"), mode: .read, pin: true, synchronously: true)
            painter.paint(controller.rootView)
            controller.workspace.closeActiveTab()
            return (soak, controller, painter)
        }

        @Test("a closed tab's document is freed")
        func closedTab() async {
            let (soak, controller, painter) = setUp()
            let workspace = controller.workspace
            await waitIdle(workspace)
            let before = await settledHeap()
            workspace.openFile(soak.absolute("huge.txt"), mode: .read, pin: true, synchronously: true)
            painter.paint(controller.rootView)
            let open = await settledHeap()
            workspace.closeActiveTab()
            await waitIdle(workspace)
            painter.paint(controller.rootView)
            let closed = await settledHeap()
            print("MEM closed-tab before=\(before / 1024)KB open=\(open / 1024)KB closed=\(closed / 1024)KB")
            #expect(open - before > Self.size)
            #expect(closed - before < Self.slack)
        }

        @Test("a preview replaced by the next click frees the previous document")
        func replacedPreview() async {
            let (soak, controller, painter) = setUp()
            let workspace = controller.workspace
            await waitIdle(workspace)
            let before = await settledHeap()
            workspace.openFile(soak.absolute("huge.txt"), mode: .read, pin: false, synchronously: true)
            painter.paint(controller.rootView)
            workspace.openFile(soak.absolute("notes.txt"), mode: .read, pin: false, synchronously: true)
            painter.paint(controller.rootView)
            #expect(workspace.tabs.count == 1)
            workspace.closeActiveTab()
            await waitIdle(workspace)
            let after = await settledHeap()
            print("MEM replaced-preview before=\(before / 1024)KB after=\(after / 1024)KB")
            #expect(after - before < Self.slack)
        }

        @Test("a file reloaded many times after changes on disk is held once")
        func reloads() async {
            let (soak, controller, painter) = setUp()
            let workspace = controller.workspace
            workspace.openFile(soak.absolute("huge.txt"), mode: .read, pin: true, synchronously: true)
            painter.paint(controller.rootView)
            await waitIdle(workspace)
            let open = await settledHeap()
            for salt in 1...6 {
                writeBigFile(soak.repo, "huge.txt", megabytes: Self.megabytes, salt: salt)
                workspace.scanNow()
                await waitIdle(workspace)
                painter.paint(controller.rootView)
            }
            let after = await settledHeap()
            print("MEM reloads open=\(open / 1024)KB after-6-reloads=\(after / 1024)KB")
            #expect(after - open < Self.slack)
        }

        @Test("opening another folder frees the previous folder's documents and trees")
        func otherFolder() async {
            let (soak, controller, painter) = setUp()
            let other = TestRepo()
            other.write("b.txt", "b\n")
            other.commitAll("b")
            await waitIdle(controller.workspace)
            let before = await settledHeap()
            controller.workspace.openFile(soak.absolute("huge.txt"), mode: .read, pin: true, synchronously: true)
            painter.paint(controller.rootView)
            controller.open(path: other.path)
            await waitIdle(controller.workspace)
            painter.paint(controller.rootView)
            let after = await settledHeap()
            print("MEM other-folder before=\(before / 1024)KB after=\(after / 1024)KB")
            #expect(after - before < Self.slack)
        }

        /// The line caches are bounded on purpose; this pins what they cost when full, in a normal-sized window:
        /// the code view's laid-out lines after scrolling through a 20 000-line file, plus a full text cache.
        @Test("full line caches cost at most 4 MB")
        func fullLineCachesStayUnderBudget() async throws {
            let soak = SoakRepo()
            let controller = makeController(soak.path)
            let workspace = controller.workspace
            workspace.scanNow()
            workspace.openFile(soak.absolute("src/big.swift"), mode: .read, pin: true, synchronously: true)
            let codeView = controller.rootView.codeView
            let document = try #require(workspace.content?.document)
            let painter = OffscreenPainter()
            painter.paint(controller.rootView)
            TextCache.shared.removeAll()
            codeView.setDocument(document, keepScroll: true)
            let start = await settledHeap()

            let height = Double(document.rows.contentHeight)
            let page = Double(codeView.visibleContentRect.height)
            var y = 0.0
            while y < height {
                codeView.scroll(to: CGPoint(x: 0, y: y))
                withPool { painter.paint(codeView) }
                // Every third page: thousands of different lines go through the cache.
                y += page * 3
            }
            // Fill the shared text cache the way a big tree does: one entry per file name.
            for i in 0..<(TextCache.shared.limit - 1 - TextCache.shared.count) {
                _ = TextCache.shared.line("component_\(i)_view.swift", .regular, .fg)
            }
            let full = await settledHeap()
            TextCache.shared.removeAll()
            let withoutTextCache = await settledHeap()
            codeView.setDocument(document, keepScroll: true)
            let withoutLineCache = await settledHeap()
            print(
                "MEM full-caches total=\((full - start) / 1024)KB text-cache=\((full - withoutTextCache) / 1024)KB "
                    + "code-lines=\((withoutTextCache - withoutLineCache) / 1024)KB "
                    + "(limits: \(CodeView.lineCacheLimit) lines, \(TextCache.shared.limit) texts)")
            #expect(full - start < 4 * 1_048_576)
        }
    }
}
