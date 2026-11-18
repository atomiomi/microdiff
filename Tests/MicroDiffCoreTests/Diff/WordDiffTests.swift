import Testing
import MicroDiffCore

/// UTF-16 range of the first occurrence of `needle` in `text`.
private func range(of needle: String, in text: String) -> Range<Int> {
    let r = text.range(of: needle)!
    let start = text.utf16.distance(from: text.startIndex, to: r.lowerBound)
    return start..<(start + needle.utf16.count)
}

private func check(invariantsOf ranges: [Range<Int>], length: Int) -> Bool {
    var previousEnd = 0
    for r in ranges {
        // Strictly greater: touching ranges must have been merged.
        if r.isEmpty || r.lowerBound < previousEnd || r.upperBound > length { return false }
        if r.lowerBound == previousEnd && previousEnd != 0 { return false }
        previousEnd = r.upperBound
    }
    return true
}

@Suite struct WordDiffTests {
    @Test func appendedArgument() throws {
        let old = "            tree.push(entry.path());"
        let new = "            tree.push(entry.path(), entry.kind());"
        let result = try #require(WordDiff.changedRanges(old: old, new: new))
        #expect(result.old.isEmpty)
        #expect(result.new == [range(of: ", entry.kind()", in: new)])
    }

    @Test func changedDigit() throws {
        let result = try #require(WordDiff.changedRanges(old: "let x = 1", new: "let x = 2"))
        #expect(result.old == [8..<9])
        #expect(result.new == [8..<9])
    }

    @Test func identicalLines() throws {
        let result = try #require(WordDiff.changedRanges(old: "let x = 1", new: "let x = 1"))
        #expect(result.old.isEmpty && result.new.isEmpty)
        let empty = try #require(WordDiff.changedRanges(old: "", new: ""))
        #expect(empty.old.isEmpty && empty.new.isEmpty)
    }

    @Test func nothingInCommon() {
        #expect(WordDiff.changedRanges(old: "import Foundation", new: "}") == nil)
    }

    @Test func oneSideEmpty() {
        #expect(WordDiff.changedRanges(old: "", new: "let x = 1") == nil)
        #expect(WordDiff.changedRanges(old: "let x = 1", new: "") == nil)
        #expect(WordDiff.changedRanges(old: "   ", new: "") == nil)
    }

    @Test func renameInsideCall() throws {
        let result = try #require(WordDiff.changedRanges(old: "foo(bar)", new: "foo(baz)"))
        #expect(result.old == [4..<7])
        #expect(result.new == [4..<7])
    }

    @Test func indentationOnly() throws {
        let result = try #require(WordDiff.changedRanges(old: "    return x", new: "\t\treturn x"))
        #expect(result.old == [0..<4])
        #expect(result.new == [0..<2])
        let added = try #require(WordDiff.changedRanges(old: "return x", new: "    return x"))
        #expect(added.old.isEmpty)
        #expect(added.new == [0..<4])
    }

    @Test func adjacentChangesMerge() throws {
        // "a.b" -> "x.y": the dot is common, so two ranges. "ab cd" -> "xy zw" shares only the space.
        let two = try #require(WordDiff.changedRanges(old: "call(a.b, keep)", new: "call(x.y, keep)"))
        #expect(two.old == [5..<6, 7..<8])
        let merged = try #require(WordDiff.changedRanges(old: "keep one(two) there", new: "keep (1)(2) there"))
        #expect(check(invariantsOf: merged.old, length: 19))
        #expect(check(invariantsOf: merged.new, length: 17))
    }

    @Test func accentedLetters() throws {
        let old = "let café = 1"
        let new = "let cafés = 1"
        let result = try #require(WordDiff.changedRanges(old: old, new: new))
        // "café" and "cafés" are different word tokens.
        #expect(result.old == [range(of: "café", in: old)])
        #expect(result.new == [range(of: "cafés", in: new)])
    }

