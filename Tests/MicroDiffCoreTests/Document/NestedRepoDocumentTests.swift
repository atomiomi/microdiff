import MicroDiffCore
import Testing

/// Files inside a nested repository open and diff against the NESTED repository's HEAD.
@Suite("DocumentLoader: nested repositories")
struct NestedRepoDocumentTests {
    private func fixture() -> (repo: TestRepo, nested: RepoSnapshot) {
        let repo = TestRepo()
        repo.write("main.txt", "m\n")
        repo.commitAll("parent")
        repo.git("init", "--quiet", "inner")
        repo.write("inner/a.txt", "one\ntwo\nthree\n")
        repo.commitAll("nested", in: "inner")
        repo.write("inner/a.txt", "one\nTWO\nthree\nfour\n")
        repo.write("inner/new.txt", "fresh\n")
        let snapshot = RepoScanner().scan(root: repo.path)
        return (repo, snapshot.repos[1])
    }

    private func load(_ nested: RepoSnapshot, _ path: String, _ mode: ViewMode) -> TextDocument? {
        let change = nested.changes.first { $0.path == path }
        let request = DocumentRequest(path: nested.rootPath + "/" + path, repo: nested, change: change, mode: mode)
        if case .text(let document) = DocumentLoader().load(request) { return document }
        return nil
    }

    private func lines(_ buffer: TextBuffer) -> [String] { (0..<buffer.lineCount).map { buffer.line($0) } }

    @Test func diffModeShowsTheChangeAgainstTheNestedHead() throws {
        let (repo, nested) = fixture()
        defer { withExtendedLifetime(repo) {} }
        let document = try #require(load(nested, "a.txt", .diff))
        #expect(lines(document.newText) == ["one", "TWO", "three", "four"])
        #expect(lines(document.oldText) == ["two"])
        #expect(document.patch.hunks.count == 2)
    }

    @Test func fileModeShowsTheWholeFile() throws {
        let (repo, nested) = fixture()
        defer { withExtendedLifetime(repo) {} }
        let document = try #require(load(nested, "a.txt", .read))
        #expect(lines(document.newText) == ["one", "TWO", "three", "four"])
        #expect(document.rows.rowCount == 4)
    }

    @Test func untrackedFileInsideOpensAsANewFile() throws {
        let (repo, nested) = fixture()
        defer { withExtendedLifetime(repo) {} }
        let document = try #require(load(nested, "new.txt", .diff))
        #expect(lines(document.newText) == ["fresh"])
        #expect(document.patch.hunks.isEmpty)
    }

    @Test func nestedRepoWithoutCommitsOpensItsFiles() throws {
        let repo = TestRepo()
        repo.write("main.txt", "m\n")
        repo.commitAll("parent")
        repo.git("init", "--quiet", "fresh")
        repo.write("fresh/f.txt", "x\ny\n")
        let nested = RepoScanner().scan(root: repo.path).repos[1]
        let document = try #require(load(nested, "f.txt", .diff))
        #expect(lines(document.newText) == ["x", "y"])
    }
}
