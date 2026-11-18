import MicroDiffCore
import Testing

@Suite struct RepoScannerScanTests {
    private let scanner = RepoScanner()

    private func scan(_ repo: TestRepo) -> WorkspaceSnapshot { scanner.scan(root: repo.path) }

    private func rootChanges(_ repo: TestRepo) throws -> [FileChange] {
        try #require(scan(repo).repos.first).changes
    }

    /// A repo with `a.txt`, `b.txt` and `dir/c.txt` committed.
    private func committedRepo() -> TestRepo {
        let repo = TestRepo()
        repo.write("a.txt", "a1\na2\n")
        repo.write("b.txt", "b1\nb2\n")
        repo.write("dir/c.txt", "c1\n")
        repo.commitAll("initial")
        return repo
    }

    // MARK: root repository

    @Test func cleanRepoHasRootRepoWithoutChanges() throws {
        let repo = committedRepo()
        let snapshot = scan(repo)
        #expect(snapshot.isGitRepo)
        #expect(snapshot.rootPath == repo.path)
        #expect(snapshot.repos.count == 1)
        #expect(snapshot.submodulePaths.isEmpty)
        let root = try #require(snapshot.repos.first)
        #expect(root.changes.isEmpty)
        #expect(root.displayPath == "")
        #expect(!root.isSubmodule)
        #expect(root.branchLabel == "main")
        #expect(root.hasHead)
        #expect(root.rootPath == repo.path)
        #expect(root.name == repo.path.split(separator: "/").last.map(String.init))
        #expect(snapshot.totalChangeCount == 0)
    }

    @Test func modifiedFile() throws {
        let repo = committedRepo()
        repo.write("a.txt", "changed\n")
        #expect(try rootChanges(repo) == [FileChange(path: "a.txt", kind: .modified)])
    }

    @Test func stagedAddedFile() throws {
        let repo = committedRepo()
        repo.write("new.txt", "x\n")
        repo.git("add", "new.txt")
        #expect(try rootChanges(repo) == [FileChange(path: "new.txt", kind: .added)])
    }