    @Test func combiningMarkStaysInItsWord() throws {
        let old = "let cafe\u{301} = 1" // e + combining acute
        let new = "let cafe\u{301}s = 1"
        let result = try #require(WordDiff.changedRanges(old: old, new: new))
        #expect(result.old == [4..<9])
        #expect(result.new == [4..<10])
    }

    @Test func emojiNeverSplitsSurrogatePairs() throws {
        let old = "say(\"hi 😀 there\") // ok"
        let new = "say(\"hi 🎉 there\") // ok"
        let result = try #require(WordDiff.changedRanges(old: old, new: new))
        let emoji = range(of: "😀", in: old)
        #expect(emoji.count == 2)
        #expect(result.old == [emoji])
        #expect(result.new == [range(of: "🎉", in: new)])
    }

    @Test func emojiSequenceIsOneUnit() throws {
        let family = "👨‍👩‍👧"
        let old = "title: \(family) done"
        let new = "title: \(family)\(family) done"
        let result = try #require(WordDiff.changedRanges(old: old, new: new))
        #expect(result.old.isEmpty)
        #expect(result.new == [range(of: family, in: old).count + 7..<range(of: family, in: old).count * 2 + 7])
    }

    @Test func tooLongLineIsSkipped() {
        let long = String(repeating: "a", count: WordDiff.maxLineLength + 1)
        #expect(WordDiff.changedRanges(old: long, new: long + "b") == nil)
        #expect(WordDiff.changedRanges(old: "x", new: long) == nil)
        let ok = String(repeating: "a ", count: WordDiff.maxLineLength / 2 - 1)
        #expect(WordDiff.changedRanges(old: ok, new: ok + "b") != nil)
    }

    @Test func hugeMiddleIsTreatedAsChanged() throws {
        // Both middles are ~900 tokens, over the DP cap, so nothing in them counts as common: the 30% rule rejects it.
        let body = String(repeating: "a.", count: 450)
        #expect(WordDiff.changedRanges(old: "[" + body + "]", new: "{" + body + "}") == nil)
    }

    @Test func longCommonEdgesSurviveSmallMiddle() throws {
        let shared = String(repeating: "ab.", count: 300)
        let old = shared + "(1)" + shared
        let new = shared + "(2)" + shared
        let result = try #require(WordDiff.changedRanges(old: old, new: new))
        #expect(result.old == [901..<902])
        #expect(result.new == [901..<902])
    }

    @Test func randomLinesKeepInvariants() {
        var rng = SeededGenerator(seed: 2024)
        let pieces = ["foo", "bar", "_x1", " ", "  ", "(", ")", ".", ",", "😀", "é", "e\u{301}", "=", "42", "\t", "日本", "{", "->"]
        func line(_ rng: inout SeededGenerator) -> String {
            (0..<Int.random(in: 0...14, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
        }
        var nonNil = 0
        for _ in 0..<2000 {
            let old = line(&rng)
            var new = line(&rng)
            if Bool.random(using: &rng) { new = old + pieces.randomElement(using: &rng)! }
            guard let r = WordDiff.changedRanges(old: old, new: new) else { continue }
            nonNil += 1
            #expect(check(invariantsOf: r.old, length: old.utf16.count), "\(old) | \(new)")
            #expect(check(invariantsOf: r.new, length: new.utf16.count), "\(old) | \(new)")
            if old == new { #expect(r.old.isEmpty && r.new.isEmpty) }
            // Ranges must never start or end inside a surrogate pair.
            for (text, ranges) in [(old, r.old), (new, r.new)] {
                let units = Array(text.utf16)
                for range in ranges {
                    #expect(!UTF16.isTrailSurrogate(units[range.lowerBound]))
                    if range.upperBound < units.count { #expect(!UTF16.isTrailSurrogate(units[range.upperBound])) }
                }
            }
        }
        #expect(nonNil > 100)
    }
}
