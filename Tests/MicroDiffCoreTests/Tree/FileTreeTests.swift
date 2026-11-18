import Testing
import MicroDiffCore

private func snap(
    _ root: String, changes: [FileChange] = [], subs: [(path: String, changes: [FileChange])] = [],
    branch: String = "main", git: Bool = true, ignored: [String] = [], subIgnored: [String: [String]] = [:]
) -> WorkspaceSnapshot {
    var repos: [RepoSnapshot] = []
    if git {
        repos.append(RepoSnapshot(rootPath: root, displayPath: "", name: "ws", isSubmodule: false,
                                  branchLabel: branch, hasHead: true, changes: changes, ignored: ignored))
    }
    for s in subs {
        repos.append(RepoSnapshot(rootPath: root + "/" + s.path, displayPath: s.path, name: s.path, isSubmodule: true,
                                  branchLabel: "dev", hasHead: true, changes: s.changes, ignored: subIgnored[s.path] ?? []))
    }
    return WorkspaceSnapshot(rootPath: root, isGitRepo: git, repos: repos, submodulePaths: subs.map(\.path))
}

private func names(_ rows: [TreeRow]) -> [String] { rows.map(\.path) }

@Suite struct DirectoryListerTests {
    @Test func sortsHidesAndMarksTypes() {
        let t = TempDir()
        t.mkdir("zdir"); t.mkdir("Adir"); t.mkdir(".git"); t.write(".DS_Store", "x")
        t.write("b.txt", ""); t.write("A.txt", ""); t.write(".env", "")
        let list = DirectoryLister.list(t.path)
        #expect(list.map(\.name) == ["Adir", "zdir", ".env", "A.txt", "b.txt"])
        #expect(list.prefix(2).allSatisfy { $0.isDirectory && !$0.isSymlink })
    }

    @Test func symlinksAreNeverFollowed() throws {
        let t = TempDir()
        t.mkdir("real")
        try makeSymlink(t.path + "/link", to: "real")
        try makeSymlink(t.path + "/loop", to: ".")
        let list = DirectoryLister.list(t.path)
        let link = try #require(list.first { $0.name == "link" })
        #expect(link.isSymlink && !link.isDirectory)
        #expect(list.first { $0.name == "loop" }?.isDirectory == false)
        #expect(list.first { $0.name == "real" }?.isDirectory == true)
    }

    @Test func unreadableOrMissingIsEmpty() {
        #expect(DirectoryLister.list("/nonexistent-microdiff-dir").isEmpty)
        let t = TempDir()
        t.write("file", "")
        #expect(DirectoryLister.list(t.path + "/file").isEmpty)
    }

    @Test func unicodeNames() {
        let t = TempDir()
        t.write("héllo wörld.txt", ""); t.write("日本語.md", ""); t.mkdir("папка")
        let list = DirectoryLister.list(t.path)
        #expect(Set(list.map(\.name)) == ["héllo wörld.txt", "日本語.md", "папка"])
        #expect(list[0].name == "папка")
    }

    @Test func largeDirectory() {
        let t = TempDir()
        for i in 0..<5000 { t.write("f\(i).txt", "") }
        let list = DirectoryLister.list(t.path)
        #expect(list.count == 5000)
        #expect(Set(list.map(\.name)).count == 5000)
    }
}

@Suite struct FileTreeTests {
    @Test func rootRowWithGit() {
        let t = TempDir()
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        let rows = tree.rows(snapshot: snap(t.path, branch: "feat"))
        #expect(rows.count == 1)
        #expect(rows[0].kind == .repo && rows[0].depth == 0 && rows[0].name == "ws" && rows[0].path == "")
        #expect(rows[0].branch == "feat" && rows[0].repoIndex == 0 && rows[0].isExpanded)
        #expect(rows[0].id == "0|r|")
    }

    @Test func rootRowWithoutGit() {
        let t = TempDir()
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        let root = tree.rows(snapshot: snap(t.path, git: false))[0]
        #expect(root.branch == nil && root.repoIndex == -1)
    }