    @Test func untrackedFilesAreListedPerFile() throws {
        let repo = committedRepo()
        repo.write("newdir/deep/one.txt", "1")
        repo.write("newdir/two.txt", "2")
        let changes = try rootChanges(repo)
        #expect(Set(changes) == [
            FileChange(path: "newdir/deep/one.txt", kind: .added, isUntracked: true),
            FileChange(path: "newdir/two.txt", kind: .added, isUntracked: true),
        ])
        #expect(changes.count == 2)
    }

    @Test func ignoredFilesAreNotListed() throws {
        let repo = committedRepo()
        repo.write(".gitignore", "*.log\n")
        repo.commitAll("ignore")
        repo.write("noise.log", "x")
        #expect(try rootChanges(repo).isEmpty)
    }

    @Test func ignoredEntriesAreReportedWithoutWalkingIntoDirectories() throws {
        let repo = committedRepo()
        repo.write(".gitignore", "node_modules\n*.log\n.env\n")
        repo.commitAll("ignore")
        repo.write("node_modules/a/b.js", "x"); repo.write("node_modules/c.js", "x")
        repo.write("noise.log", "x"); repo.write("dir/deep.log", "x"); repo.write(".env", "A=1")
        let root = try #require(scan(repo).repos.first)
        #expect(Set(root.ignored) == ["node_modules/", "noise.log", "dir/deep.log", ".env"])
        #expect(root.changes.isEmpty)
    }

    @Test func deletedUnstagedAndStaged() throws {
        let repo = committedRepo()
        repo.remove("a.txt")
        repo.git("rm", "--quiet", "b.txt")
        let changes = try rootChanges(repo)
        #expect(Set(changes) == [FileChange(path: "a.txt", kind: .deleted), FileChange(path: "b.txt", kind: .deleted)])
    }

    @Test func stagedRenameKeepsOldPath() throws {
        let repo = committedRepo()
        repo.git("mv", "a.txt", "renamed.txt")
        #expect(try rootChanges(repo) == [FileChange(path: "renamed.txt", oldPath: "a.txt", kind: .renamed)])
    }

    @Test func modifiedStagedAndUnstagedIsOneEntry() throws {
        let repo = committedRepo()
        repo.write("a.txt", "staged\n")
        repo.git("add", "a.txt")
        repo.write("a.txt", "staged\nthen unstaged\n")
        #expect(try rootChanges(repo) == [FileChange(path: "a.txt", kind: .modified)])
    }

    @Test func deletedThenRecreatedUntrackedIsModified() throws {
        let repo = committedRepo()
        repo.git("rm", "--quiet", "--cached", "a.txt")
        #expect(try rootChanges(repo) == [FileChange(path: "a.txt", kind: .modified)])
    }

    @Test func binaryModifiedFile() throws {
        let repo = TestRepo()
        repo.write("img.bin", Data([0, 1, 2, 3]))
        repo.commitAll()
        repo.write("img.bin", Data([0, 9, 9, 9, 9]))
        #expect(try rootChanges(repo) == [FileChange(path: "img.bin", kind: .modified)])
    }

    @Test func pathsWithSpacesAndUnicode() throws {
        let repo = TestRepo()
        repo.write("my file.txt", "1")
        repo.write("папка/日本語 ✓.txt", "1")
        repo.commitAll()
        repo.write("my file.txt", "2")
        repo.write("папка/日本語 ✓.txt", "2")
        repo.write("new folder/new file é.txt", "3")
        let paths = Set(try rootChanges(repo).map(\.path))
        #expect(paths == ["my file.txt", "папка/日本語 ✓.txt", "new folder/new file é.txt"])
    }

    @Test func repoWithoutCommits() throws {
        let repo = TestRepo()
        repo.write("one.txt", "1")
        repo.write("sub/two.txt", "2")
        let root = try #require(scan(repo).repos.first)
        #expect(root.branchLabel == "no commits")
        #expect(!root.hasHead)
        #expect(Set(root.changes) == [
            FileChange(path: "one.txt", kind: .added, isUntracked: true),
            FileChange(path: "sub/two.txt", kind: .added, isUntracked: true),
        ])
    }

    @Test func detachedHeadShowsSevenCharacters() throws {
        let repo = committedRepo()
        let oid = repo.git("rev-parse", "HEAD")
        repo.git("checkout", "--quiet", "--detach")
        let root = try #require(scan(repo).repos.first)
        #expect(root.branchLabel == String(oid.prefix(7)))
        #expect(root.branchLabel.count == 7)
        #expect(root.hasHead)
    }

    @Test func branchNameWithSlash() throws {
        let repo = committedRepo()
        repo.git("checkout", "--quiet", "-b", "feature/x")
        #expect(try #require(scan(repo).repos.first).branchLabel == "feature/x")
    }

    @Test func mergeConflictIsConflicted() throws {
        let repo = committedRepo()
        repo.git("checkout", "--quiet", "-b", "other")
        repo.write("a.txt", "other side\n")
        repo.commitAll("other")
        repo.git("checkout", "--quiet", "main")
        repo.write("a.txt", "main side\n")
        repo.commitAll("main")
        #expect(!repo.tryGit("merge", "other"))
        #expect(try rootChanges(repo) == [FileChange(path: "a.txt", kind: .conflicted)])
    }

    @Test func folderThatIsNotARepo() {
        let dir = TempDir()
        dir.write("x.txt", "x")
        let snapshot = scanner.scan(root: dir.path)
        #expect(!snapshot.isGitRepo)
        #expect(snapshot.repos.isEmpty)
        #expect(snapshot.rootPath == dir.path)
        #expect(snapshot.submodulePaths.isEmpty)
    }

    @Test func missingFolderIsNotARepo() {
        #expect(!scanner.scan(root: "/definitely/not/here").isGitRepo)
    }

    // MARK: submodules

    private func libRepo() -> TestRepo {
        let lib = TestRepo()
        lib.write("lib.txt", "one\ntwo\n")
        lib.commitAll("lib")
        return lib
    }

    private func repoWithSubmodule(at path: String = "vendor/lib") -> TestRepo {
        let repo = TestRepo()
        repo.write("main.txt", "m\n")
        repo.addSubmodule(from: libRepo(), at: path)
        repo.commitAll("with submodule")
        return repo
    }

    @Test func cleanSubmoduleIsRegisteredButNotListed() {
        let repo = repoWithSubmodule()
        let snapshot = scan(repo)
        #expect(snapshot.repos.count == 1)
        #expect(snapshot.submodulePaths == ["vendor/lib"])
        #expect(snapshot.totalChangeCount == 0)
    }

    @Test func submoduleWithModifiedFileBecomesItsOwnRepo() throws {
        let repo = repoWithSubmodule()
        repo.write("vendor/lib/lib.txt", "changed\n")
        let snapshot = scan(repo)
        #expect(snapshot.repos.count == 2)
        #expect(snapshot.repos[0].changes.isEmpty)
        let sub = snapshot.repos[1]
        #expect(sub.isSubmodule)
        #expect(sub.displayPath == "vendor/lib")
        #expect(sub.name == "vendor/lib")
        #expect(sub.rootPath == repo.path + "/vendor/lib")
        #expect(sub.hasHead)
        #expect(!sub.branchLabel.isEmpty)
        #expect(sub.changes == [FileChange(path: "lib.txt", kind: .modified)])
        #expect(snapshot.submodulePaths == ["vendor/lib"])
    }

    @Test func submoduleWithOnlyUntrackedFileIsListed() throws {
        let repo = repoWithSubmodule()
        repo.write("vendor/lib/notes/todo.txt", "x")
        let snapshot = scan(repo)
        let sub = try #require(snapshot.repos.last)
        #expect(snapshot.repos.count == 2)
        #expect(sub.changes == [FileChange(path: "notes/todo.txt", kind: .added, isUntracked: true)])
    }

    @Test func submoduleOnNewCommitIsNotListed() {
        let repo = repoWithSubmodule()
        repo.write("vendor/lib/extra.txt", "x")
        repo.commitAll("inside", in: "vendor/lib")
        let snapshot = scan(repo)
        #expect(snapshot.repos.count == 1)
        #expect(snapshot.repos[0].changes.isEmpty)
        #expect(!snapshot.repos[0].changes.contains { $0.path == "vendor/lib" })
        #expect(snapshot.submodulePaths == ["vendor/lib"])
    }

    @Test func newCommitPlusDirtyFileListsOnlyTheDirtyFile() throws {
        let repo = repoWithSubmodule()
        repo.write("vendor/lib/extra.txt", "x")
        repo.commitAll("inside", in: "vendor/lib")
        repo.write("vendor/lib/lib.txt", "dirty\n")
        let snapshot = scan(repo)
        #expect(snapshot.repos.count == 2)
        #expect(snapshot.repos[0].changes.isEmpty)
        #expect(snapshot.repos[1].changes == [FileChange(path: "lib.txt", kind: .modified)])
    }

    @Test func multipleSubmodulesAreSortedByPath() throws {
        let repo = repoWithSubmodule(at: "zeta")
        repo.addSubmodule(from: libRepo(), at: "alpha")
        repo.commitAll("second")
        repo.write("zeta/lib.txt", "z\n")
        repo.write("alpha/lib.txt", "a\n")
        let snapshot = scan(repo)
        #expect(snapshot.repos.map(\.displayPath) == ["", "alpha", "zeta"])
        #expect(snapshot.submodulePaths == ["alpha", "zeta"])
    }

    @Test func nestedSubmoduleChangeUsesFullDisplayPath() throws {
        let inner = libRepo()
        let outer = TestRepo()
        outer.write("outer.txt", "o\n")
        outer.addSubmodule(from: inner, at: "inner")
        outer.commitAll("outer with inner")
        let repo = TestRepo()
        repo.write("main.txt", "m\n")
        repo.addSubmodule(from: outer, at: "outer")
        repo.commitAll("main with outer")
        repo.git("submodule", "--quiet", "update", "--init", "--recursive")

        repo.write("outer/inner/lib.txt", "deep change\n")
        let snapshot = scan(repo)
        #expect(snapshot.submodulePaths == ["outer", "outer/inner"])
        let deep = try #require(snapshot.repos.first { $0.displayPath == "outer/inner" })
        #expect(deep.name == "outer/inner")
        #expect(deep.isSubmodule)
        #expect(deep.rootPath == repo.path + "/outer/inner")
        #expect(deep.changes == [FileChange(path: "lib.txt", kind: .modified)])
        #expect(snapshot.repos.allSatisfy { $0.displayPath != "outer" })
    }

    @Test func uninitializedSubmoduleIsRegisteredButSkipped() {
        let source = repoWithSubmodule()
        let cloneDir = TempDir()
        // Clone without --recursive: the submodule folder exists but is empty.
        source.git("clone", "--quiet", source.path, cloneDir.path + "/clone")
        let snapshot = scanner.scan(root: cloneDir.path + "/clone")
        #expect(snapshot.isGitRepo)
        #expect(snapshot.repos.count == 1)
        #expect(snapshot.submodulePaths == ["vendor/lib"])
    }

    // MARK: resolveRoot

    @Test func resolveRootFromSubfolderGivesTopLevel() {
        let repo = committedRepo()
        let result = scanner.resolveRoot(for: repo.path + "/dir")
        #expect(result.isGitRepo)
        #expect(result.root == repo.path)
    }

    @Test func resolveRootOfTopLevelAndTrailingSlash() {
        let repo = committedRepo()
        #expect(scanner.resolveRoot(for: repo.path).root == repo.path)
        #expect(scanner.resolveRoot(for: repo.path + "/").root == repo.path)
        #expect(scanner.resolveRoot(for: repo.path + "/dir/..").root == repo.path)
    }

    @Test func resolveRootOfNonRepoReturnsStandardizedInput() {
        let dir = TempDir()
        dir.mkdir("a/b")
        let result = scanner.resolveRoot(for: dir.path + "/a/b/../")
        #expect(!result.isGitRepo)
        #expect(result.root == dir.path + "/a")
    }

    @Test func resolveRootFollowsSymlinks() {
        let repo = committedRepo()
        let holder = TempDir()
        let link = holder.path + "/link"
        symlinkFolder(link, to: repo.path)
        let result = scanner.resolveRoot(for: link)
        #expect(result.isGitRepo)
        #expect(result.root == repo.path)
    }

    @Test func resolveRootInsideSubmoduleGivesSubmodule() {
        let repo = repoWithSubmodule()
        let result = scanner.resolveRoot(for: repo.path + "/vendor/lib")
        #expect(result.isGitRepo)
        #expect(result.root == repo.path + "/vendor/lib")
    }
}

