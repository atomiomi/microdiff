import MicroDiffCore
import MicroDiffTestSupport
import Testing

@Suite("EditFile")
struct EditFileTests {
    private let dir = TempDir()

    // MARK: editability

    @Test func plainFileIsEditable() throws {
        let path = dir.write("a.txt", "hello\n")
        _ = try EditFile.load(path: path)
    }

    @Test func emptyFileIsEditable() throws {
        _ = try EditFile.load(path: dir.write("e.txt", ""))
    }

    @Test func missingFileIsBlocked() {
        #expect(throws: EditError.notEditable(.missing)) { try EditFile.load(path: dir.path + "/nope.txt") }
    }

    @Test func directoryIsBlocked() {
        dir.mkdir("sub")
        #expect(throws: EditError.notEditable(.directory)) { try EditFile.load(path: dir.path + "/sub") }
    }

    @Test func binaryIsBlocked() {
        let path = dir.write("b.bin", bytes([0x61, 0x00, 0x62]))
        #expect(throws: EditError.notEditable(.binary)) { try EditFile.load(path: path) }
    }

    @Test func invalidUTF8IsBlocked() {
        let path = dir.write("l.txt", bytes([0x63, 0x61, 0x66, 0xE9, 0x0A]))
        #expect(throws: EditError.notEditable(.notUTF8)) { try EditFile.load(path: path) }
    }

    @Test func largerThanFourMegabytesIsBlocked() {
        let path = dir.write("big.txt", bytes([UInt8](repeating: 0x61, count: EditFile.maxBytes + 1)))
        #expect(throws: EditError.notEditable(.tooLarge)) { try EditFile.load(path: path) }
    }

    @Test func exactlyFourMegabytesIsEditable() throws {
        let path = dir.write("max.txt", bytes([UInt8](repeating: 0x61, count: EditFile.maxBytes)))
        _ = try EditFile.load(path: path)
    }

    @Test func blockedFileHasAReadableMessage() {
        #expect(EditError.notEditable(.binary).message.contains("Binary"))
    }

    // MARK: load

    @Test func loadPlain() throws {
        let loaded = try EditFile.load(path: dir.write("a.txt", "a\nb\n"))
        #expect(loaded.text == "a\nb\n")
        #expect(loaded.format == FileFormat())
        #expect(loaded.stamp == stampOf(dir.path + "/a.txt"))
    }

    @Test func loadStripsBOM() throws {
        let loaded = try EditFile.load(path: dir.write("a.txt", bytes([0xEF, 0xBB, 0xBF, 0x68, 0x69])))
        #expect(loaded.text == "hi")
        #expect(loaded.format.hasBOM)
    }

    @Test func loadCRLFOnlyTurnsIntoLF() throws {
        let loaded = try EditFile.load(path: dir.write("a.txt", "a\r\nb\r\n"))
        #expect(loaded.text == "a\nb\n")
        #expect(loaded.format.usesCRLF)
    }

    @Test func loadMixedEndingsKeepsTextExactly() throws {
        let loaded = try EditFile.load(path: dir.write("a.txt", "a\r\nb\nc\r\n"))
        #expect(loaded.text.utf8.elementsEqual("a\r\nb\nc\r\n".utf8))
        #expect(!loaded.format.usesCRLF)
    }

    @Test func loadEmptyAndNoTrailingNewline() throws {
        #expect(try EditFile.load(path: dir.write("e.txt", "")).text == "")
        #expect(try EditFile.load(path: dir.write("n.txt", "a\nb")).text == "a\nb")
        #expect(try EditFile.load(path: dir.write("c.txt", "a\r\nb")).text == "a\nb")
    }

    // MARK: save round trips

    private static let samples: [(String, [UInt8])] = [
        ("plain", Array("a\nb\n".utf8)),
        ("bom", [0xEF, 0xBB, 0xBF] + Array("a\nb\n".utf8)),
        ("crlf", Array("a\r\nb\r\n".utf8)),
        ("bom crlf", [0xEF, 0xBB, 0xBF] + Array("a\r\nb\r\n".utf8)),
        ("mixed", Array("a\r\nb\nc\r\n".utf8)),
        ("empty", []),
        ("no trailing newline", Array("a\nb".utf8)),
        ("crlf no trailing newline", Array("a\r\nb".utf8)),
        ("lone CR", Array("a\rb\r\nc\r\n".utf8)),
        ("double CR", Array("a\r\r\nb\r\n".utf8)),
        ("non-ascii", Array("caf\u{E9} \u{1F600}\n".utf8)),
        ("decomposed", Array("cafe\u{301}\n".utf8)),
    ]

    @Test(arguments: samples) func saveRoundTripsByteForByte(_ sample: (String, [UInt8])) throws {
        let path = dir.write("f.txt", bytes(sample.1))
        let loaded = try EditFile.load(path: path)
        let stamp = try EditFile.save(loaded.text, to: path, format: loaded.format)
        #expect(fileBytes(path) == sample.1, "\(sample.0)")
        #expect(stamp == stampOf(path))
    }

    @Test func saveWritesEditedTextWithOriginalFormat() throws {
        let path = dir.write("f.txt", bytes([0xEF, 0xBB, 0xBF] + Array("a\r\n".utf8)))
        let loaded = try EditFile.load(path: path)
        _ = try EditFile.save("a\nb\n", to: path, format: loaded.format)
        #expect(fileBytes(path) == [0xEF, 0xBB, 0xBF] + Array("a\r\nb\r\n".utf8))
    }

    // MARK: save behaviour

    @Test func saveKeepsPermissionsAndLeavesNoTempFile() throws {
        let path = dir.write("run.sh", "#!/bin/sh\n")
        setPermissions(path, 0o755)
        _ = try EditFile.save("#!/bin/sh\necho\n", to: path, format: FileFormat())
        #expect(permissions(path) == 0o755)
        #expect(listDirectory(dir.path) == ["run.sh"])
    }

    @Test func saveThroughSymlinkChangesTargetAndKeepsLink() throws {
        let target = dir.write("real/target.txt", "old\n")
        let link = dir.path + "/link.txt"
        try makeSymlink(link, to: target)
        _ = try EditFile.save("new\n", to: link, format: FileFormat())
        #expect(isSymlink(link))
        #expect(fileBytes(target) == Array("new\n".utf8))
    }

    @Test func saveAfterDeletionCreatesFileAgain() throws {
        let path = dir.write("gone.txt", "x\n")
        removeFile(path)
        _ = try EditFile.save("back\n", to: path, format: FileFormat())
        #expect(fileBytes(path) == Array("back\n".utf8))
    }

    @Test func saveIntoMissingFolderFails() {
        dir.mkdir("sub")
        let path = dir.path + "/sub/f.txt"
        removeFolder(dir.path + "/sub")
        #expect(throws: EditError.folderMissing) { try EditFile.save("x", to: path, format: FileFormat()) }
        #expect(EditError.folderMissing.message.contains("folder"))
    }

    @Test func saveChangesTheStamp() throws {
        let path = dir.write("f.txt", "a\n")
        let before = stampOf(path)
        let after = try EditFile.save("a longer text\n", to: path, format: FileFormat())
        #expect(before != after)
    }

    @Test func observeTellsMissingFromPresent() {
        let path = dir.write("f.txt", "a")
        #expect(DiskObservation.observe(path) == .present(stampOf(path)!))
        #expect(DiskObservation.observe(dir.path + "/none") == .missing)
    }
}
