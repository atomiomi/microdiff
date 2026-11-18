import MicroDiffCore
import Testing

/// Changes tab and files tab with nested repositories (synthetic snapshots, no git).
@Suite("Trees: nested repositories")
struct NestedRepoTreeTests {
    private func snapshot(
        _ root: String, rootChanges: [FileChange] = [], nested: [(path: String, changes: [FileChange], ignored: [String])] = [],
        submodules: [(path: String, changes: [FileChange])] = [], nestedPaths: [String]? = nil, ignored: [String] = []
    ) -> WorkspaceSnapshot {
        var repos = [RepoSnapshot(rootPath: root, displayPath: "", name: "ws", isSubmodule: false, branchLabel: "main", hasHead: true, changes: rootChanges, ignored: ignored)]
        for n in nested {
            repos.append(RepoSnapshot(rootPath: root + "/" + n.path, displayPath: n.path, name: n.path, isSubmodule: false, branchLabel: "dev", hasHead: true, changes: n.changes, ignored: n.ignored, isNested: true))
        }
        for s in submodules {
            repos.append(RepoSnapshot(rootPath: root + "/" + s.path, displayPath: s.path, name: s.path, isSubmodule: true, branchLabel: "sub", hasHead: true, changes: s.changes))
        }
        repos.sort { $0.displayPath < $1.displayPath }
        return WorkspaceSnapshot(
            rootPath: root, isGitRepo: true, repos: repos, submodulePaths: submodules.map(\.path),
            nestedRepoPaths: nestedPaths ?? nested.map(\.path))
    }

    // MARK: changes tab

    @Test func nestedRepoIsASectionWithItsOwnBranchAndNotASubmodule() {
        let s = snapshot("/ws", rootChanges: [FileChange(path: "a.txt", kind: .modified)],
                         nested: [("inner", [FileChange(path: "src/x.ts", kind: .added)], [])])
        let rows = ChangesTree(snapshot: s).rows()
        let sections = rows.filter { $0.kind == .repo }
        #expect(sections.map(\.name) == ["ws", "inner"])
        #expect(sections[1].branch == "dev" && !sections[1].isSubmodule && sections[1].gapBefore)
        #expect(sections[1].repoIndex == 1)
        #expect(rows.contains { $0.kind == .file && $0.path == "src/x.ts" && $0.repoIndex == 1 })
        // The parent has no row for the folder.
        #expect(!rows.contains { $0.repoIndex == 0 && $0.path.hasPrefix("inner") })
    }

    @Test func cleanNestedRepoHasNoSection() {
        let s = snapshot("/ws", rootChanges: [FileChange(path: "a.txt", kind: .modified)], nested: [("inner", [], [])].filter { _ in false })
        let withClean = WorkspaceSnapshot(rootPath: "/ws", isGitRepo: true, repos: s.repos, nestedRepoPaths: ["inner"])
        #expect(ChangesTree(snapshot: withClean).rows().filter { $0.kind == .repo }.count == 1)
    }

    @Test func sectionsAreOrderedByPathTogetherWithSubmodules() {
        let s = snapshot("/ws", nested: [("zeta", [FileChange(path: "z", kind: .added)], []), ("alpha", [FileChange(path: "a", kind: .added)], [])],
                         submodules: [("middle", [FileChange(path: "m", kind: .modified)])])
        let rows = ChangesTree(snapshot: s).rows()
        #expect(rows.filter { $0.kind == .repo }.map(\.name) == ["ws", "alpha", "middle", "zeta"])
        #expect(rows.filter { $0.kind == .repo }.map(\.isSubmodule) == [false, false, true, false])
    }

    @Test func fileCountCountsTheNestedFilesOnly() {
        let s = snapshot("/ws", rootChanges: [FileChange(path: "a.txt", kind: .modified)],
                         nested: [("inner", [FileChange(path: "x", kind: .added), FileChange(path: "y", kind: .deleted)], [])])
        #expect(s.totalChangeCount == 3)
        #expect(ChangesTree(snapshot: s).fileCount == 3)
        #expect(ChangesTree(snapshot: s).rows().filter { $0.kind == .file }.count == 3)
    }

