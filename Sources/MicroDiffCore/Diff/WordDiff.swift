import Foundation

/// Finds which words changed between an old and a new version of one line.
package enum WordDiff {
    /// Lines longer than this (UTF-16 units) are not compared.
    package static let maxLineLength = 2000

    /// Above this many DP cells the middle part is treated as fully changed instead of allocating a big table.
    private static let maxTableCells = 250_000

    /// Returns the changed ranges of both lines as UTF-16 offsets, or nil when highlighting would not help.
    ///
    /// - Tokens: a run of letters/digits/"_" is one token; a run of whitespace is one token; every other character is its own token.
    /// - Compare the token sequences with a longest-common-subsequence diff. Tokens not in the common subsequence are "changed".
    /// - Adjacent changed tokens are merged into one range. Ranges are sorted and never overlap.
    /// - Returns `([], [])` when the lines are equal.
    /// - Returns nil when either line is longer than `maxLineLength`, or when the lines have too little in common:
    ///   the common non-whitespace characters are less than 30% of the longer line's non-whitespace characters.
    /// - Leading whitespace that differs counts as changed like anything else.
    package static func changedRanges(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>])? {
        guard old.utf16.count <= maxLineLength, new.utf16.count <= maxLineLength else { return nil }
        if old == new { return ([], []) }

        var ids: [String: Int] = [:]
        let a = tokenize(old, ids: &ids)
        let b = tokenize(new, ids: &ids)

        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix].id == b[prefix].id { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix].id == b[b.count - 1 - suffix].id { suffix += 1 }

        var changedOld = [Bool](repeating: true, count: a.count)
        var changedNew = [Bool](repeating: true, count: b.count)
        for i in 0..<prefix { changedOld[i] = false; changedNew[i] = false }
        for i in 0..<suffix { changedOld[a.count - 1 - i] = false; changedNew[b.count - 1 - i] = false }

        let midOld = prefix..<(a.count - suffix)
        let midNew = prefix..<(b.count - suffix)
        if !midOld.isEmpty, !midNew.isEmpty, midOld.count * midNew.count <= maxTableCells {
            markCommon(a, midOld, b, midNew, changedOld: &changedOld, changedNew: &changedNew)
        }

        var common = 0
        for (i, token) in a.enumerated() where !changedOld[i] && !token.isSpace { common += token.length }
        let denominator = max(a.reduce(0) { $0 + ($1.isSpace ? 0 : $1.length) },
                              b.reduce(0) { $0 + ($1.isSpace ? 0 : $1.length) })
        guard denominator > 0, common * 10 >= denominator * 3 else { return nil }

        return (ranges(a, changed: changedOld), ranges(b, changed: changedNew))
    }

    private struct Token {
        var id: Int
        var start: Int
        var length: Int
        var isSpace: Bool
    }

    private static func tokenize(_ text: String, ids: inout [String: Int]) -> [Token] {
        var tokens: [Token] = []
        var offset = 0
        var lastWordOrSpace: (isSpace: Bool, start: Int, text: String)?

        func flush() {
            guard let run = lastWordOrSpace else { return }
            tokens.append(Token(id: id(run.text, &ids), start: run.start, length: offset - run.start, isSpace: run.isSpace))
            lastWordOrSpace = nil
        }
        func id(_ key: String, _ ids: inout [String: Int]) -> Int {
            if let existing = ids[key] { return existing }
            ids[key] = ids.count
            return ids.count - 1
        }

        for ch in text {
            let length = ch.utf16.count
            let kind = classify(ch)
            switch kind {
            case .word, .space:
                let isSpace = kind == .space
                if let run = lastWordOrSpace, run.isSpace == isSpace {
                    lastWordOrSpace?.text.append(ch)
                } else {
                    flush()
                    lastWordOrSpace = (isSpace, offset, String(ch))
                }
            case .other:
                flush()
                tokens.append(Token(id: id(String(ch), &ids), start: offset, length: length, isSpace: false))
            }
            offset += length
        }
        flush()
        return tokens
    }

    private enum CharClass { case word, space, other }

    private static func classify(_ ch: Character) -> CharClass {
        guard let first = ch.unicodeScalars.first else { return .other }
        if ch == "_" || ch.isLetter || ch.isNumber { return .word }
        if ch.isWhitespace { return .space }
        // A lone combining mark (no base letter) still belongs to the word it follows.
        switch first.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return .word
        default: return .other
        }
    }

    /// Clears the changed flag of tokens in a longest common subsequence of the two middle slices.
    private static func markCommon(
        _ a: [Token], _ ra: Range<Int>, _ b: [Token], _ rb: Range<Int>,
        changedOld: inout [Bool], changedNew: inout [Bool]
    ) {
        let m = ra.count
        let n = rb.count
        let width = n + 1
        // table[i * width + j] = LCS length of the last (m - i) old and (n - j) new tokens.
        var table = [Int32](repeating: 0, count: (m + 1) * width)
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                if a[ra.lowerBound + i].id == b[rb.lowerBound + j].id {
                    table[i * width + j] = table[(i + 1) * width + j + 1] + 1
                } else {
                    table[i * width + j] = max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
        }
        var i = 0
        var j = 0
        while i < m, j < n {
            if a[ra.lowerBound + i].id == b[rb.lowerBound + j].id {
                changedOld[ra.lowerBound + i] = false
                changedNew[rb.lowerBound + j] = false
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
    }

    /// Changed tokens as UTF-16 ranges; ranges that touch are merged.
    private static func ranges(_ tokens: [Token], changed: [Bool]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for (i, token) in tokens.enumerated() where changed[i] {
            let end = token.start + token.length
            if let last = result.last, last.upperBound == token.start {
                result[result.count - 1] = last.lowerBound..<end
            } else {
                result.append(token.start..<end)
            }
        }
        return result
    }
}
