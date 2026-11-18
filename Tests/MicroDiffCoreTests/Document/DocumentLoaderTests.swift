import MicroDiffCore
import Testing

private struct NotText: Error {}

/// Integration tests: every test builds its own throwaway git repository.
@Suite("DocumentLoader")
struct DocumentLoaderTests {
    private let loader = DocumentLoader()

    // MARK: helpers

    private func snapshot(_ repo: TestRepo) -> RepoSnapshot {
        RepoScanner().scan(root: repo.path).repos[0]
    }

    /// A request exactly as the app builds it: the change comes from a fresh scan.
    private func request(
        _ repo: TestRepo, _ path: String, mode: ViewMode = .diff, folds: Set<Int> = []
    ) -> DocumentRequest {
        let root = snapshot(repo)
        return DocumentRequest(
            path: repo.path + "/" + path, repo: root, change: root.changes.first { $0.path == path },
            mode: mode, expandedFolds: folds)
    }

    private func document(_ request: DocumentRequest) throws -> TextDocument {
        guard case .text(let document) = loader.load(request) else { throw NotText() }
        return document
    }

    private func message(_ request: DocumentRequest) -> String? {
        if case .message(let text) = loader.load(request) { return text }
        return nil
    }

    private func rows(_ document: TextDocument) -> [DiffRow] {
        (0..<document.rows.rowCount).map { document.rows.row(at: $0) }
    }

    private func lines(_ count: Int, prefix: String = "line") -> [String] {
        (1...count).map { "\(prefix)\($0)" }
    }

