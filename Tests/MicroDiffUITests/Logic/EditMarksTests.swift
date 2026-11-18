import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension UITests {
    /// The change bars beside the line numbers in edit mode: the read view's marks, kept up to date while typing.
    @MainActor
    @Suite
    struct EditMarksTests {
        /// Committed 30 numbered lines; then line 5 changed and two lines added after line 12.
        private func modifiedRepo() -> TestRepo {
            let repo = TestRepo()
            repo.write("a.txt", numberedText(30))
            repo.commitAll("first")
            var lines = (1...30).map { "line \($0)" }
            lines[4] = "line five"
            lines.insert(contentsOf: ["new a", "new b"], at: 12)
            repo.write("a.txt", lines.joined(separator: "\n") + "\n")
            return repo
        }

        private func readMarks(_ controller: MainWindowController) -> [LineMark] {
            guard let rows = controller.workspace.content?.document?.rows else { return [] }
            return (0..<rows.rowCount).map { rows.row(at: $0).mark }
        }

        @Test func theMarksOfAModifiedFileAreTheReadViewsFromTheFirstFrame() async {
            let repo = modifiedRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt", mode: .read)
            let read = readMarks(controller)
            #expect(read[4] == .modified && read[12] == .added && read[13] == .added)
            controller.showEdit(nil)
            #expect(controller.editorMarks == read, "taken over from the read view at once")
            await controller.waitForMarks()
            #expect(controller.editorMarks == read, "and computed again: the same")
        }

        @Test func enteringFromTheDiffComputesTheSameMarks() async {
            let repo = modifiedRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt", mode: .read)
            let read = readMarks(controller)
            controller.showDiff(nil)
            await waitIdle(controller.workspace)
            controller.showEdit(nil)
            await controller.waitForMarks()
            #expect(controller.editorMarks == read)
        }

        @Test func typingANewLineAddsAGreenBarAndUndoRemovesIt() async {
            let repo = TestRepo()
            repo.write("a.txt", numberedText(10))
            repo.commitAll("first")
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            await controller.waitForMarks()
            #expect(controller.editorMarks == Array(repeating: .none, count: 10))

            controller.setCaret(14) // start of "line 3"
            controller.type("typed\n")
            await turnRunLoop()
            await controller.waitForMarks()
            #expect(controller.editorMarks[2] == .added)
            #expect(controller.editorMarks.filter { $0 != .none }.count == 1)

            controller.undo()
            await controller.waitForMarks()
            #expect(controller.editorMarks == Array(repeating: .none, count: 10))
        }

        @Test func editingALineMakesItYellow() async {
            let repo = TestRepo()
            repo.write("a.txt", numberedText(10))
            repo.commitAll("first")
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            controller.setCaret(7) // after "line 1", in "line 2"
            controller.type("!")
            await controller.waitForMarks()
            #expect(controller.editorMarks[1] == .modified)
            #expect(controller.editorMarks.filter { $0 != .none }.count == 1)
        }

        @Test func aResultForOlderTextNeverReplacesANewerOne() async {
            let repo = TestRepo()
            repo.write("a.txt", numberedText(10))
            repo.commitAll("first")
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            await controller.waitForMarks()
            var applied: [Int] = []
            let editor = controller.editor
            controller.workspace.activeBuffer?.onMarksChanged = { [weak controller] in
                applied.append(controller?.marker?.rows?.rowCount ?? -1)
                editor?.gutter.invalidate()
            }
            controller.setCaret(0)
            controller.type("one\n")                      // 11 lines
            #expect(await waitUntil { controller.marker?.isComputing == true })
            controller.type("two\nthree\n")               // 13 lines, typed while 11 is computed
            await controller.waitForMarks()
            #expect(applied.last == 13)
            #expect(!applied.contains(11), "the result for the older text was dropped")
            #expect(controller.editorMarks.prefix(3) == [.added, .added, .added])
        }

        @Test func keystrokesOnlyScheduleAndOneComputationRunsAfterThePause() async {
            let repo = TestRepo()
            repo.write("a.txt", numberedText(10))
            repo.commitAll("first")
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            await controller.waitForMarks()
            var applied = 0
            controller.workspace.activeBuffer?.onMarksChanged = { applied += 1 }
            for character in "abcdefgh" {
                controller.type(String(character))
                #expect(controller.marker?.isComputing == false, "nothing starts while typing goes on")
            }
            await controller.waitForMarks()
            #expect(applied == 1)
            #expect(controller.editorMarks[0] == .modified)
        }

        @Test func filesTheReadViewShowsNoMarksForShowNoneHere() async {
            let repo = editRepo()
            repo.write("untracked.txt", "u\n")
            let folder = Fixture.plainFolder()
            for (path, file) in [(repo.path, "untracked.txt"), (folder.path, "top.txt")] {
                let controller = editController(path)
                controller.openForEdit(file)
                controller.showEdit(nil)
                controller.type("typed\n")
                await controller.waitForMarks()
                #expect(controller.marker?.rows == nil, "\(file)")
            }
        }

        @Test func afterSavingTheBarsMatchTheReadView() async {
            let repo = TestRepo()
            repo.write("a.txt", numberedText(10))
            repo.commitAll("first")
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            controller.setCaret(0)
            controller.type("added\n")
            controller.setCaret(20)
            controller.type("~")
            controller.saveDocument(nil)
            #expect(await waitUntil { controller.workspace.tabs[0].change?.kind == .modified })
            await waitIdle(controller.workspace)
            await controller.waitForMarks()
            let edit = controller.editorMarks
            controller.showRead(nil)
            await waitIdle(controller.workspace)
            #expect(controller.workspace.tabs[0].mode == .read)
            #expect(readMarks(controller) == edit)
            #expect(edit.contains(.added) && edit.contains(.modified))
        }

        @Test func aCommitChangesTheBaseOfTheBars() async {
            let repo = modifiedRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            await controller.waitForMarks()
            #expect(controller.editorMarks.contains(.added))
            repo.commitAll("second")
            controller.workspace.scanNow()
            await controller.waitForMarks()
            #expect(controller.editorMarks.allSatisfy { $0 == .none })
        }

        @Test func theBaseAndTheMarksGoWhenTheTabLeavesEditModeEvenIfTheBufferStays() async {
            let repo = modifiedRepo()
            let controller = editController(repo.path)
            controller.openForEdit("a.txt")
            controller.showEdit(nil)
            controller.type("x")
            await controller.waitForMarks()
            let marker = WeakRef(controller.marker)
            #expect(!marker.isGone)
            withPool { controller.showRead(nil) }
            #expect(controller.workspace.buffers.count == 1, "kept for its undo history")
            #expect(controller.workspace.buffers.values.first?.marker == nil)
            #expect(await eventually { marker.isGone })
        }
    }
}
