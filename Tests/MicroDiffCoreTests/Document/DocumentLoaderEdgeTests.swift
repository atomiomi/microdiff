import MicroDiffCore
import Testing

/// Odd files and odd repositories, loaded the way a tab loads them.
@Suite("DocumentLoader: edge cases")
struct DocumentLoaderEdgeTests {
    private let loader = DocumentLoader()

    private func load(_ repo: TestRepo, _ path: String, mode: ViewMode = .diff) -> DocumentContent {
        let snapshot = RepoScanner().scan(root: repo.path).repos[0]
        return loader.load(DocumentRequest(
            path: repo.path + "/" + path, repo: snapshot, change: snapshot.changes.first { $0.path == path }, mode: mode))
    }

    private func textDocument(_ content: DocumentContent) throws -> TextDocument {
        guard case let .text(document) = content else {
            Issue.record("expected text, got \(content)")
            throw CancellationError()
        }
        return document
    }

    @Test func fileWithInvalidUTF8LoadsAsTextWithReplacementCharacters() throws {
        let repo = TestRepo()
        repo.write("latin.txt", Data("caf\u{E9}\nplain\n".utf8))
        repo.commitAll("first")
        // 0xE9 alone, 0xFF and a cut-off multi-byte sequence are not valid UTF-8.
        var bytes = Data("caf".utf8)
        bytes.append(contentsOf: [0xE9, 0x0A, 0xFF, 0xFE, 0x0A])
        bytes.append(contentsOf: Data("cut ".utf8))
        bytes.append(contentsOf: [0xE6, 0x97, 0x0A])
        repo.write("latin.txt", bytes)

        let document = try textDocument(load(repo, "latin.txt", mode: .read))
        #expect(document.newText.lineCount == 3)
        #expect(document.newText.line(0) == "caf\u{FFFD}")
        #expect(document.newText.line(1) == "\u{FFFD}\u{FFFD}")
        #expect(document.newText.line(2).hasPrefix("cut "))
        // The bytes on disk are what the buffer keeps.
        #expect(document.newText.data == bytes)
    }

    @Test func untrackedFileWithInvalidUTF8IsPlainText() throws {
        let repo = TestRepo()
        repo.write("keep.txt", "x\n")
        repo.commitAll("first")
        repo.write("raw.txt", Data([0x61, 0xC3, 0x28, 0x0A]))
        let document = try textDocument(load(repo, "raw.txt"))
        #expect(document.kind == .plain)
        #expect(document.newText.lineCount == 1)
    }

    @Test func modifiedFileWithSpacesAndNonASCIIInItsPathShowsItsDiff() throws {
        let path = "my docs/h\u{E9}llo w\u{F6}rld \u{65E5}\u{672C}.txt"
        let repo = TestRepo()
        repo.write(path, "one\ntwo\nthree\n")
        repo.commitAll("first")
        repo.write(path, "one\nTWO\nthree\n")

        let document = try textDocument(load(repo, path))
        #expect(document.kind == .diff)
        #expect(document.patch.hunks.count == 1)
        #expect(document.oldText.line(0) == "two")
        #expect(document.newText.line(1) == "TWO")
    }

    @Test func deletedFileWithSpacesAndNonASCIIInItsPathShowsItsOldContents() throws {
        let path = "caf\u{E9} menu/na\u{EF}ve file.txt"
        let repo = TestRepo()
        repo.write(path, "old a\nold b\n")
        repo.commitAll("first")
        repo.remove(path)

        let document = try textDocument(load(repo, path))
        #expect(document.kind == .deleted)
        #expect(document.oldText.lineCount == 2)
        #expect(document.oldText.line(1) == "old b")
    }

    @Test func conflictedFileLoadsAsTextWithItsConflictMarkers() throws {
        let repo = TestRepo()
        repo.write("a.txt", "base\n")
        repo.commitAll("first")
        repo.git("checkout", "--quiet", "-b", "other")
        repo.write("a.txt", "other side\n")
        repo.commitAll("other")
        repo.git("checkout", "--quiet", "main")
        repo.write("a.txt", "main side\n")
        repo.commitAll("main")
        #expect(!repo.tryGit("merge", "other"))

        for mode in [ViewMode.diff, .read] {
            let document = try textDocument(load(repo, "a.txt", mode: mode))
            let lines = (0..<document.newText.lineCount).map { document.newText.line($0) }
            #expect(lines.first?.hasPrefix("<<<<<<<") == true)
            #expect(lines.contains("main side"))
            #expect(lines.contains("other side"))
            #expect(document.rows.rowCount > 0)
        }
    }

    @Test func fileInsideASubmoduleIsDiffedAgainstTheSubmodulesOwnHead() throws {
        let lib = TestRepo()
        lib.write("lib.txt", "one\ntwo\n")
        lib.commitAll("lib")
        let repo = TestRepo()
        repo.write("main.txt", "m\n")
        repo.addSubmodule(from: lib, at: "vendor/lib")
        repo.commitAll("with submodule")
        repo.write("vendor/lib/lib.txt", "one\nTWO\n")

        let snapshot = RepoScanner().scan(root: repo.path)
        let sub = try #require(snapshot.repos.last)
        #expect(sub.isSubmodule)
        let change = try #require(sub.changes.first)
        let document = try textDocument(loader.load(DocumentRequest(
            path: sub.rootPath + "/" + change.path, repo: sub, change: change, mode: .diff)))
        #expect(document.kind == .diff)
        #expect(document.oldText.line(0) == "two")
        #expect(document.newText.line(1) == "TWO")
    }

    @Test func fileInAnEmptyRepositoryWithoutCommitsIsPlain() throws {
        let repo = TestRepo()
        repo.write("first.txt", "hello\n")
        let document = try textDocument(load(repo, "first.txt"))
        #expect(document.kind == .plain)
        #expect(document.newText.line(0) == "hello")
    }

    @Test func crlfFileWithOneEditedLineKeepsLineCountsInDiffMode() throws {
        let repo = TestRepo()
        repo.write("w.txt", "a\r\nb\r\nc\r\n")
        repo.commitAll("first")
        repo.write("w.txt", "a\r\nB\r\nc\r\n")
        let document = try textDocument(load(repo, "w.txt"))
        #expect(document.kind == .diff)
        #expect(document.newText.line(1) == "B")
        #expect(document.oldText.line(0) == "b")
        #expect(document.patch.hunks.count == 1)
    }
}
