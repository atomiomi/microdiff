import MicroDiffCore
import Testing

/// What the scanner and the loader do when git is missing or fails: no crash, no thrown errors,
/// the folder simply is not shown as a repository.
@Suite("Git missing or failing")
struct GitFailureTests {
    private let missing = GitRunner(gitPath: "/nonexistent/dir/git")

    @Test func scanWithMissingGitIsNotARepoAndHasNoChanges() {
        let repo = TestRepo()
        repo.write("a.txt", "one\n")
        let snapshot = RepoScanner(git: missing).scan(root: repo.path)
        #expect(!snapshot.isGitRepo)
        #expect(snapshot.repos.isEmpty)
        #expect(snapshot.totalChangeCount == 0)
        #expect(snapshot.rootPath == repo.path)
    }

    @Test func resolveRootWithMissingGitKeepsTheGivenFolder() {
        let repo = TestRepo()
        repo.write("sub/a.txt", "one\n")
        let result = RepoScanner(git: missing).resolveRoot(for: repo.path + "/sub")
        #expect(result.root == repo.path + "/sub")
        #expect(!result.isGitRepo)
    }

    @Test func gitThatExitsWithAnErrorMeansNotARepo() {
        let git = FakeGit.failing()
        let scanner = RepoScanner(git: GitRunner(gitPath: git.path))
        let repo = TestRepo()
        let snapshot = scanner.scan(root: repo.path)
        #expect(!snapshot.isGitRepo)
        #expect(scanner.resolveRoot(for: repo.path) == (repo.path, false))
    }

    @Test func gitThatPrintsNothingForTheTopLevelMeansNotARepo() {
        let git = FakeGit("exit 0")
        let repo = TestRepo()
        #expect(RepoScanner(git: GitRunner(gitPath: git.path)).resolveRoot(for: repo.path) == (repo.path, false))
    }

    @Test func readStatusIsNilWhenGitFails() {
        let git = FakeGit.failing()
        let repo = TestRepo()
        #expect(RepoScanner(git: GitRunner(gitPath: git.path)).readStatus(in: repo.path) == nil)
    }

    @Test func gitErrorCarriesExitCodeAndTrimmedStderr() {
        let git = FakeGit.failing(exitCode: 3, message: "fatal: nope")
        #expect(throws: GitError(exitCode: 3, stderr: "fatal: nope", arguments: ["status"])) {
            try GitRunner(gitPath: git.path).run(["status"], in: "/")
        }
    }

    @Test func patchAndHeadContentsThrowWhenGitFails() throws {
        let repo = TestRepo()
        repo.write("a.txt", "one\n")
        repo.commitAll("first")
        repo.write("a.txt", "two\n")
        let snapshot = RepoScanner().scan(root: repo.path).repos[0]
        let change = try #require(snapshot.changes.first)
        let broken = RepoScanner(git: GitRunner(gitPath: "/nonexistent/git"))
        #expect(throws: GitError.self) { try broken.patch(for: change, in: snapshot) }
        #expect(throws: GitError.self) { try broken.headContents(path: "a.txt", in: snapshot) }
    }

    @Test func modifiedFileStillShowsAsPlainTextWhenItsDiffCannotBeRead() throws {
        let repo = TestRepo()
        repo.write("a.txt", "one\ntwo\n")
        repo.commitAll("first")
        repo.write("a.txt", "one\nthree\n")
        let snapshot = RepoScanner().scan(root: repo.path).repos[0]
        let loader = DocumentLoader(scanner: RepoScanner(git: GitRunner(gitPath: "/nonexistent/git")))
        let request = DocumentRequest(path: repo.path + "/a.txt", repo: snapshot, change: snapshot.changes.first, mode: .diff)
        guard case let .text(document) = loader.load(request) else {
            Issue.record("expected text")
            return
        }
        #expect(document.kind == .plain)
        #expect(document.newText.line(1) == "three")
    }

    @Test func deletedFileIsAMessageWhenGitCannotReadItsOldContents() throws {
        let repo = TestRepo()
        repo.write("a.txt", "one\n")
        repo.commitAll("first")
        repo.remove("a.txt")
        let snapshot = RepoScanner().scan(root: repo.path).repos[0]
        let loader = DocumentLoader(scanner: RepoScanner(git: GitRunner(gitPath: "/nonexistent/git")))
        let request = DocumentRequest(path: repo.path + "/a.txt", repo: snapshot, change: snapshot.changes.first)
        guard case let .message(text) = loader.load(request) else {
            Issue.record("expected a message")
            return
        }
        #expect(text == DocumentLoader.missingMessage)
    }
}
