import Testing
import MicroDiffCore

private func repo(
    _ name: String = "micro-diff", display: String = "", sub: Bool = false, branch: String = "main",
    _ changes: [FileChange]
) -> RepoSnapshot {
    RepoSnapshot(rootPath: "/w/" + display, displayPath: display, name: name, isSubmodule: sub,
                 branchLabel: branch, hasHead: true, changes: changes)
}

private func repo(_ changes: [FileChange]) -> RepoSnapshot { repo("micro-diff", changes) }

private func snap(_ repos: [RepoSnapshot]) -> WorkspaceSnapshot {
    WorkspaceSnapshot(rootPath: "/w", isGitRepo: !repos.isEmpty, repos: repos)
}

private func mod(_ p: String) -> FileChange { FileChange(path: p, kind: .modified) }

private func shape(_ rows: [TreeRow]) -> [String] {
    rows.map { "\($0.depth)\($0.kind == .repo ? "R" : $0.kind == .directory ? "D" : "F") \($0.name)" }
}

@Suite struct ChangesTreeTests {
    @Test func sampleDesign() {
        let root = repo([
            FileChange(path: "notes/old.txt", kind: .deleted),
            mod("src/app.rs"), mod("src/git/diff.rs"),
            FileChange(path: "src/ui/widgets/tree.rs", kind: .added),
        ])
        let sub = repo("vendor/libgit", display: "vendor/libgit", sub: true, branch: "dev",
                       [mod("include/git.h"), mod("src/status.c")])
        let tree = ChangesTree(snapshot: snap([root, sub]))
        let rows = tree.rows()
        #expect(shape(rows) == [
            "0R micro-diff", "1D notes", "2F old.txt", "1D src", "2D git", "3F diff.rs",
            "2D ui/widgets", "3F tree.rs", "2F app.rs",
            "0R vendor/libgit", "1D include", "2F git.h", "1D src", "2F status.c",
        ])
        #expect(rows[0].branch == "main")
        #expect(rows[9].branch == "dev")
        #expect(rows[9].isSubmodule && rows[9].gapBefore)
        #expect(!rows[0].gapBefore && !rows[0].isSubmodule)
        #expect(rows[2].change?.kind == .deleted)
        #expect(rows[6].path == "src/ui/widgets")
        #expect(rows[6].id == "0|d|src/ui/widgets")
        #expect(rows[11].repoIndex == 1)
        #expect(tree.fileCount == 6)
    }

    @Test func emptyAndBareRepo() {
        #expect(ChangesTree(snapshot: snap([])).rows().isEmpty)
        let rows = ChangesTree(snapshot: snap([repo([])])).rows()
        #expect(rows.count == 1)
        #expect(rows[0].kind == .repo && rows[0].isExpanded)
    }

    @Test func topLevelFiles() {
        let rows = ChangesTree(snapshot: snap([repo([mod("b.txt"), mod("A.txt")])])).rows()
        #expect(shape(rows) == ["0R micro-diff", "1F A.txt", "1F b.txt"])
        #expect(rows[1].path == "A.txt")
    }

    @Test func deepChainCompacts() {
        let rows = ChangesTree(snapshot: snap([repo([mod("a/b/c/d/file")])])).rows()
        #expect(shape(rows) == ["0R micro-diff", "1D a/b/c/d", "2F file"])
        #expect(rows[1].path == "a/b/c/d")
    }

    @Test func compactionStopsAtFileChild() {
        let rows = ChangesTree(snapshot: snap([repo([mod("a/x.txt"), mod("a/b/c/y.txt")])])).rows()
        #expect(shape(rows) == ["0R micro-diff", "1D a", "2D b/c", "3F y.txt", "2F x.txt"])
    }

    @Test func sortsDirectoriesFirstCaseInsensitive() {
        let rows = ChangesTree(snapshot: snap([repo([
            mod("zeta.txt"), mod("Beta/x"), mod("alpha/x"), mod("Alpha.txt"), mod("beta2/x"),
        ])])).rows()
        #expect(shape(rows) == [
            "0R micro-diff", "1D alpha", "2F x", "1D Beta", "2F x", "1D beta2", "2F x", "1F Alpha.txt", "1F zeta.txt",
        ])
    }

    @Test func collapsedDirectoryHidesDescendants() {
        let tree = ChangesTree(snapshot: snap([repo([mod("src/a.rs"), mod("src/g/b.rs"), mod("z.txt")])]))
        let rows = tree.rows(collapsed: ["0|d|src"])
        #expect(shape(rows) == ["0R micro-diff", "1D src", "1F z.txt"])
        #expect(rows[1].isExpanded == false)
        #expect(tree.rows()[1].isExpanded)
    }

    @Test func collapsedRepo() {
        let tree = ChangesTree(snapshot: snap([repo([mod("a/b.txt")]), repo("sub", display: "sub", sub: true, [mod("c.txt")])]))
        let rows = tree.rows(collapsed: ["0|r|"])
        #expect(shape(rows) == ["0R micro-diff", "0R sub", "1F c.txt"])
        #expect(rows[0].isExpanded == false)
        #expect(rows[1].isExpanded)
    }

    @Test func collapsingCompactedDirectoryById() {
        let tree = ChangesTree(snapshot: snap([repo([mod("ui/widgets/a.rs")])]))
        let rows = tree.rows(collapsed: ["0|d|ui/widgets"])
        #expect(shape(rows) == ["0R micro-diff", "1D ui/widgets"])
        #expect(rows[1].isExpanded == false)
        // The id of the first chain element is not the row id.
        #expect(tree.rows(collapsed: ["0|d|ui"]).count == 3)
    }

    @Test func renamedFilePlacedByNewPath() {
        let change = FileChange(path: "new/dir/f.txt", oldPath: "old/f.txt", kind: .renamed)
        let rows = ChangesTree(snapshot: snap([repo([change])])).rows()
        #expect(shape(rows) == ["0R micro-diff", "1D new/dir", "2F f.txt"])
        #expect(rows[2].change == change)
        #expect(rows[2].change?.oldPath == "old/f.txt")
    }

    @Test func idsAreUniqueAndStable() {
        let tree = ChangesTree(snapshot: snap([
            repo([mod("a/x"), mod("a/b/y"), mod("c")]),
            repo("s", display: "s", sub: true, [mod("a/x"), mod("a/b/y"), mod("c")]),
        ]))
        let first = tree.rows().map(\.id)
        #expect(Set(first).count == first.count)
        #expect(first == tree.rows().map(\.id))
        #expect(first.contains("0|f|a/x") && first.contains("1|f|a/x"))
    }

    @Test func gapOnlyAfterFirstRepo() {
        let tree = ChangesTree(snapshot: snap([
            repo([mod("a")]),
            repo("s1", display: "s1", sub: true, [mod("b")]),
            repo("s2", display: "s2", sub: true, [mod("c")]),
        ]))
        let gaps = tree.rows().filter { $0.gapBefore }.map(\.name)
        #expect(gaps == ["s1", "s2"])
    }

    @Test func largeInputCounts() {
        var changes: [FileChange] = []
        for i in 0..<10_000 { changes.append(mod("d\(i % 1000)/sub/f\(i).txt")) }
        let tree = ChangesTree(snapshot: snap([repo("micro-diff", changes)]))
        let rows = tree.rows()
        #expect(tree.fileCount == 10_000)
        #expect(rows.filter { $0.kind == .file }.count == 10_000)
        #expect(rows.filter { $0.kind == .directory }.count == 1000)
        #expect(rows.count == 1 + 1000 + 10_000)
        #expect(tree.rows(collapsed: ["0|r|"]).count == 1)
    }
}
