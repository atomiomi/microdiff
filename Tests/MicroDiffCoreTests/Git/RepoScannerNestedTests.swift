import MicroDiffCore
import Testing

/// A folder that is its own git repository, untracked in its parent and not a submodule.
@Suite("RepoScanner: nested repositories")
struct RepoScannerNestedTests {
    private let scanner = RepoScanner()

    private func scan(_ repo: TestRepo) -> WorkspaceSnapshot { scanner.scan(root: repo.path) }

    /// A parent with `main.txt` committed and a committed nested repo at `path` holding `a.txt`, `b.txt` and `dir/c.txt`.
    private func parentWithNested(at path: String = "inner") -> TestRepo {
        let repo = TestRepo()
        repo.write("main.txt", "m\n")
        repo.commitAll("parent")
        repo.git("init", "--quiet", path)
        repo.write(path + "/a.txt", "a1\na2\n")
        repo.write(path + "/b.txt", "b1\n")
        repo.write(path + "/dir/c.txt", "c1\n")
        repo.commitAll("nested", in: path)
        return repo
    }

    @Test func modifiedFileInsideGetsItsOwnSection() throws {
        let repo = parentWithNested()
        repo.write("inner/a.txt", "a1\nchanged\n")
        let snapshot = scan(repo)
        #expect(snapshot.repos.count == 2)
        let nested = snapshot.repos[1]
        #expect(nested.isNested && !nested.isSubmodule)
        #expect(nested.displayPath == "inner" && nested.name == "inner")
        #expect(nested.rootPath == repo.path + "/inner")
        #expect(nested.branchLabel == "main" && nested.hasHead)
        #expect(nested.changes == [FileChange(path: "a.txt", kind: .modified)])
        // The parent has nothing, and in particular no entry for the folder.
        #expect(snapshot.repos[0].changes.isEmpty && !snapshot.repos[0].isNested)
        #expect(snapshot.nestedRepoPaths == ["inner"])
        #expect(snapshot.submodulePaths.isEmpty)
        #expect(snapshot.totalChangeCount == 1)
    }

