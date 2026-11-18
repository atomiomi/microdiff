import MicroDiffCore
import Testing

@Suite struct StatusParserTests {
    /// Joins records the way `-z` does: every record ends with NUL.
    private func z(_ records: String...) -> Data {
        Data((records.joined(separator: "\0") + "\0").utf8)
    }

    private func entry(_ xy: String, _ path: String, sub: String = "N...") -> String {
        "1 \(xy) \(sub) 100644 100644 100644 aaaa bbbb \(path)"
    }

    private func rename(_ xy: String, _ path: String, score: String = "R100") -> String {
        "2 \(xy) N... 100644 100644 100644 aaaa bbbb \(score) \(path)"
    }

    private func conflict(_ xy: String, _ path: String) -> String {
        "u \(xy) N... 100644 100644 100644 100644 aaaa bbbb cccc \(path)"
    }

    private func parse(_ records: String...) -> RepoStatus {
        StatusParser.parse(Data((records.joined(separator: "\0") + "\0").utf8))
    }

    // MARK: nested repositories

    @Test func untrackedEntriesEndingInASlashAreNestedRepoCandidatesNotChanges() {
        let status = parse("? some-repo/", "? new.txt", entry(".M", "a.txt"), "? deep/er/inner/")
        #expect(status.nestedRepoCandidates == ["some-repo/", "deep/er/inner/"])
        #expect(status.changes == [
            FileChange(path: "new.txt", kind: .added, isUntracked: true), FileChange(path: "a.txt", kind: .modified),
        ])
    }

    @Test func nestedRepoCandidatePathsWithSpacesAndNonASCII() {
        let status = parse("? my repo/", "? café 日本/", "? plain file.txt")
        #expect(status.nestedRepoCandidates == ["my repo/", "café 日本/"])
        #expect(status.changes == [FileChange(path: "plain file.txt", kind: .added, isUntracked: true)])
    }

    @Test func untrackedPlainFileStillWorksAndIgnoredDirectoriesAreNotCandidates() {
        let status = parse("? a/b.txt", "! node_modules/")
        #expect(status.nestedRepoCandidates.isEmpty)
        #expect(status.ignored == ["node_modules/"])
        #expect(status.changes == [FileChange(path: "a/b.txt", kind: .added, isUntracked: true)])
    }

    @Test func aCandidateDoesNotMergeWithADeletedFileOfTheSameName() {
        let status = parse(entry(".D", "x"), "? x/")
        #expect(status.nestedRepoCandidates == ["x/"])
        #expect(status.changes == [FileChange(path: "x", kind: .deleted)])
    }

    // MARK: XY mapping

    @Test(arguments: [
        (".M", ChangeKind.modified),
        ("M.", .modified),
        ("MM", .modified),
        ("T.", .modified),
        (".T", .modified),
        ("A.", .added),
        ("AM", .added),
        ("C.", .added),
        (".D", .deleted),
        ("D.", .deleted),
        ("MD", .deleted),
        ("AD", nil),
    ] as [(String, ChangeKind?)])
    func mapsType1XY(xy: String, expected: ChangeKind?) {
        let status = parse(entry(xy, "f.txt"))
        if let expected {
            #expect(status.changes == [FileChange(path: "f.txt", kind: expected)])
        } else {
            #expect(status.changes.isEmpty)
        }
    }

    @Test func conflictRecordIsConflicted() {
        for xy in ["UU", "AA", "DD", "AU", "UD"] {
            #expect(parse(conflict(xy, "c.txt")).changes == [FileChange(path: "c.txt", kind: .conflicted)])
        }
    }

    @Test func untrackedRecordIsAddedAndUntracked() {
        #expect(parse("? new/dir/file.txt").changes == [FileChange(path: "new/dir/file.txt", kind: .added, isUntracked: true)])
    }

    @Test func ignoredRecordIsSkipped() {
        #expect(parse("! build/out.o").changes.isEmpty)
    }

    @Test func ignoredRecordsAreCollectedAndDirectoriesKeepTheSlash() {
        let status = parse("! node_modules/", "! .env", "! my dir/a b.log", entry(".M", "a.txt"), "!x", "! ")
        #expect(status.ignored == ["node_modules/", ".env", "my dir/a b.log"])
        #expect(status.changes.count == 1)
    }

    // MARK: renames

    @Test func renameConsumesOriginalPathRecord() {
        let status = parse(rename("R.", "new.txt"), "old.txt", entry(".M", "after.txt"))
        #expect(status.changes == [
            FileChange(path: "new.txt", oldPath: "old.txt", kind: .renamed),
            FileChange(path: "after.txt", kind: .modified),
        ])
    }

    @Test func renameThenEditedStaysRenamed() {
        let status = parse(rename("RM", "new.txt", score: "R87"), "old.txt")
        #expect(status.changes == [FileChange(path: "new.txt", oldPath: "old.txt", kind: .renamed)])
    }

    @Test func renamedThenDeletedIsDeletedAtOriginalPath() {
        let status = parse(rename("RD", "new.txt"), "old.txt")
        #expect(status.changes == [FileChange(path: "old.txt", kind: .deleted)])
    }

    @Test func copyIsAddedAtNewPath() {
        let status = parse(rename("C.", "copy.txt", score: "C100"), "orig.txt")
        #expect(status.changes == [FileChange(path: "copy.txt", kind: .added)])
    }

    @Test func renameWithoutOriginalRecordIsDropped() {
        #expect(parse(rename("R.", "new.txt")).changes.isEmpty)
    }

    // MARK: paths

    @Test(arguments: ["with space.txt", "dir with space/a b.txt", "ünï/日本語 ✓.txt", "-leading-dash.txt", "a  b.txt", " lead.txt", "x y z/ ."])
    func keepsUnusualPathsIntact(path: String) {
        let status = parse(entry(".M", path), "? " + path + "2", rename("R.", path + "3"), path + "4", conflict("UU", path + "5"))
        #expect(status.changes.map(\.path) == [path, path + "2", path + "3", path + "5"])
        #expect(status.changes[2].oldPath == path + "4")
    }

    // MARK: headers

    @Test func parsesBranchHeaders() {
        let status = parse(
            "# branch.oid 0123456789abcdef0123456789abcdef01234567", "# branch.head feature/x",
            "# branch.upstream origin/feature/x", "# branch.ab +1 -2")
        #expect(status.headOID == "0123456789abcdef0123456789abcdef01234567")
        #expect(status.branch == "feature/x")
        #expect(status.changes.isEmpty)
    }

    @Test func initialAndDetachedHeadersGiveNil() {
        let fresh = parse("# branch.oid (initial)", "# branch.head main")
        #expect(fresh.headOID == nil)
        #expect(fresh.branch == "main")
        let detached = parse("# branch.oid abc1234abc1234abc1234abc1234abc1234abc12", "# branch.head (detached)")
        #expect(detached.headOID != nil)
        #expect(detached.branch == nil)
    }

    @Test func branchNameWithSpaceSurvives() {
        #expect(parse("# branch.head odd name").branch == "odd name")
    }

    // MARK: submodules

    @Test(arguments: [
        ("S...", false, false, false),
        ("SC..", true, false, false),
        ("S.M.", false, true, false),
        ("S..U", false, false, true),
        ("SCM.", true, true, false),
        ("SC.U", true, false, true),
        ("S.MU", false, true, true),
        ("SCMU", true, true, true),
    ] as [(String, Bool, Bool, Bool)])
    func submoduleFlags(sub: String, commit: Bool, modified: Bool, untracked: Bool) {
        let status = parse(entry(".M", "libs/dep", sub: sub))
        #expect(status.changes.isEmpty)
        #expect(status.submodules == [SubmoduleState(path: "libs/dep", commitChanged: commit, hasModifiedContent: modified, hasUntrackedContent: untracked)])
    }

    // MARK: merging and ordering

    @Test func deletedPlusUntrackedMergeIntoOneModified() {
        let status = parse(entry("D.", "a.txt"), entry(".M", "b.txt"), "? a.txt", "? c.txt")
        #expect(status.changes == [
            FileChange(path: "a.txt", kind: .modified),
            FileChange(path: "b.txt", kind: .modified),
            FileChange(path: "c.txt", kind: .added, isUntracked: true),
        ])
    }

    @Test func unstagedDeletePlusUntrackedMerges() {
        #expect(parse(entry(".D", "a.txt"), "? a.txt").changes == [FileChange(path: "a.txt", kind: .modified)])
    }

    @Test func keepsGitOrder() {
        let status = parse(entry(".M", "z.txt"), entry("A.", "a.txt"), "? m.txt")
        #expect(status.changes.map(\.path) == ["z.txt", "a.txt", "m.txt"])
    }

    // MARK: bad input

    @Test func emptyInputGivesEmptyStatus() {
        #expect(StatusParser.parse(Data()) == RepoStatus())
    }

    @Test(arguments: [
        "", "1", "1 .M", "1 .M N... 100644", "2 R. N... 1 2 3 4 5", "u UU", "?", "? ", "?x", "x garbage", "# branch.oid", "1 .M N... 1 2 3 4 5 ",
        "1x.M N... 100644 100644 100644 a b path", "\u{1}\u{2}\u{3}",
    ])
    func garbageRecordsAreSkipped(record: String) {
        let status = parse(record, entry(".M", "ok.txt"))
        #expect(status.changes.last == FileChange(path: "ok.txt", kind: .modified))
    }

    @Test func truncatedInputNeverCrashes() {
        let full = z("# branch.oid abc", "# branch.head main", entry("MM", "some/path.txt"), rename("R.", "n.txt"), "o.txt", "? u.txt")
        for cut in 0...full.count {
            _ = StatusParser.parse(full.prefix(cut))
        }
        var noise = Data()
        for i in 0..<5000 { noise.append(UInt8(truncatingIfNeeded: i &* 31 &+ i >> 3)) }
        _ = StatusParser.parse(noise)
    }

    @Test func missingFinalTerminatorStillParses() {
        let data = Data(entry(".M", "a.txt").utf8)
        #expect(StatusParser.parse(data).changes == [FileChange(path: "a.txt", kind: .modified)])
    }

    @Test func invalidUTF8PathDoesNotCrash() {
        var data = Data("? ".utf8)
        data.append(contentsOf: [0xFF, 0xFE, 0x61, 0])
        #expect(StatusParser.parse(data).changes.count == 1)
    }

    @Test func parsesTenThousandRecordsQuickly() {
        var text = "# branch.oid abc\0# branch.head main\0"
        for i in 0..<10_000 {
            switch i % 4 {
            case 0: text += entry(".M", "src/module\(i)/file \(i).swift") + "\0"
            case 1: text += rename("R.", "src/new\(i).swift") + "\0src/old\(i).swift\0"
            case 2: text += entry("A.", "src/added\(i).swift") + "\0"
            default: text += "? untracked/dir\(i)/x.txt\0"
            }
        }
        let data = Data(text.utf8)
        let start = ContinuousClock.now
        let status = StatusParser.parse(data)
        let elapsed = ContinuousClock.now - start
        #expect(status.changes.count == 10_000)
        // Generous bound so debug builds on a busy machine pass; release is a few milliseconds.
        #expect(elapsed < .seconds(1))
    }
}
