import MicroDiffCore
import Testing

@Suite("EditSession")
struct EditSessionTests {
    private func session(_ text: String = "abc", stampN: Int = 1) -> EditSession {
        EditSession(loaded: EditableText(text: text, format: FileFormat(), stamp: stamp(stampN)))
    }

    private func disk(_ text: String, _ n: Int, crlf: Bool = false) -> EditableText {
        EditableText(text: text, format: FileFormat(usesCRLF: crlf), stamp: stamp(n))
    }

    private func edit(_ s: inout EditSession, _ text: String) {
        s.textDidChange(length: text.utf16.count) { text }
    }

    private func event(
        _ s: inout EditSession, _ observation: DiskObservation, current: String = "", read: EditableText?
    ) -> DiskOutcome {
        s.diskDidChange(observation, currentText: { current }, readDisk: { read })
    }

    // MARK: dirty

    @Test func startsClean() {
        let s = session()
        #expect(!s.isDirty && s.conflict == nil)
    }

    @Test func editMakesDirtyAndReturningToSavedTextMakesCleanAgain() {
        var s = session("abc")
        edit(&s, "abcd")
        #expect(s.isDirty)
        edit(&s, "abxd")
        #expect(s.isDirty)
        edit(&s, "abc")
        #expect(!s.isDirty)
    }

    @Test func sameLengthDifferentTextIsDirty() {
        var s = session("abc")
        edit(&s, "abd")
        #expect(s.isDirty)
    }

    @Test func differentLengthDoesNotLookAtTheText() {
        var s = session("abc")
        var called = false
        s.textDidChange(length: 4) { called = true; return "abcd" }
        #expect(s.isDirty && !called)
        s.textDidChange(length: 3) { called = true; return "abc" }
        #expect(!s.isDirty && called)
    }

    @Test func canonicallyEquivalentButDifferentBytesIsDirty() {
        // Same UTF-16 length, equal under Swift ==, different bytes on disk.
        var s = session("\u{E9}")
        s.textDidChange(length: 1) { "e\u{301}" }
        #expect(s.isDirty)
    }

    @Test func lengthIsUTF16() {
        var s = session("a\u{1F600}")
        s.textDidChange(length: 3) { "a\u{1F600}" }
        #expect(!s.isDirty)
    }

    // MARK: disk changes

    @Test func unchangedStampDoesNothingAndReadsNothing() {
        var s = session()
        var read = false
        let out = s.diskDidChange(.present(stamp(1)), currentText: { "" }, readDisk: { read = true; return nil })
        #expect(out == .nothing && !read)
    }

    @Test func newStampWithSameTextOnlyRemembersStamp() {
        var s = session("abc")
        #expect(event(&s, .present(stamp(2)), read: disk("abc", 2)) == .nothing)
        // The stamp is remembered: the same event again does not read.
        var read = false
        _ = s.diskDidChange(.present(stamp(2)), currentText: { "" }, readDisk: { read = true; return nil })
        #expect(!read)
    }

    @Test func cleanSessionReloads() {
        var s = session("abc")
        #expect(event(&s, .present(stamp(2)), read: disk("new", 2)) == .reload("new"))
        #expect(s.savedText == "new" && !s.isDirty)
        edit(&s, "new")
        #expect(!s.isDirty)
    }

    @Test func reloadTakesNewLineEndingFormat() {
        var s = session("abc")
        _ = event(&s, .present(stamp(2)), read: disk("a\nb\n", 2, crlf: true))
        #expect(s.format.usesCRLF)
    }

    @Test func dirtyButEditorEqualsDiskBecomesClean() {
        var s = session("abc")
        edit(&s, "xyz")
        #expect(event(&s, .present(stamp(2)), current: "xyz", read: disk("xyz", 2)) == .becameClean)
        #expect(!s.isDirty && s.conflict == nil && s.savedText == "xyz")
    }