@Suite struct RepoScannerPatchTests {
    private let scanner = RepoScanner()

    private func repoSnapshot(_ repo: TestRepo) throws -> RepoSnapshot {
        try #require(scanner.scan(root: repo.path).repos.first)
    }

    private func deleted(_ patch: FilePatch) -> [String] {
        (0..<patch.deletedText.lineCount).map { patch.deletedText.line($0) }
    }

    private func numbered(_ count: Int, replacing: [Int: String] = [:]) -> String {
        (1...count).map { replacing[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
    }

    @Test func modifiedFileGivesHunks() throws {
        let repo = TestRepo()
        repo.write("f.txt", numbered(10))
        repo.commitAll()
        repo.write("f.txt", numbered(10, replacing: [2: "TWO", 7: "SEVEN"]) + "tail\n")
        let snapshot = try repoSnapshot(repo)
        let change = try #require(snapshot.changes.first)
        let patch = try scanner.patch(for: change, in: snapshot)
        #expect(!patch.isBinary)
        #expect(patch.hunks == [
            Hunk(oldStart: 2, oldCount: 1, newStart: 2, newCount: 1, deletedLines: 0..<1),
            Hunk(oldStart: 7, oldCount: 1, newStart: 7, newCount: 1, deletedLines: 1..<2),
            Hunk(oldStart: 10, oldCount: 0, newStart: 11, newCount: 1, deletedLines: 2..<2),
        ])
        #expect(deleted(patch) == ["line 2", "line 7"])
    }

