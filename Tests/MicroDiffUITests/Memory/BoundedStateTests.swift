import CoreGraphics
import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

/// Every cache and remembered collection has a cap, so days of use cannot grow it without end.
extension UITests {
    @MainActor
    @Suite(.serialized)
    struct BoundedStateTests {
        @Test("the text layout cache never holds more than its limit")
        func textCacheIsCapped() {
            let cache = TextCache()
            for i in 0..<(cache.limit * 3 + 17) {
                _ = cache.line("line \(i)", .regular, .fg)
                #expect(cache.count <= cache.limit)
            }
            cache.removeAll()
            for _ in 0..<1000 { _ = cache.line("same", .regular, .fg) }
            #expect(cache.count == 1)
        }

        @Test("the code view's line caches stay at their caps while scrolling through a long file")
        func codeViewCachesAreCapped() throws {
            let soak = SoakRepo()
            let controller = makeController(soak.path)
            let workspace = controller.workspace
            workspace.scanNow()
            workspace.openFile(soak.absolute("src/big.swift"), mode: .diff, pin: true, synchronously: true)
            let codeView = controller.rootView.codeView
            let document = try #require(workspace.content?.document)
            let painter = OffscreenPainter()
            let height = Double(document.rows.contentHeight)
            let page = Double(codeView.visibleContentRect.height)
            var y = 0.0
            var maxLines = 0
            var maxWords = 0
            while y < height {
                codeView.scroll(to: CGPoint(x: 0, y: y))
                painter.paint(codeView)
                // The private caches, read by reflection.
                maxLines = max(maxLines, storedCount(codeView, "lineCache") ?? -1)
                maxWords = max(maxWords, storedCount(codeView, "wordRanges") ?? -1)
                #expect(TextCache.shared.count <= TextCache.shared.limit)
                y += page
            }
            #expect(CodeView.lineCacheLimit == 200)
            #expect(TextCache.shared.limit == 1000)
            #expect(maxLines > 0 && maxLines <= CodeView.lineCacheLimit)
            #expect(maxWords >= 0 && maxWords <= CodeView.wordRangesLimit + 2)
        }

        @Test("single clicks reuse the preview tab: hundreds of them leave one tab")
        func previewTabDoesNotPileUp() {
            let soak = SoakRepo()
            let workspace = scannedWorkspace(soak.path)
            let files = ["src/app.swift", "src/mid.swift", "notes.txt"] + (0..<12).map { "pkg/m\($0)/sub/file\($0).txt" }
            for i in 0..<200 {
                workspace.openFile(soak.absolute(files[i % files.count]), mode: .read, pin: false, synchronously: true)
            }
            #expect(workspace.tabs.count == 1)
            for i in 0..<60 {
                workspace.openFile(soak.absolute(files[i % 3]), mode: .read, pin: true, synchronously: true)
            }
            // A file is open in at most one tab: the preview plus the three pinned files.
            #expect(workspace.tabs.count == 4)
        }

        @Test("a closed tab's opened folds are not remembered")
        func foldsGoWithTheTab() throws {
            let soak = SoakRepo()
            let workspace = scannedWorkspace(soak.path)
            let app = soak.absolute("src/app.swift")
            workspace.openFile(app, mode: .diff, pin: true, synchronously: true)
            let fold = try #require(workspace.content?.document?.foldRows.first)
            workspace.expandFold(startingAt: fold.line)
            #expect(workspace.tabs[0].expandedFolds.count == 1)
            workspace.closeTab(0)
            workspace.openFile(app, mode: .diff, pin: true, synchronously: true)
            #expect(workspace.tabs[0].expandedFolds.isEmpty)
        }

        @Test("a flood of refresh requests during a scan queues one rescan, not hundreds")
        func refreshRequestsCoalesce() async {
            let soak = SoakRepo()
            let workspace = Workspace(path: soak.path)
            var scans = 0
            workspace.onSidebarChanged = { scans += 1 }
            for _ in 0..<500 { workspace.refresh() }
            await waitQuiet(workspace)
            // The scan that was asked for, plus one for everything that came in while it ran.
            #expect(scans <= 2)
            #expect(scans >= 1)
        }

        @Test("open folders of the files tab that disappeared are forgotten once there are many")
        func vanishedExpandedFoldersAreForgotten() {
            let soak = SoakRepo()
            let count = Workspace.folderStateLimit + 44
            for i in 0..<count { soak.repo.write("gone/d\(i)/f.txt", "x\n") }
            let workspace = scannedWorkspace(soak.path)
            workspace.selectSidebarTab(.files)
            func toggle(_ path: String) {
                if let row = workspace.row(path: path, kind: .directory) { workspace.toggle(row) }
            }
            toggle("gone")
            for i in 0..<count { toggle("gone/d\(i)") }
            toggle("pkg")
            let expanded: () -> Set<String> = { storedProperty(workspace, "fileTree", "expanded") ?? [] }
            #expect(expanded().count == count + 3)

            soak.repo.remove("gone")
            workspace.scanNow()
            // Only what still exists is kept: the root and "pkg".
            #expect(expanded() == ["", "pkg"])
            #expect(workspace.row(path: "pkg", kind: .directory)?.isExpanded == true)
        }

        @Test("a few vanished folders keep their state (a checkout that brings them back)")
        func fewVanishedFoldersAreKept() {
            let soak = SoakRepo()
            let workspace = scannedWorkspace(soak.path)
            workspace.selectSidebarTab(.files)
            if let row = workspace.row(path: "pkg", kind: .directory) { workspace.toggle(row) }
            soak.repo.remove("pkg")
            workspace.scanNow()
            soak.repo.write("pkg/m0/sub/file0.txt", "x\n")
            workspace.scanNow()
            #expect(workspace.row(path: "pkg", kind: .directory)?.isExpanded == true)
        }

        @Test("collapsed folders of the changes tab that disappeared are forgotten once there are many")
        func vanishedCollapsedFoldersAreForgotten() {
            let soak = SoakRepo()
            let count = Workspace.folderStateLimit + 44
            for i in 0..<count { soak.repo.write("new/d\(i)/f.txt", "x\n") }
            let workspace = scannedWorkspace(soak.path)
            for i in 0..<count {
                if let row = workspace.row(path: "new/d\(i)", kind: .directory) { workspace.toggle(row) }
            }
            if let row = workspace.row(path: "src", kind: .directory) { workspace.toggle(row) }
            let collapsed: () -> Set<String> = { storedProperty(workspace, "collapsed") ?? [] }
            #expect(collapsed().count == count + 1)

            soak.repo.remove("new")
            workspace.scanNow()
            #expect(collapsed().count == 1)
            #expect(workspace.row(path: "src", kind: .directory)?.isExpanded == false)
        }
    }
}
