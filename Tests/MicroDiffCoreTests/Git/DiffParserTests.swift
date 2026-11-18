import MicroDiffCore
import Testing

@Suite struct DiffParserTests {
    private func parse(_ lines: String...) -> FilePatch {
        DiffParser.parse(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func deleted(_ patch: FilePatch) -> [String] {
        (0..<patch.deletedText.lineCount).map { patch.deletedText.line($0) }
    }

    private let header = ["diff --git a/f.txt b/f.txt", "index 1111111..2222222 100644", "--- a/f.txt", "+++ b/f.txt"]

    private func hunk(_ os: Int, _ oc: Int, _ ns: Int, _ nc: Int, _ del: Range<Int>) -> Hunk {
        Hunk(oldStart: os, oldCount: oc, newStart: ns, newCount: nc, deletedLines: del)
    }

    @Test func emptyInputIsEmptyPatch() {
        let patch = DiffParser.parse(Data())
        #expect(patch.hunks.isEmpty)
        #expect(!patch.isBinary)
        #expect(patch.deletedText.lineCount == 0)
    }

    @Test func headersOnlyGiveNoHunks() {
        let patch = parse("diff --git a/a b/b", "similarity index 100%", "rename from a", "rename to b")
        #expect(patch.hunks.isEmpty)
        #expect(!patch.isBinary)
    }

    @Test func parsesU0Replacement() {
        let patch = parse(header[0], header[1], header[2], header[3], "@@ -2,2 +2,3 @@", "-old a", "-old b", "+new a", "+new b", "+new c")
        #expect(patch.hunks == [hunk(2, 2, 2, 3, 0..<2)])
        #expect(deleted(patch) == ["old a", "old b"])
    }

    @Test func parsesPureInsertionAndDeletion() {
        let patch = parse(
            "@@ -0,0 +1,2 @@", "+a", "+b",
            "@@ -5 +4,0 @@", "-gone",
            "@@ -9,0 +10 @@", "+x")
        #expect(patch.hunks == [hunk(0, 0, 1, 2, 0..<0), hunk(5, 1, 4, 0, 0..<1), hunk(9, 0, 10, 1, 1..<1)])
        #expect(deleted(patch) == ["gone"])
    }

    @Test func headerWithoutCountsMeansOne() {
        let patch = parse("@@ -5 +5 @@", "-a", "+b")
        #expect(patch.hunks == [hunk(5, 1, 5, 1, 0..<1)])
    }

    @Test func sectionTextAfterSecondAtSignsIsIgnored() {
        let patch = parse("@@ -3 +3 @@ func foo() { @@ -1 +1 @@", "-a", "+b")
        #expect(patch.hunks == [hunk(3, 1, 3, 1, 0..<1)])
    }

    @Test func ignoresNoNewlineMarkers() {
        let patch = parse("@@ -1 +1 @@", "-a", "\\ No newline at end of file", "+b", "\\ No newline at end of file")
        #expect(patch.hunks == [hunk(1, 1, 1, 1, 0..<1)])
        #expect(deleted(patch) == ["a"])
    }

    @Test(arguments: [
        "Binary files a/x.bin and b/x.bin differ",
        "Binary files /dev/null and b/x.bin differ",
        "GIT binary patch",
    ])
    func detectsBinary(marker: String) {
        let patch = parse("diff --git a/x.bin b/x.bin", "index 1..2 100644", marker)
        #expect(patch.isBinary)
        #expect(patch.hunks.isEmpty)
    }

    @Test func textLookingLikeBinaryMarkerInsideHunkIsContent() {
        let patch = parse("@@ -1 +1 @@", "-Binary files a and b differ", "+x")
        #expect(!patch.isBinary)
        #expect(deleted(patch) == ["Binary files a and b differ"])
    }

    @Test func keepsDeletedLinesThatLookLikeDiffSyntax() {
        let patch = parse("@@ -1,6 +0,0 @@", "--- not a header", "-- dash", "-+plus", "-@@ -1 +1 @@", "-", "-+++ b/x")
        #expect(patch.hunks == [hunk(1, 6, 0, 0, 0..<6)])
        #expect(deleted(patch) == ["-- not a header", "- dash", "+plus", "@@ -1 +1 @@", "", "+++ b/x"])
    }

    @Test func lastDeletedLineBeingEmptyIsKept() {
        let patch = parse("@@ -1,2 +0,0 @@", "-a", "-")
        #expect(deleted(patch) == ["a", ""])
        #expect(patch.hunks.first?.deletedLines == 0..<2)
    }

    @Test func crlfContentIsStrippedInDeletedText() {
        let data = Data("@@ -1,2 +1 @@\n-one\r\n-two\r\n+three\r\n".utf8)
        let patch = DiffParser.parse(data)
        #expect(patch.hunks == [hunk(1, 2, 1, 1, 0..<2)])
        #expect(deleted(patch) == ["one", "two"])
    }

    @Test func deletedLinesIndexAcrossHunks() {
        let patch = parse("@@ -1 +1 @@", "-a", "+A", "@@ -4,2 +4 @@", "-d", "-e", "+D", "@@ -9,0 +9 @@", "+ins", "@@ -12 +11,0 @@", "-l")
        #expect(patch.hunks.map(\.deletedLines) == [0..<1, 1..<3, 3..<3, 3..<4])
        #expect(deleted(patch) == ["a", "d", "e", "l"])
    }

    @Test func malformedHeaderSkipsItsHunkOnly() {
        let patch = parse("@@ -x +1 @@", "-lost", "+lost", "@@ -2 +2 @@", "-a", "+b")
        #expect(patch.hunks == [hunk(2, 1, 2, 1, 0..<1)])
        #expect(deleted(patch) == ["a"])
    }

    @Test func missingTrailingNewlineStillParses() {
        let patch = DiffParser.parse(Data("@@ -1 +1 @@\n-a\n+b".utf8))
        #expect(patch.hunks == [hunk(1, 1, 1, 1, 0..<1)])
    }

    @Test func garbageNeverCrashes() {
        var noise = Data()
        for i in 0..<4000 { noise.append(UInt8(truncatingIfNeeded: i &* 131 &+ i >> 2)) }
        _ = DiffParser.parse(noise)
        _ = DiffParser.parse(Data("@@ -99999999999 +1 @@\n-a\n".utf8))
        _ = DiffParser.parse(Data("@@".utf8))
        _ = DiffParser.parse(Data("-".utf8))
    }

    // MARK: context normalization

    /// The same changes as a -U0 patch and as -U3 patches must give identical hunks.
    @Test func contextPatchNormalizesToU0() {
        // old: 1..10, changes: line 2 replaced, lines 6-7 deleted, an insertion after old line 9.
        let u0 = parse(
            "@@ -2 +2 @@", "-L2", "+N2",
            "@@ -6,2 +5,0 @@", "-L6", "-L7",
            "@@ -9,0 +8 @@", "+INS")
        let u3 = parse(
            "@@ -1,10 +1,9 @@",
            " L1", "-L2", "+N2", " L3", " L4", " L5", "-L6", "-L7", " L8", " L9", "+INS", " L10")
        #expect(u3.hunks == u0.hunks)
        #expect(deleted(u3) == deleted(u0))
    }

    @Test func contextPatchSplitsOneHunkIntoRuns() {
        let patch = parse("@@ -10,7 +10,7 @@ section", " a", " b", "-c", "+C", " d", " e", "-f", "+F", " g")
        #expect(patch.hunks == [hunk(12, 1, 12, 1, 0..<1), hunk(15, 1, 15, 1, 1..<2)])
    }

    @Test func contextPatchPureInsertionAtTopAndBottom() {
        #expect(parse("@@ -1,2 +1,3 @@", "+top", " a", " b").hunks == [hunk(0, 0, 1, 1, 0..<0)])
        #expect(parse("@@ -1,2 +1,3 @@", " a", " b", "+end").hunks == [hunk(2, 0, 3, 1, 0..<0)])
    }

    @Test func contextPatchPureDeletion() {
        #expect(parse("@@ -1,3 +1,2 @@", " a", "-b", " c").hunks == [hunk(2, 1, 1, 0, 0..<1)])
    }

    @Test func emptyContextLineWithStrippedSpaceCounts() {
        let patch = parse("@@ -1,3 +1,3 @@", "", "-b", "+B", " c")
        #expect(patch.hunks == [hunk(2, 1, 2, 1, 0..<1)])
    }

    @Test func hunkOrderIsTopToBottomAndNonOverlapping() {
        let patch = parse("@@ -1,9 +1,9 @@", "-a", "+A", " 1", " 2", " 3", " 4", "-b", "+B", " 5", " 6", "-c", "+C")
        let starts = patch.hunks.map(\.oldStart)
        #expect(starts == starts.sorted())
        #expect(patch.hunks.count == 3)
    }
}
