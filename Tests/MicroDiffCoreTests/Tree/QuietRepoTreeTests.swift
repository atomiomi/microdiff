import MicroDiffCore
import Testing

/// The changes tree and nested repositories without changes: a header alone, only when asked for.
@Suite("ChangesTree: quiet repositories")
struct QuietRepoTreeTests {
    private func repo(_ name: String, changes: [String] = []) -> RepoSnapshot {
        RepoSnapshot(
            rootPath: "/w/" + name, displayPath: name == "root" ? "" : name, name: name, isSubmodule: false, branchLabel: "main",
            hasHead: true, changes: changes.map { FileChange(path: $0, kind: .modified) }, isNested: name != "root")
    }

    private func snapshot(_ repos: [RepoSnapshot], quiet: [RepoSnapshot]) -> WorkspaceSnapshot {
        WorkspaceSnapshot(rootPath: "/w/root", isGitRepo: true, repos: repos, quietRepos: quiet)
    }

    private func headers(_ rows: [TreeRow]) -> [String] { rows.filter { $0.kind == .repo }.map(\.name) }

    @Test func aQuietRepositoryIsNotListedUnlessAskedFor() {
        let tree = ChangesTree(snapshot: snapshot([repo("root", changes: ["a.txt"])], quiet: [repo("b-quiet")]))
        #expect(headers(tree.rows()) == ["root"])
        #expect(headers(tree.rows(listedQuiet: [])) == ["root"])
    }

    @Test func aListedQuietRepositoryIsAHeaderAloneWithTheGapBeforeIt() {
        let tree = ChangesTree(snapshot: snapshot([repo("root", changes: ["a.txt"])], quiet: [repo("b-quiet")]))
        let rows = tree.rows(listedQuiet: ["/w/b-quiet"])
        #expect(rows.map(\.kind) == [.repo, .file, .repo])
        let header = rows[2]
        #expect(header.name == "b-quiet" && header.branch == "main" && header.depth == 0 && header.path == "")
        #expect(header.gapBefore)
        #expect(header.repoIndex == 1, "counted on after the repositories with changes")
        #expect(header.id == TreeRow.makeID(repoIndex: 1, kind: .repo, path: ""))
        #expect(!rows[0].gapBefore)
    }

    @Test func theRootWithoutChangesAndAListedQuietRepositoryAreTwoHeaders() {
        let tree = ChangesTree(snapshot: snapshot([repo("root")], quiet: [repo("q")]))
        let rows = tree.rows(listedQuiet: ["/w/q"])
        #expect(headers(rows) == ["root", "q"])
        #expect(rows.count == 2)
        #expect(tree.fileCount == 0)
    }

    @Test func quietRepositoriesSitAmongTheSectionsByDisplayPath() {
        let tree = ChangesTree(snapshot: snapshot(
            [repo("root"), repo("b-changed", changes: ["x.txt"]), repo("d-changed", changes: ["y.txt"])],
            quiet: [repo("a-quiet"), repo("c-quiet"), repo("e-quiet")]))
        let rows = tree.rows(listedQuiet: ["/w/a-quiet", "/w/c-quiet", "/w/e-quiet"])
        #expect(headers(rows) == ["root", "a-quiet", "b-changed", "c-quiet", "d-changed", "e-quiet"])
        let some = tree.rows(listedQuiet: ["/w/c-quiet"])
        #expect(headers(some) == ["root", "b-changed", "c-quiet", "d-changed"])
        #expect(some.filter { $0.kind == .repo }.map(\.gapBefore) == [false, true, true, true])
    }

    @Test func aFoldedStateOfASectionStillWorksNextToQuietOnes() {
        let tree = ChangesTree(snapshot: snapshot([repo("root", changes: ["a.txt"])], quiet: [repo("q")]))
        let id = TreeRow.makeID(repoIndex: 0, kind: .repo, path: "")
        let rows = tree.rows(collapsed: [id], listedQuiet: ["/w/q"])
        #expect(rows.map(\.kind) == [.repo, .repo])
    }
}