    @Test func addedAndDeletedFilesInside() {
        let repo = parentWithNested()
        repo.write("inner/new.txt", "n\n")
        repo.remove("inner/b.txt")
        let nested = scan(repo).repos[1]
        #expect(Set(nested.changes) == [
            FileChange(path: "new.txt", kind: .added, isUntracked: true), FileChange(path: "b.txt", kind: .deleted),
        ])
    }

    @Test func parentChangesStayInTheParent() {
        let repo = parentWithNested()
        repo.write("main.txt", "changed\n")
        repo.write("inner/a.txt", "x\n")
        let snapshot = scan(repo)
        #expect(snapshot.repos.map(\.displayPath) == ["", "inner"])
        #expect(snapshot.repos[0].changes == [FileChange(path: "main.txt", kind: .modified)])
        #expect(snapshot.totalChangeCount == 2)
    }

    @Test func cleanNestedRepoHasNoSectionButIsKnown() {
        let snapshot = scan(parentWithNested())
        #expect(snapshot.repos.count == 1)
        #expect(snapshot.nestedRepoPaths == ["inner"])
        #expect(snapshot.totalChangeCount == 0)
    }

    @Test func nestedRepoWithoutCommits() throws {
        let repo = TestRepo()
        repo.write("main.txt", "m\n")
        repo.commitAll("parent")
        repo.git("init", "--quiet", "fresh")
        repo.write("fresh/one.txt", "1\n")
        let snapshot = scan(repo)
        let nested = try #require(snapshot.repos.last)
        #expect(nested.displayPath == "fresh" && nested.isNested)
        #expect(nested.branchLabel == "no commits" && !nested.hasHead)
        #expect(nested.changes == [FileChange(path: "one.txt", kind: .added, isUntracked: true)])
        // Without a HEAD there is nothing to diff against.
        let patch = try scanner.patch(for: nested.changes[0], in: nested)
        #expect(patch.hunks.isEmpty)
    }

    @Test func emptyNestedRepoWithoutCommitsIsKnownAndHasNoSection() {
        let repo = TestRepo()
        repo.write("main.txt", "m\n")
        repo.commitAll("parent")
        repo.git("init", "--quiet", "empty")
        let snapshot = scan(repo)
        #expect(snapshot.repos.count == 1)
        #expect(snapshot.nestedRepoPaths == ["empty"])
    }

    @Test func nestedRepoTwoFoldersDeep() throws {
        let repo = TestRepo()
        repo.write("main.txt", "m\n")
        repo.commitAll("parent")
        repo.git("init", "--quiet", "tools/vendor/lib")
        repo.write("tools/vendor/lib/x.txt", "x\n")
        repo.commitAll("lib", in: "tools/vendor/lib")
        repo.write("tools/vendor/lib/x.txt", "x2\n")
        repo.write("tools/other.txt", "o\n")
        let snapshot = scan(repo)
        #expect(snapshot.nestedRepoPaths == ["tools/vendor/lib"])
        let nested = try #require(snapshot.repos.first { $0.isNested })
        #expect(nested.displayPath == "tools/vendor/lib" && nested.name == "tools/vendor/lib")
        #expect(nested.changes == [FileChange(path: "x.txt", kind: .modified)])
        // The plain untracked file next to it is still the parent's.
        #expect(snapshot.repos[0].changes == [FileChange(path: "tools/other.txt", kind: .added, isUntracked: true)])
    }

    @Test func nestedRepoNextToARealSubmodule() throws {
        let lib = TestRepo()
        lib.write("lib.txt", "l\n")
        lib.commitAll("lib")
        let repo = TestRepo()
        repo.write("main.txt", "m\n")
        repo.addSubmodule(from: lib, at: "vendor/lib")
        repo.commitAll("with submodule")
        repo.git("init", "--quiet", "alpha")
        repo.write("alpha/a.txt", "a\n")
        repo.commitAll("alpha", in: "alpha")
        repo.write("alpha/a.txt", "a2\n")
        repo.write("vendor/lib/lib.txt", "l2\n")
        let snapshot = scan(repo)
        #expect(snapshot.repos.map(\.displayPath) == ["", "alpha", "vendor/lib"])
        #expect(snapshot.repos.map(\.isSubmodule) == [false, false, true])
        #expect(snapshot.repos.map(\.isNested) == [false, true, false])
        #expect(snapshot.submodulePaths == ["vendor/lib"])
        #expect(snapshot.nestedRepoPaths == ["alpha"])
        #expect(snapshot.totalChangeCount == 2)
    }

    @Test func nestedRepoThatTheParentIgnoresIsNotFound() {
        let repo = TestRepo()
        repo.write(".gitignore", "inner/\n")
        repo.write("main.txt", "m\n")
        repo.commitAll("parent")
        repo.git("init", "--quiet", "inner")
        repo.write("inner/a.txt", "a\n")
        let snapshot = scan(repo)
        #expect(snapshot.repos.count == 1)
        #expect(snapshot.nestedRepoPaths.isEmpty)
        #expect(snapshot.repos[0].ignored.contains("inner/"))
        #expect(snapshot.totalChangeCount == 0)
    }

    @Test func nestedRepoInsideANestedRepo() throws {
        let repo = parentWithNested()
        repo.git("init", "--quiet", "inner/deeper")
        repo.write("inner/deeper/d.txt", "d\n")
        let snapshot = scan(repo)
        #expect(snapshot.nestedRepoPaths == ["inner", "inner/deeper"])
        let deeper = try #require(snapshot.repos.first { $0.displayPath == "inner/deeper" })
        #expect(deeper.isNested && deeper.changes == [FileChange(path: "d.txt", kind: .added, isUntracked: true)])
        // The inner repo has no entry of its own for the folder.
        #expect(snapshot.repos.first { $0.displayPath == "inner" } == nil)
    }

    @Test func nestingStopsAtTheDepthCap() {
        let repo = TestRepo()
        repo.write("main.txt", "m\n")
        repo.commitAll("parent")
        var path = "n1"
        for level in 2...(RepoScanner.maxSubmoduleDepth + 2) {
            repo.git("init", "--quiet", path)
            repo.write(path + "/f\(level).txt", "x\n")
            path += "/n\(level)"
        }
        let snapshot = scan(repo)
        #expect(snapshot.nestedRepoPaths.count == RepoScanner.maxSubmoduleDepth)
        #expect(snapshot.repos.count == 1 + RepoScanner.maxSubmoduleDepth)
    }

    @Test func folderRemovedBetweenScans() {
        let repo = parentWithNested()
        repo.write("inner/a.txt", "changed\n")
        #expect(scan(repo).repos.count == 2)
        repo.remove("inner")
        let after = scan(repo)
        #expect(after.repos.count == 1)
        #expect(after.nestedRepoPaths.isEmpty)
        #expect(after.totalChangeCount == 0)
    }

    @Test func filesInsideDiffAgainstTheNestedHead() throws {
        let repo = parentWithNested()
        repo.write("inner/a.txt", "a1\nchanged\n")
        let nested = scan(repo).repos[1]
        let patch = try scanner.patch(for: nested.changes[0], in: nested)
        #expect(patch.hunks.count == 1)
        let head = try scanner.headContents(path: "a.txt", in: nested)
        #expect(String(decoding: head, as: UTF8.self) == "a1\na2\n")
    }

    @Test func nestedRepoCostsOneGitCallMore() {
        // Same result as a dirty submodule: the section appears and the parent keeps working when the repo is clean.
        let repo = parentWithNested()
        let clean = scan(repo)
        repo.write("inner/b.txt", "x\n")
        let dirty = scan(repo)
        #expect(clean.repos.count == 1 && dirty.repos.count == 2)
        #expect(clean.nestedRepoPaths == dirty.nestedRepoPaths)
    }
}
