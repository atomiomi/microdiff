import MicroDiffCore
import MicroDiffTestSupport
import Testing

@testable import MicroDiffUI

/// The app watches the folder: changes made outside it must show up by themselves.
/// These tests use the real file watcher and real git, so they wait (with a deadline) instead of sleeping a fixed time.
@MainActor
@Suite("Live refresh", .serialized)
struct LiveRefreshTests {
    /// Waits until `condition` holds, giving background work the main thread in between.
    private func waitUntil(seconds: Double = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func startedWorkspace(_ repo: TestRepo) async -> Workspace {
        let workspace = Workspace(path: repo.path)
        workspace.start()
        _ = await waitUntil { workspace.snapshot != nil }
        return workspace
    }

    private func lineCount(_ workspace: Workspace) -> Int? {
        guard case let .text(document)? = workspace.content else { return nil }
        return document.newText.lineCount
    }

    @Test("a file edited on disk becomes a change without asking")
    func editShowsUp() async {
        let repo = TestRepo()
        repo.write("a.txt", "one\n")
        repo.commitAll("first")
        let workspace = await startedWorkspace(repo)
        #expect(workspace.snapshot?.totalChangeCount == 0)

        repo.write("a.txt", "one\ntwo\n")
        #expect(await waitUntil { workspace.snapshot?.totalChangeCount == 1 })
        #expect(workspace.sidebarRows().contains { $0.kind == .file && $0.name == "a.txt" })
    }

    @Test("a new file appears, and disappears again when it is removed")
    func untrackedFileComesAndGoes() async {
        let repo = TestRepo()
        repo.write("a.txt", "one\n")
        repo.commitAll("first")
        let workspace = await startedWorkspace(repo)

        repo.write("notes/new.txt", "hello\n")
        #expect(await waitUntil { workspace.snapshot?.repos.first?.changes.map(\.path) == ["notes/new.txt"] })

        repo.remove("notes/new.txt")
        #expect(await waitUntil { workspace.snapshot?.totalChangeCount == 0 })
    }

    @Test("the open document reloads when its file changes")
    func openDocumentReloads() async {
        let repo = TestRepo()
        repo.write("a.txt", "one\n")
        repo.commitAll("first")
        repo.write("a.txt", "one\ntwo\n")
        let workspace = await startedWorkspace(repo)

        workspace.openFile(repo.path + "/a.txt", mode: .diff, pin: true)
        #expect(await waitUntil { lineCount(workspace) == 2 })

        repo.write("a.txt", "one\ntwo\nthree\n")
        #expect(await waitUntil { lineCount(workspace) == 3 })
    }

    @Test("a commit made outside the app clears the change and the tab's status")
    func commitClearsChange() async {
        let repo = TestRepo()
        repo.write("a.txt", "one\n")
        repo.commitAll("first")
        repo.write("a.txt", "one\ntwo\n")
        let workspace = await startedWorkspace(repo)
        workspace.openFile(repo.path + "/a.txt", mode: .diff, pin: true)
        #expect(workspace.tabs.first?.change?.kind == .modified)

        repo.commitAll("second")
        #expect(await waitUntil { workspace.snapshot?.totalChangeCount == 0 })
        #expect(workspace.tabs.first?.change == nil)
    }

    @Test("many quick edits end with the final state shown")
    func burstOfEdits() async {
        let repo = TestRepo()
        repo.write("a.txt", "0\n")
        repo.commitAll("first")
        let workspace = await startedWorkspace(repo)
        workspace.openFile(repo.path + "/a.txt", mode: .file, pin: true)

        var text = "0\n"
        for i in 1...30 {
            text += "\(i)\n"
            repo.write("a.txt", text)
        }
        #expect(await waitUntil { lineCount(workspace) == 31 })
    }
}
