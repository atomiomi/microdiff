import Testing
import MicroDiffCore

@Suite("Models")
struct ModelsTests {
    @Test("status letters match the design", arguments: [
        (ChangeKind.modified, "M"),
        (.added, "A"),
        (.deleted, "D"),
        (.renamed, "R"),
        (.conflicted, "U"),
    ])
    func letters(kind: ChangeKind, letter: String) {
        #expect(kind.letter == letter)
    }

    @Test("total change count sums every repo")
    func totalCount() {
        let a = RepoSnapshot(rootPath: "/w", displayPath: "", name: "w", isSubmodule: false, branchLabel: "main", hasHead: true,
                             changes: [FileChange(path: "a", kind: .modified), FileChange(path: "b", kind: .added)])
        let b = RepoSnapshot(rootPath: "/w/sub", displayPath: "sub", name: "sub", isSubmodule: true, branchLabel: "dev", hasHead: true,
                             changes: [FileChange(path: "c", kind: .deleted)])
        let snap = WorkspaceSnapshot(rootPath: "/w", isGitRepo: true, repos: [a, b])
        #expect(snap.totalChangeCount == 3)
    }

    @Test("tree sort ignores ASCII case and is total")
    func treeSort() {
        #expect(TreeSort.lessThan("apple", "Banana"))
        #expect(TreeSort.lessThan("Apple", "banana"))
        #expect(!TreeSort.lessThan("b", "A"))
        #expect(TreeSort.lessThan("a", "ab"))
        // Same letters, different case: byte order decides, and exactly one direction is true.
        #expect(TreeSort.lessThan("A", "a") != TreeSort.lessThan("a", "A"))
        #expect(!TreeSort.lessThan("same", "same"))
    }
}