    @Test func stagedAndUnstagedEditsAppearTogether() throws {
        let repo = TestRepo()
        repo.write("f.txt", numbered(10))
        repo.commitAll()
        repo.write("f.txt", numbered(10, replacing: [1: "ONE"]))
        repo.git("add", "f.txt")
        repo.write("f.txt", numbered(10, replacing: [1: "ONE", 9: "NINE"]))
        let snapshot = try repoSnapshot(repo)
        let patch = try scanner.patch(for: #require(snapshot.changes.first), in: snapshot)
        #expect(patch.hunks.map(\.oldStart) == [1, 9])
        #expect(deleted(patch) == ["line 1", "line 9"])
    }

    @Test func deletedFileDiffsAsOneDeletion() throws {
        let repo = TestRepo()
        repo.write("f.txt", "a\nb\n")
        repo.commitAll()
        repo.remove("f.txt")
        let snapshot = try repoSnapshot(repo)
        let patch = try scanner.patch(for: #require(snapshot.changes.first), in: snapshot)
        #expect(patch.hunks == [Hunk(oldStart: 1, oldCount: 2, newStart: 0, newCount: 0, deletedLines: 0..<2)])
        #expect(deleted(patch) == ["a", "b"])
    }

    @Test func renamedAndEditedFileDiffsAgainstOldPath() throws {
        let repo = TestRepo()
        repo.write("old name.txt", numbered(12))
        repo.commitAll()
        repo.git("mv", "old name.txt", "new name.txt")
        repo.write("new name.txt", numbered(12, replacing: [5: "FIVE"]))
        let snapshot = try repoSnapshot(repo)
        let change = try #require(snapshot.changes.first)
        #expect(change == FileChange(path: "new name.txt", oldPath: "old name.txt", kind: .renamed))
        let patch = try scanner.patch(for: change, in: snapshot)
        #expect(patch.hunks == [Hunk(oldStart: 5, oldCount: 1, newStart: 5, newCount: 1, deletedLines: 0..<1)])
        #expect(deleted(patch) == ["line 5"])
    }

    @Test func pureRenameHasNoHunks() throws {
        let repo = TestRepo()
        repo.write("a.txt", numbered(12))
        repo.commitAll()
        repo.git("mv", "a.txt", "b.txt")
        let snapshot = try repoSnapshot(repo)
        let patch = try scanner.patch(for: #require(snapshot.changes.first), in: snapshot)
        #expect(patch.hunks.isEmpty)
        #expect(!patch.isBinary)
    }

    @Test func untrackedAndAddedGiveEmptyPatch() throws {
        let repo = TestRepo()
        repo.write("tracked.txt", "t\n")
        repo.commitAll()
        repo.write("untracked.txt", "u\n")
        repo.write("added.txt", "a\n")
        repo.git("add", "added.txt")
        let snapshot = try repoSnapshot(repo)
        #expect(snapshot.changes.count == 2)
        for change in snapshot.changes {
            let patch = try scanner.patch(for: change, in: snapshot)
            #expect(patch.hunks.isEmpty)
            #expect(!patch.isBinary)
        }
    }

    @Test func repoWithoutHeadGivesEmptyPatch() throws {
        let repo = TestRepo()
        repo.write("a.txt", "a\n")
        repo.git("add", "a.txt")
        let snapshot = try repoSnapshot(repo)
        #expect(!snapshot.hasHead)
        let patch = try scanner.patch(for: #require(snapshot.changes.first), in: snapshot)
        #expect(patch.hunks.isEmpty)
    }

    @Test func binaryChangeIsFlagged() throws {
        let repo = TestRepo()
        repo.write("img.bin", Data([0, 1, 2, 3]))
        repo.commitAll()
        repo.write("img.bin", Data([0, 9, 9, 9, 9]))
        let snapshot = try repoSnapshot(repo)
        let patch = try scanner.patch(for: #require(snapshot.changes.first), in: snapshot)
        #expect(patch.isBinary)
        #expect(patch.hunks.isEmpty)
    }

    @Test func specialFileNamesAreTakenLiterally() throws {
        let repo = TestRepo()
        repo.write("*.txt", "star\n")
        repo.write("other.txt", "other\n")
        repo.commitAll()
        repo.write("*.txt", "STAR\n")
        repo.write("other.txt", "OTHER\n")
        let snapshot = try repoSnapshot(repo)
        let change = try #require(snapshot.changes.first { $0.path == "*.txt" })
        let patch = try scanner.patch(for: change, in: snapshot)
        #expect(deleted(patch) == ["star"])
    }

    @Test func crlfFileDiffsCleanly() throws {
        let repo = TestRepo()
        repo.write("w.txt", "a\r\nb\r\nc\r\n")
        repo.commitAll()
        repo.write("w.txt", "a\r\nB\r\nc\r\n")
        let snapshot = try repoSnapshot(repo)
        let patch = try scanner.patch(for: #require(snapshot.changes.first), in: snapshot)
        #expect(patch.hunks == [Hunk(oldStart: 2, oldCount: 1, newStart: 2, newCount: 1, deletedLines: 0..<1)])
        #expect(deleted(patch) == ["b"])
    }

    @Test func patchInsideSubmodule() throws {
        let lib = TestRepo()
        lib.write("lib.txt", "one\ntwo\n")
        lib.commitAll()
        let repo = TestRepo()
        repo.addSubmodule(from: lib, at: "lib")
        repo.commitAll()
        repo.write("lib/lib.txt", "one\n2\n")
        let snapshot = scanner.scan(root: repo.path)
        let sub = try #require(snapshot.repos.last)
        let patch = try scanner.patch(for: #require(sub.changes.first), in: sub)
        #expect(deleted(patch) == ["two"])
    }

    // MARK: headContents

    @Test func headContentsReturnsCommittedBytes() throws {
        let repo = TestRepo()
        repo.write("f.txt", "committed\n")
        repo.write("dir/bin.dat", Data([0, 255, 1, 2]))
        repo.commitAll()
        repo.write("f.txt", "edited\n")
        let snapshot = try repoSnapshot(repo)
        #expect(try scanner.headContents(path: "f.txt", in: snapshot) == Data("committed\n".utf8))
        #expect(try scanner.headContents(path: "dir/bin.dat", in: snapshot) == Data([0, 255, 1, 2]))
    }

    @Test func headContentsOfDeletedFile() throws {
        let repo = TestRepo()
        repo.write("gone.txt", "still in HEAD\n")
        repo.commitAll()
        repo.remove("gone.txt")
        let snapshot = try repoSnapshot(repo)
        #expect(try scanner.headContents(path: "gone.txt", in: snapshot) == Data("still in HEAD\n".utf8))
    }

    @Test func headContentsOfUnknownPathThrows() throws {
        let repo = TestRepo()
        repo.write("f.txt", "x\n")
        repo.commitAll()
        let snapshot = try repoSnapshot(repo)
        #expect(throws: GitError.self) {
            try scanner.headContents(path: "nope.txt", in: snapshot)
        }
    }
}
