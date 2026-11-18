import MicroDiffCore
import MicroDiffTestSupport
import Testing

@Suite("ChangeMarks")
struct ChangeMarksTests {
    private func numbered(_ n: Int) -> String {
        (1...n).map { "line \($0)" }.joined(separator: "\n") + "\n"
    }

    /// Committed 30 lines, then: line 5 changed, two lines added after line 12, line 20 deleted.
    private func modifiedRepo() -> TestRepo {
        let repo = TestRepo()
        repo.write("a.txt", numbered(30))
        repo.commitAll("first")
        var lines = (1...30).map { "line \($0)" }
        lines[4] = "line five"
        lines.remove(at: 19)
        lines.insert(contentsOf: ["new a", "new b"], at: 12)
        repo.write("a.txt", lines.joined(separator: "\n") + "\n")
        return repo
    }

    @Test func theMarksOfTheFileOnDiskAreTheReadViewsMarks() {
        let repo = modifiedRepo()
        let disk = fileBytes(repo.path + "/a.txt")
        let read = readViewMarks(repo, "a.txt")
        #expect(read.contains(.added) && read.contains(.modified))
        #expect(editorMarks(repo, "a.txt", text: disk) == read)
    }

    @Test func aTypedLineIsAddedAndAnEditedLineIsModified() {
        let repo = TestRepo()
        repo.write("a.txt", numbered(10))
        repo.commitAll("first")
        #expect(editorMarks(repo, "a.txt", text: utf8(numbered(10))) == Array(repeating: .none, count: 10))

        var lines = (1...10).map { "line \($0)" }
        lines.insert("typed", at: 3)
        let added = editorMarks(repo, "a.txt", text: utf8(lines.joined(separator: "\n") + "\n"))
        #expect(added?[3] == .added)
        #expect(added?.filter { $0 != .none }.count == 1)

        lines.remove(at: 3)
        lines[6] = "line 7 edited"
        let modified = editorMarks(repo, "a.txt", text: utf8(lines.joined(separator: "\n") + "\n"))
        #expect(modified?[6] == .modified)
        #expect(modified?.filter { $0 != .none }.count == 1)
    }

    @Test func aDeletionAloneMarksNothing() {
        let repo = TestRepo()
        repo.write("a.txt", numbered(10))
        repo.commitAll("first")
        var lines = (1...10).map { "line \($0)" }
        lines.remove(at: 4)
        #expect(editorMarks(repo, "a.txt", text: utf8(lines.joined(separator: "\n") + "\n")) == Array(repeating: .none, count: 9))
    }

    @Test func windowsLineEndingsAndABOMMatchTheReadView() {
        let repo = TestRepo()
        repo.write("w.txt", "one\r\ntwo\r\nthree\r\n")
        repo.commitAll("first")
        repo.write("w.txt", bytes([0xEF, 0xBB, 0xBF] + utf8("one\r\nTWO\r\nthree\r\nfour\r\n")))
        let text = EditFile.bytes("one\nTWO\nthree\nfour\n", format: FileFormat(hasBOM: true, usesCRLF: true))
        #expect(editorMarks(repo, "w.txt", text: text) == readViewMarks(repo, "w.txt"))
    }

    @Test func filesWithoutAHeadVersionHaveNoBase() {
        let repo = TestRepo()
        repo.write("a.txt", "a\n")
        repo.commitAll("first")
        repo.write("new.txt", "fresh\n")
        let git = GitRunner()
        #expect(ChangeMarks.base(MarkSource(repoRoot: repo.path, headPath: "new.txt"), git: git) == nil)
        #expect(ChangeMarks.base(MarkSource(repoRoot: repo.path, headPath: "a.txt"), git: git) != nil)
        let empty = TestRepo()
        empty.write("b.txt", "b\n")
        #expect(ChangeMarks.base(MarkSource(repoRoot: empty.path, headPath: "b.txt"), git: git) == nil, "no commits yet")
    }

    @Test func editorBytesPutTheFormatBack() {
        #expect(EditFile.bytes("a\nb\n", format: FileFormat()) == utf8("a\nb\n"))
        #expect(EditFile.bytes("a\nb\n", format: FileFormat(hasBOM: true, usesCRLF: true)) == [0xEF, 0xBB, 0xBF] + utf8("a\r\nb\r\n"))
    }
}