    private func text(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    private func lineTexts(_ buffer: TextBuffer) -> [String] {
        (0..<buffer.lineCount).map { buffer.line($0) }
    }

    /// A repo with `path` committed with `lines`.
    private func repo(committing path: String = "main.swift", lines committed: [String]) -> TestRepo {
        let repo = TestRepo()
        repo.write(path, text(committed))
        repo.commitAll("initial")
        return repo
    }

    /// 30 numbered lines, then: line 10 replaced, line 20 deleted, "new" added after old line 28.
    private func editedThirtyLines(_ repo: TestRepo, path: String = "main.swift") -> String {
        var edited = lines(30)
        edited.insert("new", at: 28)
        edited.remove(at: 19)
        edited[9] = "changed10"
        let content = text(edited)
        repo.write(path, content)
        return content
    }

    // MARK: modified file, diff mode

    @Test func modifiedFileInDiffModeShowsFoldsContextAddedAndDeletedRows() throws {
        let repo = repo(lines: lines(30))
        let content = editedThirtyLines(repo)
        let document = try document(request(repo, "main.swift"))

        #expect(document.kind == .diff)
        #expect(document.patch.hunks.count == 3)
        #expect(document.newText.lineCount == 30)
        #expect(String(decoding: document.newText.data, as: UTF8.self) == content)
        #expect(lineTexts(document.oldText) == ["line10", "line20"])

        // Lines 1-6 fold away, 7-30 stay visible (the gaps between hunks are shorter than a fold),
        // two deleted rows come on top: 1 + 24 + 2 rows.
        let all = rows(document)
        #expect(document.rows.foldCount == 1)
        #expect(all.count == 27)
        #expect(all.first == DiffRow(kind: .fold, line: 0, count: 6, number: nil, hunk: -1))
        #expect(all.filter { $0.kind == .added }.count == 2)
        #expect(all.filter { $0.kind == .deleted }.count == 2)
    }

    @Test func rowsPointAtTheRightTextOfTheEdit() throws {
        let repo = repo(lines: lines(30))
        _ = editedThirtyLines(repo)
        let document = try document(request(repo, "main.swift"))

        for row in rows(document) {
            switch row.kind {
            case .added:
                #expect(["changed10", "new"].contains(document.newText.line(row.line)))
                #expect(row.number == row.line + 1)
            case .context:
                #expect(!["changed10", "new"].contains(document.newText.line(row.line)))
                #expect(row.number == row.line + 1)
            case .deleted:
                #expect(["line10", "line20"].contains(document.oldText.line(row.line)))
                #expect(row.number == nil)
                #expect(document.patch.hunks.indices.contains(row.hunk))
            case .fold:
                #expect(row.number == nil)
                #expect(row.count == 6)
            }
        }
        // A deleted row sits right before the added row that replaced it.
        let all = rows(document)
        let replaced = try #require(all.firstIndex { $0.kind == .deleted && document.oldText.line($0.line) == "line10" })
        #expect(all[replaced + 1].kind == .added)
        #expect(document.newText.line(all[replaced + 1].line) == "changed10")
    }

    @Test func swiftFileGetsALexerAndAPlainTextFileDoesNot() throws {
        let swift = repo(lines: lines(5))
        swift.write("main.swift", text(lines(5, prefix: "let x")))
        #expect(try document(request(swift, "main.swift")).lexer?.definition.name == "Swift")

        let rust = repo(committing: "src/lib.rs", lines: lines(5))
        rust.write("src/lib.rs", text(lines(5, prefix: "fn f")))
        #expect(try document(request(rust, "src/lib.rs")).lexer?.definition.name == "Rust")

        let notes = repo(committing: "notes.txt", lines: lines(5))
        notes.write("notes.txt", text(lines(5, prefix: "other")))
        #expect(try document(request(notes, "notes.txt")).lexer == nil)
    }

    @Test func fileInASubfolderIsDiffedAgainstItsOwnHead() throws {
        let repo = repo(committing: "a/b/c.rs", lines: lines(4))
        repo.write("a/b/c.rs", text(["line1", "changed", "line3", "line4"]))
        let document = try document(request(repo, "a/b/c.rs"))
        #expect(document.kind == .diff)
        #expect(lineTexts(document.oldText) == ["line2"])
    }

    @Test func stagedAndUnstagedEditsAreShownTogether() throws {
        let repo = repo(lines: lines(20))
        var edited = lines(20)
        edited[1] = "staged2"
        repo.write("main.swift", text(edited))
        repo.git("add", "main.swift")
        edited[15] = "unstaged16"
        repo.write("main.swift", text(edited))
        let document = try document(request(repo, "main.swift"))
        #expect(document.kind == .diff)
        #expect(lineTexts(document.oldText) == ["line2", "line16"])
    }

    @Test func fileWithoutTrailingNewline() throws {
        let repo = TestRepo()
        repo.write("a.txt", "a\nb")
        repo.commitAll()
        repo.write("a.txt", "a\nc")
        let document = try document(request(repo, "a.txt"))
        #expect(document.kind == .diff)
        #expect(document.newText.lineCount == 2)
        #expect(lineTexts(document.oldText) == ["b"])
    }

    @Test func fileEmptiedCompletelyShowsOnlyDeletedRows() throws {
        let repo = repo(lines: lines(3))
        repo.write("main.swift", "")
        let document = try document(request(repo, "main.swift"))
        #expect(document.kind == .diff)
        #expect(document.newText.lineCount == 0)
        #expect(rows(document).map(\.kind) == [.deleted, .deleted, .deleted])
        #expect(lineTexts(document.oldText) == ["line1", "line2", "line3"])
    }

    // MARK: modified file, file mode

    @Test func modifiedFileInFileModeHasOneRowPerLineWithMarks() throws {
        let repo = repo(lines: lines(30))
        let content = editedThirtyLines(repo)
        let document = try document(request(repo, "main.swift", mode: .file))

        #expect(document.kind == .file)
        #expect(String(decoding: document.newText.data, as: UTF8.self) == content)
        let all = rows(document)
        #expect(all.count == 30)
        #expect(all.allSatisfy { $0.kind == .context })
        #expect(all.map(\.number) == (1...30).map { Optional($0) })
        #expect(document.rows.foldCount == 0)
        // Line 10 replaced something, line 28 is new; the pure deletion marks no line.
        for (index, row) in all.enumerated() {
            switch index {
            case 9: #expect(row.mark == .modified)
            case 27: #expect(row.mark == .added)
            default: #expect(row.mark == .none, "line \(index + 1)")
            }
        }
        #expect(lineTexts(document.oldText) == ["line10", "line20"])
    }

    // MARK: folds

    @Test func expandedFoldInTheRequestRemovesThatFold() throws {
        let repo = repo(lines: lines(30))
        _ = editedThirtyLines(repo)
        let collapsed = try document(request(repo, "main.swift"))
        let expanded = try document(request(repo, "main.swift", folds: [0]))
        #expect(collapsed.rows.foldCount == 1)
        #expect(expanded.rows.foldCount == 0)
        // 30 new lines plus 2 deleted rows.
        #expect(expanded.rows.rowCount == 32)
        #expect(rows(expanded).filter { $0.kind == .context }.count == 28)
    }

    @Test func foldIndexThatIsNotAFoldChangesNothing() throws {
        let repo = repo(lines: lines(30))
        _ = editedThirtyLines(repo)
        let normal = try document(request(repo, "main.swift"))
        let other = try document(request(repo, "main.swift", folds: [3, 17, 99]))
        #expect(rows(normal) == rows(other))
    }

    @Test func withExpandedFoldsGivesTheSameRowsAsLoadingWithThoseFolds() throws {
        let repo = repo(lines: lines(60))
        var edited = lines(60)
        edited[29] = "changed30"
        repo.write("main.swift", text(edited))
        let collapsed = try document(request(repo, "main.swift"))
        let loaded = try document(request(repo, "main.swift", folds: [0]))
        let derived = collapsed.withExpandedFolds([0])
        #expect(collapsed.rows.foldCount == 2)
        #expect(rows(derived) == rows(loaded))
        #expect(derived.rows.foldCount == loaded.rows.foldCount)
        #expect(derived.kind == .diff)
        #expect(derived.rows.contentHeight == loaded.rows.contentHeight)
    }

    @Test func withExpandedFoldsKeepsEverythingElseAndCanFoldAgain() throws {
        let repo = repo(lines: lines(60))
        var edited = lines(60)
        edited[29] = "changed30"
        repo.write("main.swift", text(edited))
        let collapsed = try document(request(repo, "main.swift"))
        let expanded = collapsed.withExpandedFolds([0])
        #expect(expanded.newText.byteCount == collapsed.newText.byteCount)
        #expect(expanded.oldText.byteCount == collapsed.oldText.byteCount)
        #expect(expanded.patch.hunks == collapsed.patch.hunks)
        #expect(expanded.lexer === collapsed.lexer)
        #expect(rows(expanded.withExpandedFolds([])) == rows(collapsed))
    }

    @Test func withExpandedFoldsIsANoOpForFileDeletedAndPlainDocuments() throws {
        let repo = repo(lines: lines(30))
        _ = editedThirtyLines(repo)
        let file = try document(request(repo, "main.swift", mode: .file))
        #expect(file.kind == .file)
        #expect(rows(file.withExpandedFolds([0, 5, 10])) == rows(file))

        repo.write("fresh.txt", text(lines(8)))
        let plain = try document(request(repo, "fresh.txt"))
        #expect(plain.kind == .plain)
        #expect(rows(plain.withExpandedFolds([0])) == rows(plain))

        repo.remove("main.swift")
        let deleted = try document(request(repo, "main.swift"))
        #expect(deleted.kind == .deleted)
        #expect(rows(deleted.withExpandedFolds([0])) == rows(deleted))
    }

    // MARK: files without a diff

    @Test(arguments: [ViewMode.diff, ViewMode.file])
    func untrackedFileIsShownPlain(_ mode: ViewMode) throws {
        let repo = repo(lines: lines(3))
        repo.write("fresh.rs", text(lines(7)))
        let request = request(repo, "fresh.rs", mode: mode)
        #expect(request.change?.isUntracked == true)
        let document = try document(request)
        #expect(document.kind == .plain)
        #expect(document.newText.lineCount == 7)
        #expect(document.oldText.lineCount == 0)
        #expect(document.patch.hunks.isEmpty)
        #expect(rows(document).count == 7)
        #expect(rows(document).allSatisfy { $0.kind == .context && $0.mark == .none })
        #expect(rows(document).map(\.number) == (1...7).map { Optional($0) })
        #expect(document.lexer?.definition.name == "Rust")
    }

    @Test(arguments: [ViewMode.diff, ViewMode.file])
    func stagedAddedFileIsShownPlain(_ mode: ViewMode) throws {
        let repo = repo(lines: lines(3))
        repo.write("added.swift", text(lines(4)))
        repo.git("add", "added.swift")
        let request = request(repo, "added.swift", mode: mode)
        #expect(request.change?.kind == .added)
        let document = try document(request)
        #expect(document.kind == .plain)
        #expect(rows(document).count == 4)
        #expect(document.rows.foldCount == 0)
    }

    @Test func newFileInARepositoryWithoutCommits() throws {
        let repo = TestRepo()
        repo.write("a.swift", text(lines(3)))
        let request = request(repo, "a.swift")
        #expect(!snapshot(repo).hasHead)
        let document = try document(request)
        #expect(document.kind == .plain)
        #expect(document.newText.lineCount == 3)
    }

    @Test func fileWithoutAChangeOrARepoIsShownPlain() throws {
        let repo = repo(lines: lines(6))
        let path = repo.path + "/main.swift"
        let withoutRepo = try document(DocumentRequest(path: path))
        #expect(withoutRepo.kind == .plain)
        #expect(withoutRepo.newText.lineCount == 6)
        #expect(withoutRepo.rows.rowCount == 6)

        // Clean file inside a repo: a change of nil.
        let clean = request(repo, "main.swift")
        #expect(clean.change == nil)
        #expect(clean.repo != nil)
        #expect(try document(clean).kind == .plain)
    }

    @Test func changeWithoutARepoIsIgnored() throws {
        let repo = repo(lines: lines(6))
        repo.write("main.swift", text(lines(6, prefix: "other")))
        let change = try #require(snapshot(repo).changes.first)
        let request = DocumentRequest(path: repo.path + "/main.swift", repo: nil, change: change)
        #expect(try document(request).kind == .plain)
    }

    @Test func modifiedFileWhoseOnlyChangeIsTheModeIsShownPlain() throws {
        let repo = repo(lines: lines(6))
        makeExecutable(repo.path + "/main.swift")
        for mode in [ViewMode.diff, ViewMode.file] {
            let request = request(repo, "main.swift", mode: mode)
            #expect(request.change?.kind == .modified)
            let document = try document(request)
            #expect(document.kind == .plain)
            #expect(document.patch.hunks.isEmpty)
            #expect(rows(document).count == 6)
            #expect(rows(document).allSatisfy { $0.kind == .context })
        }
    }

    // MARK: deleted files

    @Test(arguments: [ViewMode.diff, ViewMode.file])
    func deletedFileShowsItsOldContentsAsDeletedRows(_ mode: ViewMode) throws {
        let repo = repo(lines: lines(5))
        repo.remove("main.swift")
        let request = request(repo, "main.swift", mode: mode)
        #expect(request.change?.kind == .deleted)
        let document = try document(request)
        #expect(document.kind == .deleted)
        #expect(String(decoding: document.oldText.data, as: UTF8.self) == text(lines(5)))
        #expect(document.newText.byteCount == 0)
        #expect(document.newText.lineCount == 0)
        let all = rows(document)
        #expect(all.count == 5)
        #expect(all.allSatisfy { $0.kind == .deleted && $0.hunk == -1 })
        #expect(all.map(\.number) == (1...5).map { Optional($0) })
        #expect(all.map(\.line) == Array(0..<5))
        #expect(document.lexer?.definition.name == "Swift")
    }

    @Test func stagedDeletionAndDeletionInASubfolder() throws {
        let repo = repo(committing: "dir/gone.rs", lines: lines(3))
        repo.git("rm", "--quiet", "dir/gone.rs")
        let document = try document(request(repo, "dir/gone.rs"))
        #expect(document.kind == .deleted)
        #expect(lineTexts(document.oldText) == lines(3))
        #expect(document.lexer?.definition.name == "Rust")
    }

    @Test func deletedEmptyFileHasNoRows() throws {
        let repo = TestRepo()
        repo.write("empty.txt", "")
        repo.write("keep.txt", "x\n")
        repo.commitAll()
        repo.remove("empty.txt")
        let document = try document(request(repo, "empty.txt"))
        #expect(document.kind == .deleted)
        #expect(document.rows.rowCount == 0)
    }

    @Test func deletedBinaryFileIsAMessage() {
        let repo = TestRepo()
        repo.write("blob.bin", Data([0x01, 0x00, 0x02, 0x00]))
        repo.commitAll()
        repo.remove("blob.bin")
        #expect(message(request(repo, "blob.bin")) == DocumentLoader.binaryMessage)
    }

    @Test func deletedFileThatIsNotInHeadIsAMessage() {
        let repo = repo(lines: lines(2))
        let change = FileChange(path: "never-existed.txt", kind: .deleted)
        let request = DocumentRequest(path: repo.path + "/never-existed.txt", repo: snapshot(repo), change: change)
        #expect(message(request) == DocumentLoader.missingMessage)
    }

    // MARK: rename

    @Test func renamedAndEditedFileIsDiffedAgainstTheOldPath() throws {
        let repo = TestRepo()
        repo.write("old.swift", text(lines(20)))
        repo.commitAll()
        repo.git("mv", "old.swift", "new.swift")
        var edited = lines(20)
        edited[9] = "changed10"
        repo.write("new.swift", text(edited))
        let request = request(repo, "new.swift")
        #expect(request.change?.kind == .renamed)
        #expect(request.change?.oldPath == "old.swift")
        let document = try document(request)
        #expect(document.kind == .diff)
        #expect(lineTexts(document.oldText) == ["line10"])
        #expect(rows(document).filter { $0.kind == .added }.map { document.newText.line($0.line) } == ["changed10"])
    }

    @Test func renamedWithoutEditsIsShownPlain() throws {
        let repo = TestRepo()
        repo.write("old.swift", text(lines(10)))
        repo.commitAll()
        repo.git("mv", "old.swift", "new.swift")
        let request = request(repo, "new.swift")
        #expect(request.change?.kind == .renamed)
        let document = try document(request)
        #expect(document.kind == .plain)
        #expect(rows(document).count == 10)
    }

    // MARK: binary files

    @Test func modifiedBinaryFileIsAMessage() {
        let repo = TestRepo()
        repo.write("blob.bin", Data([0x00, 0x01, 0x02, 0x03]))
        repo.commitAll()
        repo.write("blob.bin", Data([0x00, 0x09, 0x08, 0x07, 0x00]))
        #expect(message(request(repo, "blob.bin")) == DocumentLoader.binaryMessage)
        #expect(message(request(repo, "blob.bin", mode: .file)) == DocumentLoader.binaryMessage)
    }

    @Test func untrackedBinaryFileIsAMessage() {
        let repo = repo(lines: lines(2))
        repo.write("blob.bin", Data([0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01]))
        #expect(message(request(repo, "blob.bin")) == DocumentLoader.binaryMessage)
    }

    @Test func binaryFileWithoutAnyChangeInfoIsAMessage() {
        let repo = TestRepo()
        let path = repo.write("blob.bin", Data([0x00]))
        #expect(message(DocumentRequest(path: path)) == DocumentLoader.binaryMessage)
    }

    @Test func nulBeyondTheFirst8000BytesDoesNotMakeAFileBinary() throws {
        let repo = TestRepo()
        var bytes = Data(Array("a\n".utf8) + Array(repeating: UInt8(ascii: "x"), count: 8100))
        bytes.append(0)
        let path = repo.write("late.txt", bytes)
        let document = try document(DocumentRequest(path: path))
        #expect(document.kind == .plain)
    }

    @Test func gitBinaryAttributeMakesATextFileAMessage() {
        let repo = TestRepo()
        repo.write(".gitattributes", "data.txt -diff\n")
        repo.write("data.txt", text(lines(5)))
        repo.commitAll()
        repo.write("data.txt", text(lines(5, prefix: "other")))
        #expect(message(request(repo, "data.txt")) == DocumentLoader.binaryMessage)
    }

    // MARK: missing and unreadable

    @Test func missingFileIsAMessage() {
        let repo = TestRepo()
        #expect(message(DocumentRequest(path: repo.path + "/nope.txt")) == DocumentLoader.missingMessage)
    }

    @Test func fileRemovedAfterTheScanIsAMessage() {
        let repo = repo(lines: lines(5))
        repo.write("main.swift", text(lines(5, prefix: "other")))
        let request = request(repo, "main.swift")
        repo.remove("main.swift")
        #expect(message(request) == DocumentLoader.missingMessage)
    }

    @Test func directoryIsAMessageNotACrash() {
        let repo = TestRepo()
        repo.write("dir/a.txt", "x\n")
        let result = message(DocumentRequest(path: repo.path + "/dir"))
        #expect(result == DocumentLoader.missingMessage)
        #expect(message(DocumentRequest(path: repo.path)) != nil)
    }

    @Test func emptyAndNonsensePathsAreMessages() {
        #expect(message(DocumentRequest(path: "")) != nil)
        #expect(message(DocumentRequest(path: "/definitely/not/here/\u{1F4A5}.txt")) == DocumentLoader.missingMessage)
    }

    // MARK: size limits

    @Test func fileLargerThanTheMaximumIsTooLarge() {
        let repo = TestRepo()
        let path = repo.path + "/huge.txt"
        writeSparseFile(path, byteCount: TextBuffer.defaultMaxBytes + 1)
        #expect(message(DocumentRequest(path: path)) == DocumentLoader.tooLargeMessage)
    }

    @Test func sizeMessageWinsOverTheBinaryCheck() {
        // A sparse file is all NUL bytes, so it would be binary; the size check comes first.
        let repo = TestRepo()
        let path = repo.path + "/huge.dat"
        writeSparseFile(path, byteCount: TextBuffer.defaultMaxBytes + 4096)
        #expect(message(DocumentRequest(path: path)) == DocumentLoader.tooLargeMessage)
    }

    @Test func modifiedFileThatGrewPastTheMaximumIsTooLarge() {
        let repo = repo(lines: lines(5))
        writeSparseFile(repo.path + "/main.swift", byteCount: TextBuffer.defaultMaxBytes + 1)
        #expect(message(request(repo, "main.swift")) == DocumentLoader.tooLargeMessage)
    }

    @Test func fileExactlyAtTheMaximumLoads() throws {
        let repo = TestRepo()
        let path = repo.write("max.txt", filledData(UInt8(ascii: "a"), count: TextBuffer.defaultMaxBytes))
        let document = try document(DocumentRequest(path: path))
        #expect(document.newText.byteCount == TextBuffer.defaultMaxBytes)
        #expect(document.lexer == nil)
    }

    @Test func deletedFileLargerThanTheMaximumIsTooLarge() {
        let repo = TestRepo()
        repo.write("huge.bin", filledData(UInt8(ascii: "a"), count: TextBuffer.defaultMaxBytes + 1))
        repo.commitAll()
        repo.remove("huge.bin")
        #expect(message(request(repo, "huge.bin")) == DocumentLoader.tooLargeMessage)
    }

    // MARK: highlight limit

    @Test func fileAboveTheHighlightLimitLoadsWithoutALexer() throws {
        let repo = TestRepo()
        let path = repo.write("big.swift", filledData(UInt8(ascii: "a"), count: DocumentLoader.maxHighlightBytes + 1))
        let document = try document(DocumentRequest(path: path))
        #expect(document.lexer == nil)
        #expect(document.newStates.isEmpty)
        #expect(document.newText.byteCount == DocumentLoader.maxHighlightBytes + 1)
        #expect(document.kind == .plain)
    }

    @Test func fileAtTheHighlightLimitStillGetsALexer() throws {
        let repo = TestRepo()
        let path = repo.write("edge.swift", filledData(UInt8(ascii: "a"), count: DocumentLoader.maxHighlightBytes))
        #expect(try document(DocumentRequest(path: path)).lexer != nil)
    }

    @Test func modifiedFileAboveTheHighlightLimitKeepsItsDiff() throws {
        let repo = TestRepo()
        let big = String(repeating: "let x = 1\n", count: DocumentLoader.maxHighlightBytes / 10 + 10)
        repo.write("big.swift", big)
        repo.commitAll()
        repo.write("big.swift", "changed\n" + big)
        let document = try document(request(repo, "big.swift"))
        #expect(document.kind == .diff)
        #expect(document.lexer == nil)
        #expect(document.oldStates.isEmpty)
        #expect(rows(document).contains { $0.kind == .added })
    }

    @Test func deletedFileAboveTheHighlightLimitHasNoLexer() throws {
        let repo = TestRepo()
        repo.write("big.swift", filledData(UInt8(ascii: "a"), count: DocumentLoader.maxHighlightBytes + 1))
        repo.commitAll()
        repo.remove("big.swift")
        let document = try document(request(repo, "big.swift"))
        #expect(document.kind == .deleted)
        #expect(document.lexer == nil)
    }

    // MARK: line endings

    @Test func crlfFileLoadsWithTheRightLineCount() throws {
        let repo = TestRepo()
        repo.write("win.txt", "a\r\nb\r\nc\r\nd\r\n")
        repo.commitAll()
        repo.write("win.txt", "a\r\nB\r\nc\r\nd\r\n")
        let document = try document(request(repo, "win.txt"))
        #expect(document.kind == .diff)
        #expect(document.newText.lineCount == 4)
        #expect(document.newText.line(1) == "B")
        #expect(document.newText.maxLineByteLength == 1)
        #expect(lineTexts(document.oldText) == ["b"])
        #expect(rows(document).filter { $0.kind == .added }.count == 1)
    }

    @Test func crlfUntrackedFile() throws {
        let repo = repo(lines: lines(2))
        repo.write("win.txt", "a\r\nb\r\n")
        let document = try document(request(repo, "win.txt"))
        #expect(document.kind == .plain)
        #expect(document.newText.lineCount == 2)
        #expect(document.rows.rowCount == 2)
    }

    // MARK: lengths and lexer states

    @Test func maxLineByteLengthCoversBothTexts() throws {
        // The longest line is a deleted one.
        let longOld = String(repeating: "o", count: 120)
        let repo = TestRepo()
        repo.write("a.txt", "short\n\(longOld)\nshort\n")
        repo.commitAll()
        repo.write("a.txt", "short\nnew\nshort\n")
        let deletedLong = try document(request(repo, "a.txt"))
        #expect(deletedLong.newText.maxLineByteLength == 5)
        #expect(deletedLong.oldText.maxLineByteLength == 120)
        #expect(deletedLong.maxLineByteLength == 120)

        // The longest line is a new one.
        let longNew = String(repeating: "n", count: 200)
        repo.write("a.txt", "short\n\(longNew)\nshort\n")
        let addedLong = try document(request(repo, "a.txt"))
        #expect(addedLong.newText.maxLineByteLength == 200)
        #expect(addedLong.maxLineByteLength == 200)
    }

    @Test func maxLineByteLengthOfPlainAndDeletedDocuments() throws {
        let repo = TestRepo()
        let plain = repo.write("p.txt", "abc\nabcdefgh\n")
        #expect(try document(DocumentRequest(path: plain)).maxLineByteLength == 8)
        repo.write("gone.txt", "12345678901\nx\n")
        repo.commitAll()
        repo.remove("gone.txt")
        #expect(try document(request(repo, "gone.txt")).maxLineByteLength == 11)
    }

    @Test func newTextLexerStatesCarryAnOpenBlockComment() throws {
        let repo = TestRepo()
        let original = ["let a = 1", "/* open", "inside", "*/", "let b = 2"]
        repo.write("main.swift", text(original))
        repo.commitAll()
        var edited = original
        edited[0] = "let a = 99"
        repo.write("main.swift", text(edited))
        let document = try document(request(repo, "main.swift"))
        #expect(document.newStates.count == 5)
        #expect(document.newStates[0] == .normal)
        #expect(document.newStates[2] != .normal)
        #expect(document.newStates[4] == .normal)
    }

    @Test func deletedLinesOfSeparateHunksStartFreshLexerStates() throws {
        // Hunk 1 deletes a line that opens a comment, hunk 2 deletes an unrelated line. The second deleted
        // line must be lexed as code: the two are not neighbours in the old file.
        let repo = TestRepo()
        let original = lines(20).enumerated().map { $0.offset == 2 ? "/* start" : ($0.offset == 15 ? "let x = 1" : $0.element) }
        repo.write("main.swift", text(original))
        repo.commitAll()
        var edited = original
        edited[2] = "// gone"
        edited[15] = "let y = 2"
        repo.write("main.swift", text(edited))
        let document = try document(request(repo, "main.swift"))
        #expect(document.patch.hunks.count == 2)
        #expect(lineTexts(document.oldText) == ["/* start", "let x = 1"])
        #expect(document.oldStates.isEmpty)
    }

    @Test func deletedFileLexerStatesFollowTheWholeOldFile() throws {
        let repo = TestRepo()
        repo.write("main.swift", text(["/* a", "b", "*/ let x"]))
        repo.commitAll()
        repo.remove("main.swift")
        let document = try document(request(repo, "main.swift"))
        #expect(document.oldStates.count == 3)
        #expect(document.oldStates[1] != .normal)
        #expect(document.oldStates[2] != .normal)
        #expect(document.newStates.isEmpty)
    }

    @Test func plainFileLexerStatesFollowTheFile() throws {
        let repo = TestRepo()
        let path = repo.write("a.c", text(["/* a", "b", "*/", "int x;"]))
        let document = try document(DocumentRequest(path: path))
        #expect(document.newStates.count == 4)
        #expect(document.newStates[3] == .normal)
        #expect(document.newStates[1] != .normal)
    }
}
