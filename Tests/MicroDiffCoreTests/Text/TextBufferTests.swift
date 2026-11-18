import MicroDiffCore
import Testing

@Suite struct TextBufferTests {
    private func lines(_ buffer: TextBuffer) -> [String] {
        (0..<buffer.lineCount).map { buffer.line($0) }
    }

    private func buffer(_ text: String) -> TextBuffer { TextBuffer(Data(text.utf8)) }

    @Test(arguments: [
        ("", []),
        ("a", ["a"]),
        ("a\n", ["a"]),
        ("a\nb", ["a", "b"]),
        ("a\nb\n", ["a", "b"]),
        ("a\n\n", ["a", ""]),
        ("\n", [""]),
        ("\n\n\n", ["", "", ""]),
        ("a\n\nb", ["a", "", "b"]),
        ("a\r\nb\r\n", ["a", "b"]),
        ("a\r\nb", ["a", "b"]),
        ("a\r\n\r\n", ["a", ""]),
        ("\r\n", [""]),
        ("a\rb\nc", ["a\rb", "c"]),
        ("a\r", ["a\r"]),
        ("héllo\nwörld ✓", ["héllo", "wörld ✓"]),
    ] as [(String, [String])])
    func splitsLines(text: String, expected: [String]) {
        let b = buffer(text)
        #expect(b.lineCount == expected.count)
        #expect(lines(b) == expected)
        #expect(b.byteCount == text.utf8.count)
    }

    @Test func emptyBuffer() {
        let b = TextBuffer.empty
        #expect(b.lineCount == 0)
        #expect(b.byteCount == 0)
        #expect(b.maxLineByteLength == 0)
        #expect(!b.isBinary)
    }

    @Test func lineRangesExcludeTerminators() {
        let b = buffer("ab\r\ncd\n\nef")
        #expect(b.lineRange(0) == 0..<2)
        #expect(b.lineRange(1) == 4..<6)
        #expect(b.lineRange(2) == 7..<7)
        #expect(b.lineRange(3) == 8..<10)
    }

    @Test func withLineBytesGivesRawBytes() {
        let b = TextBuffer(Data([0x61, 0xFF, 0x0A, 0x62]))
        #expect(b.withLineBytes(0) { Array($0) } == [0x61, 0xFF])
        #expect(b.withLineBytes(1) { Array($0) } == [0x62])
    }

    @Test func invalidUTF8BecomesReplacementCharacter() {
        let b = TextBuffer(Data([0x61, 0xFF, 0xFE, 0x62, 0x0A, 0x63]))
        #expect(b.line(0) == "a\u{FFFD}\u{FFFD}b")
        #expect(b.line(1) == "c")
    }

    @Test func detectsNulInFirst8000Bytes() {
        #expect(TextBuffer(Data([0x61, 0x00, 0x62])).isBinary)
        #expect(!buffer("plain text\n").isBinary)
        var late = Data(repeating: 0x61, count: 8000)
        late.append(0)
        #expect(!TextBuffer(late).isBinary)
        var edge = Data(repeating: 0x61, count: 7999)
        edge.append(0)
        #expect(TextBuffer(edge).isBinary)
    }

    @Test func maxLineByteLengthIgnoresTerminatorsAndCountsBytes() {
        #expect(buffer("ab\nabcd\nabc").maxLineByteLength == 4)
        #expect(buffer("abcd\r\nab").maxLineByteLength == 4)
        #expect(buffer("\n\n").maxLineByteLength == 0)
        #expect(buffer("ééé\nx").maxLineByteLength == 6)
        #expect(buffer("abc").maxLineByteLength == 3)
    }

    @Test func handlesLargeBuffer() {
        var text = ""
        text.reserveCapacity(200_000 * 12)
        for i in 0..<200_000 { text += "line \(i)\n" }
        let b = buffer(text)
        #expect(b.lineCount == 200_000)
        #expect(b.line(0) == "line 0")
        #expect(b.line(123_456) == "line 123456")
        #expect(b.line(199_999) == "line 199999")
        #expect(b.maxLineByteLength == "line 199999".utf8.count)
    }

    @Test func loadsFile() throws {
        let dir = TempDir()
        let path = dir.write("a.txt", "one\ntwo\n")
        let b = try TextBuffer(contentsOfFile: path)
        #expect(lines(b) == ["one", "two"])
    }

    @Test func missingFileIsUnreadable() {
        let dir = TempDir()
        #expect(throws: TextBuffer.LoadError.unreadable) {
            try TextBuffer(contentsOfFile: dir.path + "/nope.txt")
        }
    }

    @Test func directoryIsUnreadable() {
        let dir = TempDir()
        #expect(throws: TextBuffer.LoadError.unreadable) {
            try TextBuffer(contentsOfFile: dir.path)
        }
    }

    @Test func tooLargeFileIsRejectedBeforeReading() {
        let dir = TempDir()
        let path = dir.write("big.txt", String(repeating: "x", count: 100))
        #expect(throws: TextBuffer.LoadError.tooLarge(bytes: 100)) {
            try TextBuffer(contentsOfFile: path, maxBytes: 99)
        }
        #expect((try? TextBuffer(contentsOfFile: path, maxBytes: 100)) != nil)
    }
}
