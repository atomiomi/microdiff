import AppKit
import MicroDiffCore
import Testing
@testable import MicroDiffUI

extension UITests {
    /// Real events delivered to the view that is on top at a point (the canvas inside a scroll view), the way the window would.
    @MainActor
    @Suite
    struct CanvasEventForwardingTests {
        private func fileRows(_ count: Int) -> [TreeRow] {
            (0..<count).map { index in
                TreeRow(
                    id: TreeRow.makeID(repoIndex: 0, kind: .file, path: "f\(index)"), kind: .file, depth: 0, name: "f\(index)",
                    path: "f\(index)", repoIndex: -1, change: nil)
            }
        }

        private func hostedTree(rows: Int) -> (TreeView, NSWindow) {
            let tree = TreeView(frame: .zero)
            tree.style = .files
            let window = hostInWindow(tree, width: 280, height: 300)
            tree.setRows(fileRows(rows))
            tree.layoutSubtreeIfNeeded()
            return (tree, window)
        }

        private func topmost(_ window: NSWindow, _ tree: TreeView, at point: CGPoint) throws -> NSView {
            try #require(window.topmostView(atWindowPoint: tree.convert(point, to: nil)))
        }

        @Test func aClickOnAScrolledTreeOpensTheRowUnderThePointerAndTakesFocus() throws {
            let (tree, window) = hostedTree(rows: 60)
            var opened: [String] = []
            tree.onOpen = { row, _ in opened.append(row.name) }
            tree.scroll(to: CGPoint(x: 0, y: 96))

            let spot = point(40, 30)
            let canvas = try topmost(window, tree, at: spot)
            #expect(canvas !== tree)
            canvas.mouseDown(with: makeMouseDown(in: tree, at: spot, window: window))

            // Content y = 30 + 96 = 126; rows start at 8 and are 24 tall: (126 - 8) / 24 = row 4.
            #expect(opened == ["f4"])
            #expect(window.firstResponder === tree)
        }

        @Test func aClickOnTheTopRowOfAnUnscrolledTreeOpensTheFirstRow() throws {
            let (tree, window) = hostedTree(rows: 5)
            var opened: [String] = []
            tree.onOpen = { row, pin in opened.append("\(row.name) pinned=\(pin)") }
            let spot = point(40, 20)
            try topmost(window, tree, at: spot).mouseDown(with: makeMouseDown(in: tree, at: spot, window: window))
            try topmost(window, tree, at: spot).mouseDown(with: makeMouseDown(in: tree, at: spot, clickCount: 2, window: window))
            #expect(opened == ["f0 pinned=false", "f0 pinned=true"])
        }

        @Test func draggingInsideTheCodeViewSelectsAndReleasingKeepsTheSelection() throws {
            let repo = Fixture.changesRepo()
            let view = CodeView(frame: .zero)
            let window = hostInWindow(view, width: 800, height: 400)
            view.setDocument(DocumentFixture.load(repo, "new/deep/fresh.txt"), keepScroll: false)
            view.layoutSubtreeIfNeeded()

            let start = point(Theme.codeX + 1, 8 + Theme.lineHeight / 2)
            let end = point(Theme.codeX + 5 * Theme.codeCharWidth + 1, 8 + Theme.lineHeight / 2)
            let canvas = try #require(window.topmostView(atWindowPoint: view.convert(start, to: nil)))
            canvas.mouseDown(with: makeMouseDown(in: view, at: start, window: window))
            canvas.mouseDragged(with: Event.mouse(.leftMouseDragged, at: view.convert(end, to: nil)))
            canvas.mouseUp(with: Event.mouse(.leftMouseUp, at: view.convert(end, to: nil)))
            #expect(view.selectedText == "fresh")
            #expect(window.firstResponder === view)
        }
    }
}
