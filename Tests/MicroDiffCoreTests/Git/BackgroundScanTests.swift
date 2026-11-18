import MicroDiffCore
import Testing

/// The scan that starts at process launch, before the window exists.
@Suite("BackgroundScan")
struct BackgroundScanTests {
    private func changedRepo() -> TestRepo {
        let repo = TestRepo()
        repo.write("a.txt", "one\n")
        repo.commitAll("first")
        repo.write("a.txt", "two\n")
        repo.write("new.txt", "fresh\n")
        return repo
    }

    @Test func deliversTheSameSnapshotAsAScanOfTheRoot() {
        let repo = changedRepo()
        let scan = BackgroundScan(path: repo.path)
        let snapshot = scan.wait(timeout: 30)
        #expect(snapshot == RepoScanner().scan(root: repo.path))
        #expect(snapshot?.totalChangeCount == 2)
    }

    @Test func aPathInsideTheRepoScansTheTopLevel() {
        let repo = changedRepo()
        repo.write("deep/er/x.txt", "x\n")
        let snapshot = BackgroundScan(path: repo.path + "/deep/er").wait(timeout: 30)
        #expect(snapshot?.rootPath == repo.path)
        #expect(snapshot?.isGitRepo == true)
    }

    @Test func aFolderThatIsNotARepoGivesANonRepoSnapshot() {
        let dir = TempDir()
        dir.write("a.txt", "x\n")
        let snapshot = BackgroundScan(path: dir.path).wait(timeout: 30)
        #expect(snapshot?.isGitRepo == false)
        #expect(snapshot?.rootPath == dir.path)
    }

    @Test func waitGivesNilWhenTheScanIsNotReadyInTimeAndLaterCallsStillGetTheResult() {
        let repo = changedRepo()
        let git = FakeGit.slow(0.15)
        let scan = BackgroundScan(path: repo.path, scanner: RepoScanner(git: GitRunner(gitPath: git.path)))
        #expect(scan.wait(timeout: 0.02) == nil)
        let snapshot = scan.wait(timeout: 30)
        #expect(snapshot?.totalChangeCount == 2)
        // Once finished, every call returns at once with the same result.
        #expect(scan.wait(timeout: 0) == snapshot)
        #expect(scan.waitUntilDone() == snapshot)
    }

    @Test func waitUntilDoneBlocksUntilTheScanFinishes() {
        let repo = changedRepo()
        let git = FakeGit.slow(0.15)
        let scan = BackgroundScan(path: repo.path, scanner: RepoScanner(git: GitRunner(gitPath: git.path)))
        #expect(scan.waitUntilDone().totalChangeCount == 2)
    }

    @Test func severalThreadsCanWaitForTheSameScan() async {
        let repo = changedRepo()
        let git = FakeGit.slow(0.15)
        let scan = BackgroundScan(path: repo.path, scanner: RepoScanner(git: GitRunner(gitPath: git.path)))
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<4 { group.addTask { scan.waitUntilDone().totalChangeCount } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(counts == [2, 2, 2, 2])
    }
}
