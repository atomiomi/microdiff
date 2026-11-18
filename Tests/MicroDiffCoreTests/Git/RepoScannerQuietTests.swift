import MicroDiffCore
import Testing

/// Nested repositories without local changes: reported apart (`quietRepos`), with what the remote checks need.
@Suite("RepoScanner: quiet nested repositories")
struct RepoScannerQuietTests {
    private let scanner = RepoScanner()

    /// An outer repository with a committed `main.txt` and a clone of `remote` at `path` (clean, following `origin/main`).
    private func outer(cloning remote: TestRemote, at path: String = "inner") -> TestRepo {
        let repo = TestRepo()
        repo.write("main.txt", "m\n")
        repo.commitAll("outer")
        repo.git("clone", "--quiet", remote.path, path)
        return repo
    }

    private func head(_ repo: TestRepo, in folder: String) -> String {
        repo.git("rev-parse", "HEAD", in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func aCleanNestedRepositoryIsReportedWithBranchUpstreamAndHead() {
        let remote = TestRemote()
        _ = remote.clone()
        let repo = outer(cloning: remote)
        let snapshot = scanner.scan(root: repo.path)
        #expect(snapshot.repos.count == 1, "no section: it has nothing changed")
        #expect(snapshot.totalChangeCount == 0)
        let quiet = snapshot.quietRepos
        #expect(quiet.count == 1)
        #expect(quiet.first?.displayPath == "inner" && quiet.first?.name == "inner")
        #expect(quiet.first?.isNested == true && quiet.first?.isSubmodule == false)
        #expect(quiet.first?.rootPath == repo.path + "/inner")
        #expect(quiet.first?.branchLabel == "main" && quiet.first?.hasHead == true)
        #expect(quiet.first?.upstream == "origin/main")
        #expect(quiet.first?.isAhead == false && quiet.first?.isBehind == false)
        #expect(quiet.first?.headOID == head(repo, in: "inner"))
        #expect(snapshot.nestedRepoPaths == ["inner"])
        #expect(snapshot.allRepos.count == 2)
    }

    @Test func aheadAndBehindComeFromWhatGitKnows() {
        let remote = TestRemote()
        let seed = remote.clone()
        let repo = outer(cloning: remote)
        repo.write("inner/mine.txt", "mine\n")
        repo.commitAll("mine", in: "inner")
        var quiet = scanner.scan(root: repo.path).quietRepos[0]
        #expect(quiet.isAhead && !quiet.isBehind)

        seed.write("later.txt", "later\n")
        seed.commitAll("later")
        seed.git("push", "--quiet")
        repo.git("fetch", "--quiet", in: "inner")
        quiet = scanner.scan(root: repo.path).quietRepos[0]
        #expect(quiet.isAhead && quiet.isBehind)
    }

    @Test func aNestedRepositoryWithChangesIsASectionAsBefore() {
        let remote = TestRemote()
        _ = remote.clone()
        let repo = outer(cloning: remote)
        repo.write("inner/a.txt", "changed\n")
        let snapshot = scanner.scan(root: repo.path)
        #expect(snapshot.repos.count == 2)
        #expect(snapshot.quietRepos.isEmpty)
        #expect(snapshot.repos[1].changes == [FileChange(path: "a.txt", kind: .modified)])
        #expect(snapshot.repos[1].upstream == "origin/main")
        #expect(snapshot.repos[1].headOID == head(repo, in: "inner"))
    }

    @Test func aNestedRepositoryThatTheParentIgnoresIsStillNotFound() {
        let remote = TestRemote()
        _ = remote.clone()
        let repo = outer(cloning: remote)
        repo.write(".gitignore", "inner/\n")
        repo.commitAll("ignore it")
        let snapshot = scanner.scan(root: repo.path)
        #expect(snapshot.quietRepos.isEmpty)
        #expect(snapshot.nestedRepoPaths.isEmpty)
    }

    @Test func quietRepositoriesAreSortedByDisplayPathAtAnyDepth() {
        let remote = TestRemote()
        _ = remote.clone()
        let repo = outer(cloning: remote, at: "zeta")
        repo.git("clone", "--quiet", remote.path, "alpha")
        repo.git("clone", "--quiet", remote.path, "alpha/deep")
        let snapshot = scanner.scan(root: repo.path)
        #expect(snapshot.quietRepos.map(\.displayPath) == ["alpha", "alpha/deep", "zeta"])
    }

    @Test func aFolderWithoutDotGitIsNotARepository() {
        let repo = TestRepo()
        repo.write("main.txt", "m\n")
        repo.commitAll("outer")
        repo.write("plain/file.txt", "x\n")
        #expect(scanner.scan(root: repo.path).quietRepos.isEmpty)
    }

    @Test func aScanRunsNoMoreGitCallsThanBefore() {
        let remote = TestRemote()
        _ = remote.clone()
        let repo = outer(cloning: remote)
        let folder = TempDir()
        let log = folder.path + "/calls"
        let fake = FakeGit.wrapping(logTo: log)
        let counting = RepoScanner(git: fake.runner)
        func calls() -> [String] { (fileText(log) ?? "").split(separator: "\n").map(String.init) }

        _ = counting.scan(root: repo.path)
        let clean = calls()
        #expect(clean.filter { $0.contains(" status ") }.count == 2, "the parent and the nested repository, once each")

        repo.write("inner/a.txt", "changed\n")
        _ = counting.scan(root: repo.path)
        let both = calls().count
        #expect(both - clean.count == clean.count, "a nested repository with changes costs the same")
        withExtendedLifetime((folder, fake)) {}
    }
}