    // MARK: files tab

    @Test func nestedRepoFolderIsFlaggedAndMarkedLikeASubmodule() {
        let t = TempDir()
        t.write("inner/src/x.ts", ""); t.write("inner/clean.txt", ""); t.write("plain/f", ""); t.write("main.txt", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        tree.setExpanded(true, path: "inner")
        let s = snapshot(t.path, nested: [("inner", [FileChange(path: "src/x.ts", kind: .modified)], [])])
        let rows = Dictionary(uniqueKeysWithValues: tree.rows(snapshot: s).map { ($0.path, $0) })
        #expect(rows["inner"]?.isNestedRepo == true && rows["inner"]?.isSubmodule == false)
        #expect(rows["inner"]?.dirMark == .modified)
        #expect(rows["inner/src"]?.isNestedRepo == false && rows["inner/src"]?.dirMark == .modified)
        #expect(rows["plain"]?.isNestedRepo == false && rows["plain"]?.dirMark == nil)
        #expect(rows["inner/src/x.ts"] == nil)
    }

    @Test func cleanNestedRepoFolderIsFlaggedWithoutAMark() {
        let t = TempDir()
        t.write("inner/a.txt", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        let s = WorkspaceSnapshot(rootPath: t.path, isGitRepo: true,
            repos: [RepoSnapshot(rootPath: t.path, displayPath: "", name: "ws", isSubmodule: false, branchLabel: "main", hasHead: true, changes: [])],
            nestedRepoPaths: ["inner"])
        let row = tree.rows(snapshot: s).first { $0.path == "inner" }
        #expect(row?.isNestedRepo == true && row?.dirMark == nil && row?.isIgnored == false)
    }

    @Test func submoduleFolderIsNotANestedRepo() {
        let t = TempDir()
        t.write("vendor/lib/x.c", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        tree.setExpanded(true, path: "vendor")
        let s = snapshot(t.path, submodules: [("vendor/lib", [FileChange(path: "x.c", kind: .modified)])])
        let row = tree.rows(snapshot: s).first { $0.path == "vendor/lib" }
        #expect(row?.isSubmodule == true && row?.isNestedRepo == false)
    }

    @Test func ignoredNestedRepoStaysIgnoredAndIsNotARepo() {
        let t = TempDir()
        t.write("inner/a.txt", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        tree.setExpanded(true, path: "inner")
        // The parent ignores it, so git never reports it as a nested repo.
        let s = snapshot(t.path, nestedPaths: [], ignored: ["inner/"])
        let rows = Dictionary(uniqueKeysWithValues: tree.rows(snapshot: s).map { ($0.path, $0) })
        #expect(rows["inner"]?.isIgnored == true && rows["inner"]?.isNestedRepo == false && rows["inner"]?.dirMark == nil)
        #expect(rows["inner/a.txt"]?.isIgnored == true)
    }

    @Test func ignoredEntriesInsideANestedRepoAreDimmed() {
        let t = TempDir()
        t.write("inner/node_modules/p/i.js", ""); t.write("inner/a.txt", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        tree.setExpanded(true, path: "inner")
        let s = snapshot(t.path, nested: [("inner", [FileChange(path: "a.txt", kind: .modified)], ["node_modules/"])])
        let rows = Dictionary(uniqueKeysWithValues: tree.rows(snapshot: s).map { ($0.path, $0) })
        #expect(rows["inner/node_modules"]?.isIgnored == true)
        #expect(rows["inner/a.txt"]?.isIgnored == false && rows["inner/a.txt"]?.change?.kind == .modified)
        #expect(rows["inner/a.txt"]?.repoIndex == 1)
    }
}