    @Test func dirtyAndDifferentIsConflict() {
        var s = session("abc")
        edit(&s, "mine")
        #expect(event(&s, .present(stamp(2)), current: "mine", read: disk("theirs", 2)) == .conflict(.changed))
        #expect(s.conflict == .changed && s.isDirty)
        #expect(s.savedText == "abc")
    }

    @Test func conflictReloadTakesDiskText() {
        var s = session("abc")
        edit(&s, "mine")
        _ = event(&s, .present(stamp(2)), current: "mine", read: disk("theirs", 2))
        #expect(s.reload() == "theirs")
        #expect(!s.isDirty && s.conflict == nil && s.savedText == "theirs")
    }

    @Test func reloadWithoutConflictIsNil() {
        var s = session()
        #expect(s.reload() == nil)
    }

    @Test func keepMineHidesStripAndDoesNotRaiseSameVersionAgain() {
        var s = session("abc")
        edit(&s, "mine")
        _ = event(&s, .present(stamp(2)), current: "mine", read: disk("theirs", 2))
        s.keepMine()
        #expect(s.conflict == nil && s.isDirty)
        #expect(event(&s, .present(stamp(2)), current: "mine", read: disk("theirs", 2)) == .nothing)
        #expect(s.conflict == nil)
    }

    @Test func keepMineRaisesAgainForNewerDiskVersion() {
        var s = session("abc")
        edit(&s, "mine")
        _ = event(&s, .present(stamp(2)), current: "mine", read: disk("theirs", 2))
        s.keepMine()
        #expect(event(&s, .present(stamp(3)), current: "mine", read: disk("theirs 2", 3)) == .conflict(.changed))
        #expect(s.reload() == "theirs 2")
    }

    @Test func secondChangeWhileStripShownReplacesDiskText() {
        var s = session("abc")
        edit(&s, "mine")
        _ = event(&s, .present(stamp(2)), current: "mine", read: disk("v2", 2))
        _ = event(&s, .present(stamp(3)), current: "mine", read: disk("v3", 3))
        #expect(s.reload() == "v3")
    }

    @Test func unreadableDiskIsIgnoredAndRetriedLater() {
        var s = session("abc")
        #expect(event(&s, .present(stamp(2)), read: nil) == .nothing)
        #expect(event(&s, .present(stamp(2)), read: disk("new", 2)) == .reload("new"))
    }

    @Test func deletedWhenCleanLeavesEditMode() {
        var s = session()
        #expect(event(&s, .missing, read: nil) == .fileDeleted)
        #expect(event(&s, .missing, read: nil) == .nothing)
    }

    @Test func deletedWhenDirtyIsDeletedConflict() {
        var s = session()
        edit(&s, "mine")
        #expect(event(&s, .missing, read: nil) == .conflict(.deleted))
        #expect(s.conflict == .deleted)
        #expect(s.reload() == nil)
    }

    @Test func saveAfterDeletedConflictRecreatesAndClears() {
        var s = session()
        edit(&s, "mine")
        _ = event(&s, .missing, read: nil)
        s.didSave(text: "mine", stamp: stamp(5))
        #expect(!s.isDirty && s.conflict == nil && s.savedText == "mine")
        // The watcher reports our own save: no-op.
        #expect(event(&s, .present(stamp(5)), read: disk("mine", 5)) == .nothing)
    }

    @Test func saveWhileChangedConflictWins() {
        var s = session("abc")
        edit(&s, "mine")
        _ = event(&s, .present(stamp(2)), current: "mine", read: disk("theirs", 2))
        s.didSave(text: "mine", stamp: stamp(3))
        #expect(!s.isDirty && s.conflict == nil)
        #expect(s.reload() == nil)
        edit(&s, "mine")
        #expect(!s.isDirty)
        edit(&s, "min")
        #expect(s.isDirty)
    }

    @Test func fileReappearingWithSavedTextClearsDeletedConflict() {
        var s = session("abc")
        edit(&s, "mine")
        _ = event(&s, .missing, read: nil)
        #expect(event(&s, .present(stamp(2)), current: "mine", read: disk("abc", 2)) == .nothing)
        #expect(s.conflict == nil && s.isDirty)
    }
}
