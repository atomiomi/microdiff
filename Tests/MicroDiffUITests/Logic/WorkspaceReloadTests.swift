import AppKit
import MicroDiffCore
import MicroDiffTestSupport
import Testing
@testable import MicroDiffUI

extension UITests {
    /// An open document when its file changes under it: what the view is told, and what it keeps.
    @MainActor
    @Suite
    struct WorkspaceReloadTests {
        private func workspace(_ repo: TestRepo, opening path: String, mode: ViewMode = .read) -> (Workspace, Counter) {
            let workspace = scannedWorkspace(repo.path)
            let counter = Counter()
            workspace.onContentChanged = { keepScroll in counter.calls.append(keepScroll) }
            workspace.open(repo, path, mode: mode)
            counter.calls.removeAll()
            return (workspace, counter)
        }

        @MainActor
        final class Counter {
            var calls: [Bool] = []
        }

        @Test func aBinaryFileThatBecomesTextIsShownAsTextAndKeepsTheScrollPosition() async throws {
            let repo = TestRepo()
            repo.write("keep.txt", "x\n")
            repo.commitAll("first")
            // Untracked: no diff against an older binary version gets in the way.
            repo.write("blob.dat", Data([0, 1, 2, 3]))
            let (workspace, counter) = workspace(repo, opening: "blob.dat")
            #expect(workspace.content?.message == DocumentLoader.binaryMessage)

            repo.write("blob.dat", "now text\n")
            workspace.scanNow()

            #expect(await waitUntil { workspace.content?.document != nil })
            #expect(workspace.content?.document?.firstLine == "now text")
            #expect(counter.calls == [true])
        }

        @Test func aReloadThatChangesNothingDoesNotTellTheViewToRedraw() async {
            let repo = TestRepo()
            repo.write("blob.dat", Data([0, 1, 2, 3]))
            repo.write("a.txt", "one\ntwo\n")
            repo.commitAll("first")
            for path in ["blob.dat", "a.txt"] {
                let (workspace, counter) = workspace(repo, opening: path)
                // A rescan of an unchanged folder reloads the open file.
                workspace.scanNow()
                _ = await waitUntil(timeout: .milliseconds(300)) { !counter.calls.isEmpty }
                #expect(counter.calls.isEmpty, "\(path) was redrawn without a change")
            }
        }

        @Test func aFileDeletedFromDiskUnderAnOpenTabBecomesAMessageAndComesBackWhenRestored() async {
            let repo = TestRepo()
            repo.write("a.txt", "one\ntwo\n")
            repo.write("b.txt", "keep\n")
            repo.commitAll("first")
            let (workspace, _) = workspace(repo, opening: "a.txt")
            #expect(workspace.content?.document != nil)

            repo.remove("a.txt")
            workspace.scanNow()
            // The file is now a deleted change: its old contents from HEAD, as deleted rows.
            #expect(await waitUntil { workspace.content?.document?.kind == .deleted })
            #expect(workspace.content?.document?.firstLine == "one")

            repo.write("a.txt", "one\ntwo\n")
            workspace.scanNow()
            #expect(await waitUntil { workspace.content?.document?.kind == .plain })
            #expect(workspace.tabs[0].change == nil)
        }

        @Test func anUntrackedFileRemovedBetweenScanAndLoadIsAMessage() {
            let repo = TestRepo()
            repo.write("a.txt", "x\n")
            repo.commitAll("first")
            repo.write("temp.txt", "temporary\n")
            let workspace = scannedWorkspace(repo.path)
            // The scan saw temp.txt; then it vanished before the tab loaded it.
            repo.remove("temp.txt")
            workspace.open(repo, "temp.txt", mode: .diff)
            #expect(workspace.content?.message == DocumentLoader.missingMessage)
            #expect(workspace.tabs.count == 1)
        }
    }
}
