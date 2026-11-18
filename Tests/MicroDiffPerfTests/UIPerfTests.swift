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
