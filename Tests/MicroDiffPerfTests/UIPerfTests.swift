import AppKit
import MicroDiffCore
import Testing
@testable import MicroDiffUI

extension PerfSuite {
    @MainActor @Suite struct Drawing {
        @Test func codeViewDraw() {
            let diff = Fixtures.diffDocument
            let view = UIHarness.codeView(diff)
            let ctx = UIHarness.makeContext(width: 900, height: 700)

            // Cold: the view's line and word caches are reset before every run.
            let cold = measure(before: { UIHarness.resetCodeView(view, diff) }) { view.render(in: ctx) }
            #expect(report("codeview-first-draw-diff-5000-lines", cold, budgetMs: 16))

            view.render(in: ctx)
            let warm = measure { view.render(in: ctx) }
            #expect(report("codeview-redraw-warm", warm, budgetMs: 4))
        }

        /// Uses the whole-file view: a diff of 20 hunks is only a few pages long, too short for 50 page-downs.
        @Test func codeViewScroll() {
            let file = Fixtures.fileDocument
            let view = UIHarness.codeView(file)
            let ctx = UIHarness.makeContext(width: 900, height: 700)
            let m = measure(iterations: 5, before: { UIHarness.resetCodeView(view, file) }) {
                for _ in 0..<50 {
                    UIHarness.pageDown(view)
                    view.render(in: ctx)
                }
            }
            #expect(report("codeview-scroll-page-avg", m, budgetMs: 8, perCall: 50))
        }

        /// Entering edit mode on a 5,000-line file: read and check the file, build its text storage, make the editor
        /// view, lay out and draw the first screen. The editor is released in between, so every run is a first entry.
        @Test func editMode() throws {
            let controller = UIHarness.controller(Fixtures.docRepo.path, open: "Big.swift")
            let enter = measure(before: {
                if controller.workspace.tabs[0].mode == .edit { controller.showRead(nil) }
            }) {
                controller.showEdit(nil)
                if let editor = UIHarness.editor(controller) { UIHarness.paint(editor) }
            }
            #expect(report("edit-enter-5000-lines", enter, budgetMs: 25))

            // One keystroke in the middle of the screen, and the frame it causes (text and gutter).
            if controller.workspace.tabs[0].mode != .edit { controller.showEdit(nil) }
            let editor = try #require(UIHarness.editor(controller))
            let rep = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
            editor.scroll(to: ScrollSpot(line: 2500))
            let caret = controller.workspace.activeBuffer?.characterIndex(ofLine: 2510) ?? 0
            editor.textView.setSelectedRange(NSRange(location: caret, length: 0))
            UIHarness.paint(editor, into: rep)
            let key = measure(iterations: 50, warmup: 5) {
                editor.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
                UIHarness.paint(editor, into: rep)
            }
            #expect(controller.workspace.isUnsaved(Fixtures.docRepo.path + "/Big.swift"))
            #expect(report("edit-keystroke-5000-lines", key, budgetMs: 8))
        }

        @Test func treeView() {
            let rows = ChangesTree(snapshot: Fixtures.changesSnapshot).rows()
            #expect(rows.count > 10_000)
            let view = UIHarness.treeView()
            let ctx = UIHarness.makeContext(width: 300, height: 700)

            let set = measure(before: { view.setRows([]) }) { view.setRows(rows) }
            #expect(report("treeview-setrows-10k", set, budgetMs: 10))

            view.render(in: ctx)
            let draw = measure { view.render(in: ctx) }
            #expect(report("treeview-draw-warm", draw, budgetMs: 3))
        }
    }
}