    @Test func collapsedRootShowsOnlyRoot() {
        let t = TempDir()
        t.write("a.txt", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        tree.setExpanded(false, path: "")
        let rows = tree.rows(snapshot: snap(t.path))
        #expect(rows.count == 1 && rows[0].isExpanded == false)
        tree.setExpanded(true, path: "")
        #expect(tree.rows(snapshot: snap(t.path)).count == 2)
    }

    @Test func listsSortedWithDepthsAndHidden() {
        let t = TempDir()
        t.write("src/b.swift", ""); t.write("src/inner/c.swift", ""); t.write("a.txt", "")
        t.mkdir(".git"); t.write(".DS_Store", ""); t.write(".gitignore", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        tree.setExpanded(true, path: "src")
        tree.setExpanded(true, path: "src/inner")
        let rows = tree.rows(snapshot: snap(t.path))
        #expect(names(rows) == ["", "src", "src/inner", "src/inner/c.swift", "src/b.swift", ".gitignore", "a.txt"])
        #expect(rows.map(\.depth) == [0, 1, 2, 3, 2, 1, 1])
        #expect(rows[1].isExpanded && rows[1].name == "src" && rows[1].id == "0|d|src")
        #expect(rows.allSatisfy { $0.kind != .directory || $0.repoIndex == -1 })
    }

    @Test func collapsedDirectoryIsReadLazily() {
        let t = TempDir()
        t.write("sub/one.txt", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        let s = snap(t.path)
        #expect(names(tree.rows(snapshot: s)) == ["", "sub"])
        // If `sub` had been read while collapsed, its listing would be cached and this file would stay hidden.
        t.write("sub/two.txt", "")
        tree.setExpanded(true, path: "sub")
        #expect(names(tree.rows(snapshot: s)) == ["", "sub", "sub/one.txt", "sub/two.txt"])
    }

    @Test func cacheSurvivesCollapseAndInvalidateRefreshes() {
        let t = TempDir()
        t.write("sub/one.txt", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        let s = snap(t.path)
        tree.setExpanded(true, path: "sub")
        #expect(tree.rows(snapshot: s).count == 3)
        tree.setExpanded(false, path: "sub")
        t.write("sub/two.txt", "")
        tree.setExpanded(true, path: "sub")
        #expect(tree.rows(snapshot: s).count == 3)  // cached
        tree.invalidate()
        #expect(tree.expanded.contains("sub"))
        #expect(tree.rows(snapshot: s).count == 4)
    }

    @Test func fileChangesDecorateRows() {
        let t = TempDir()
        t.write("a.txt", ""); t.write("plain.txt", ""); t.write("new/name.txt", "")
        t.write("vendor/lib/inc/git.h", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        tree.setExpanded(true, path: "new")
        tree.setExpanded(true, path: "vendor"); tree.setExpanded(true, path: "vendor/lib"); tree.setExpanded(true, path: "vendor/lib/inc")
        let renamed = FileChange(path: "new/name.txt", oldPath: "old/name.txt", kind: .renamed)
        let s = snap(t.path, changes: [FileChange(path: "a.txt", kind: .modified), renamed],
                     subs: [("vendor/lib", [FileChange(path: "inc/git.h", kind: .added)])])
        let rows = tree.rows(snapshot: s)
        let byPath = Dictionary(uniqueKeysWithValues: rows.map { ($0.path, $0) })
        #expect(byPath["a.txt"]?.change?.kind == .modified && byPath["a.txt"]?.repoIndex == 0)
        #expect(byPath["plain.txt"]?.change == nil && byPath["plain.txt"]?.repoIndex == -1)
        #expect(byPath["new/name.txt"]?.change == renamed)
        #expect(byPath["vendor/lib/inc/git.h"]?.change?.kind == .added)
        #expect(byPath["vendor/lib/inc/git.h"]?.repoIndex == 1)
        // Ids do not depend on change state.
        #expect(byPath["a.txt"]?.id == "0|f|a.txt")
        #expect(byPath["vendor/lib/inc/git.h"]?.id == "0|f|vendor/lib/inc/git.h")
    }

    @Test func dirMarks() {
        let t = TempDir()
        t.write("single/a", ""); t.write("mixed/a", ""); t.write("mixed/b", ""); t.write("clean/a", "")
        t.write("gone/keep", ""); t.write("deep/x/y/z", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        let s = snap(t.path, changes: [
            FileChange(path: "single/a", kind: .added),
            FileChange(path: "mixed/a", kind: .added), FileChange(path: "mixed/b", kind: .deleted),
            FileChange(path: "gone/removed.txt", kind: .deleted),
            FileChange(path: "deep/x/y/z", kind: .conflicted),
        ])
        for d in ["deep", "deep/x", "deep/x/y"] { tree.setExpanded(true, path: d) }
        let rows = Dictionary(uniqueKeysWithValues: tree.rows(snapshot: s).map { ($0.path, $0) })
        #expect(rows["single"]?.dirMark == .added)
        #expect(rows["mixed"]?.dirMark == .modified)
        #expect(rows["clean"]?.dirMark == nil)
        #expect(rows["gone"]?.dirMark == .deleted)
        #expect(rows["deep"]?.dirMark == .conflicted)
        #expect(rows["deep/x/y"]?.dirMark == .conflicted)
        #expect(rows["a"] == nil)
    }

    @Test func ignoredEntriesAndEverythingInsideThem() {
        let t = TempDir()
        t.write("node_modules/p/index.js", ""); t.write("src/a.ts", ""); t.write("src/debug.log", ""); t.write(".env", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        for d in ["node_modules", "node_modules/p", "src"] { tree.setExpanded(true, path: d) }
        let s = snap(t.path, ignored: ["node_modules/", ".env", "src/debug.log"])
        let rows = Dictionary(uniqueKeysWithValues: tree.rows(snapshot: s).map { ($0.path, $0) })
        for p in ["node_modules", "node_modules/p", "node_modules/p/index.js", ".env", "src/debug.log"] {
            #expect(rows[p]?.isIgnored == true, "\(p)")
        }
        for p in ["src", "src/a.ts", ""] { #expect(rows[p]?.isIgnored == false, "\(p)") }
    }

    @Test func ignoredInsideSubmodule() {
        let t = TempDir()
        t.write("vendor/lib/dist/x.js", ""); t.write("vendor/lib/x.c", ""); t.write("dist/y.js", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        for d in ["vendor", "vendor/lib", "vendor/lib/dist", "dist"] { tree.setExpanded(true, path: d) }
        let s = snap(t.path, subs: [("vendor/lib", [FileChange(path: "x.c", kind: .modified)])], subIgnored: ["vendor/lib": ["dist/"]])
        let rows = Dictionary(uniqueKeysWithValues: tree.rows(snapshot: s).map { ($0.path, $0) })
        #expect(rows["vendor/lib/dist"]?.isIgnored == true)
        #expect(rows["vendor/lib/dist/x.js"]?.isIgnored == true)
        #expect(rows["vendor/lib/x.c"]?.isIgnored == false)
        #expect(rows["vendor/lib"]?.isIgnored == false)
        // The root repo's own `dist` is a different path and is not ignored.
        #expect(rows["dist"]?.isIgnored == false)
    }

    @Test func ignoredFolderNeverHasADirMarkAndOthersKeepTheirs() {
        let t = TempDir()
        t.write("build/a", ""); t.write("src/a", ""); t.write("src/b", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        let s = snap(t.path, changes: [
            FileChange(path: "build/a", kind: .modified),
            FileChange(path: "src/a", kind: .added), FileChange(path: "src/b", kind: .added),
        ], ignored: ["build/"])
        let rows = Dictionary(uniqueKeysWithValues: tree.rows(snapshot: s).map { ($0.path, $0) })
        #expect(rows["build"]?.dirMark == nil)
        #expect(rows["src"]?.dirMark == .added)
    }

    @Test func nothingIsIgnoredByDefault() {
        let t = TempDir()
        t.write("a/b", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        #expect(tree.rows(snapshot: snap(t.path)).allSatisfy { !$0.isIgnored })
    }

    @Test func submoduleDirectoryRows() {
        let t = TempDir()
        t.write("vendor/lib/x.c", ""); t.write("vendor/other/y.c", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        tree.setExpanded(true, path: "vendor")
        let s = snap(t.path, subs: [("vendor/lib", [FileChange(path: "x.c", kind: .modified)])])
        let rows = Dictionary(uniqueKeysWithValues: tree.rows(snapshot: s).map { ($0.path, $0) })
        #expect(rows["vendor/lib"]?.isSubmodule == true)
        #expect(rows["vendor/lib"]?.dirMark == .modified)
        #expect(rows["vendor/other"]?.isSubmodule == false)
        #expect(rows["vendor"]?.isSubmodule == false)
        #expect(rows["vendor"]?.dirMark == .modified)
    }

    @Test func revealExpandsAncestors() {
        let t = TempDir()
        t.write("a/b/c/file.txt", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        tree.setExpanded(false, path: "")
        tree.reveal(path: "a/b/c/file.txt")
        #expect(tree.expanded == ["", "a", "a/b", "a/b/c"])
        #expect(names(tree.rows(snapshot: snap(t.path))) == ["", "a", "a/b", "a/b/c", "a/b/c/file.txt"])
    }

    @Test func vanishedDirectoryIsDropped() {
        let t = TempDir()
        t.write("gone/f.txt", ""); t.write("stay.txt", "")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        let s = snap(t.path)
        tree.setExpanded(true, path: "gone")
        #expect(tree.rows(snapshot: s).count == 4)
        t.remove("gone")
        tree.invalidate()
        #expect(names(tree.rows(snapshot: s)) == ["", "stay.txt"])
    }

    @Test func expandedDirDeletedWithoutInvalidateDoesNotCrash() {
        let t = TempDir()
        t.mkdir("gone/inner")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        tree.setExpanded(true, path: "gone"); tree.setExpanded(true, path: "gone/inner")
        _ = tree.rows(snapshot: snap(t.path))
        t.remove("gone")
        tree.setExpanded(true, path: "never/existed")
        #expect(tree.rows(snapshot: snap(t.path)).count == 3)
    }

    @Test func symlinkEntryIsAFileRow() throws {
        let t = TempDir()
        t.mkdir("real")
        try makeSymlink(t.path + "/link", to: "real")
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        let rows = tree.rows(snapshot: snap(t.path))
        #expect(rows.first { $0.path == "link" }?.kind == .file)
        #expect(rows.first { $0.path == "real" }?.kind == .directory)
    }

    @Test func unicodeAndLargeDirectory() {
        let t = TempDir()
        t.write("日本/ファイル.txt", "")
        for i in 0..<5000 { t.write("big/f\(i).txt", "") }
        var tree = FileTree(rootPath: t.path, rootName: "ws")
        tree.setExpanded(true, path: "日本")
        tree.setExpanded(true, path: "big")
        let rows = tree.rows(snapshot: snap(t.path))
        #expect(rows.count == 1 + 2 + 1 + 5000)
        #expect(rows.contains { $0.path == "日本/ファイル.txt" })
        #expect(Set(rows.map(\.id)).count == rows.count)
    }
}
