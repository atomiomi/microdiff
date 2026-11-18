import Testing
import MicroDiffCore

private func ctx(_ number: Int) -> DiffRow { DiffRow(kind: .context, line: number - 1, number: number) }
private func add(_ number: Int, hunk: Int) -> DiffRow { DiffRow(kind: .added, line: number - 1, number: number, hunk: hunk) }
private func del(_ line: Int, hunk: Int) -> DiffRow { DiffRow(kind: .deleted, line: line, hunk: hunk) }
private func fold(line: Int, count: Int) -> DiffRow { DiffRow(kind: .fold, line: line, count: count) }

private func rows(_ doc: DiffDocument) -> [DiffRow] { (0..<doc.rowCount).map { doc.row(at: $0) } }

private func patch(_ hunks: Hunk...) -> FilePatch { FilePatch(hunks: hunks) }

private let workedHunks = [
    Hunk(oldStart: 17, oldCount: 1, newStart: 17, newCount: 1, deletedLines: 0..<1),
    Hunk(oldStart: 19, oldCount: 0, newStart: 20, newCount: 4, deletedLines: 1..<1),
    Hunk(oldStart: 43, oldCount: 2, newStart: 46, newCount: 0, deletedLines: 1..<3),
    Hunk(oldStart: 45, oldCount: 0, newStart: 48, newCount: 1, deletedLines: 3..<3),
]

@Suite struct DiffDocumentWorkedExampleTests {
    let doc = DiffDocument.diff(patch: FilePatch(hunks: workedHunks), newLineCount: 62)

    @Test func rowsMatchTheSpec() {
        var expected: [DiffRow] = [fold(line: 0, count: 13), ctx(14), ctx(15), ctx(16), del(0, hunk: 0), add(17, hunk: 0), ctx(18), ctx(19)]
        expected += (20...23).map { add($0, hunk: 1) }
        expected += [ctx(24), ctx(25), ctx(26), fold(line: 26, count: 17), ctx(44), ctx(45), ctx(46)]
        expected += [del(1, hunk: 2), del(2, hunk: 2), ctx(47), add(48, hunk: 3), ctx(49), ctx(50), ctx(51), fold(line: 51, count: 11)]
        #expect(expected.count == 27)
        #expect(rows(doc) == expected)
    }

    @Test func counts() {
        #expect(doc.rowCount == 27)
        #expect(doc.foldCount == 3)
        #expect(doc.contentHeight == 558)
    }

    @Test func counterparts() {
        #expect(doc.counterpart(ofRow: 4) == 5)
        #expect(doc.counterpart(ofRow: 5) == 4)
        for i in 0..<doc.rowCount where i != 4 && i != 5 {
            #expect(doc.counterpart(ofRow: i) == nil, "row \(i)")
        }
        #expect(doc.counterpart(ofRow: -1) == nil)
        #expect(doc.counterpart(ofRow: 27) == nil)
    }

    @Test func positions() {
        #expect(doc.y(ofRow: 0) == 0)
        #expect(doc.y(ofRow: 1) == 26)
        #expect(doc.y(ofRow: 27) == 558)
        #expect(doc.height(ofRow: 0) == 26)
        #expect(doc.height(ofRow: 1) == 20)
        #expect(doc.rowIndex(atY: 0) == 0)
        #expect(doc.rowIndex(atY: 25.9) == 0)
        #expect(doc.rowIndex(atY: 26) == 1)
        #expect(doc.rowIndex(atY: -5) == 0)
        #expect(doc.rowIndex(atY: 558) == 26)
        #expect(doc.rowIndex(atY: 10_000) == 26)
        for i in 0..<doc.rowCount {
            #expect(doc.rowIndex(atY: doc.y(ofRow: i)) == i)
            #expect(doc.rowIndex(atY: doc.y(ofRow: i) + doc.height(ofRow: i) - 0.01) == i)
        }
    }

    @Test func expandedFoldShowsContext() {
        let expanded = DiffDocument.diff(patch: FilePatch(hunks: workedHunks), newLineCount: 62, expandedFolds: [26])
        #expect(expanded.foldCount == 2)
        #expect(expanded.rowCount == 27 - 1 + 17)
        let all = rows(expanded)
        #expect(all[15...31].map(\.number) == Array(27...43).map { Optional($0) })
        #expect(all[0].kind == .fold)
        #expect(all.last?.kind == .fold)
    }

    @Test func customMetrics() {
        let doc = DiffDocument.diff(patch: FilePatch(hunks: workedHunks), newLineCount: 62, metrics: RowMetrics(lineHeight: 10, foldHeight: 4))
        #expect(doc.contentHeight == 24 * 10 + 3 * 4)
    }
}

@Suite struct DiffDocumentEdgeTests {
    @Test func noHunksIsAllContext() {
        let doc = DiffDocument.diff(patch: .empty, newLineCount: 30)
        #expect(doc.foldCount == 0)
        #expect(rows(doc) == (1...30).map(ctx))
    }

    @Test func emptyDocument() {
        let doc = DiffDocument.diff(patch: .empty, newLineCount: 0)
        #expect(doc.rowCount == 0)
        #expect(doc.contentHeight == 0)
        #expect(doc.rowIndex(atY: 5) == 0)
        #expect(doc.y(ofRow: 0) == 0)
        #expect(DiffDocument().rowCount == 0)
    }

    @Test func fileEmptiedLeavesOnlyDeletedRows() {
        let p = patch(Hunk(oldStart: 1, oldCount: 3, newStart: 0, newCount: 0, deletedLines: 0..<3))
        let doc = DiffDocument.diff(patch: p, newLineCount: 0)
        #expect(rows(doc) == [del(0, hunk: 0), del(1, hunk: 0), del(2, hunk: 0)])
        #expect(doc.foldCount == 0)
    }

    @Test func deletionAtTop() {
        let p = patch(Hunk(oldStart: 1, oldCount: 2, newStart: 0, newCount: 0, deletedLines: 0..<2))
        let doc = DiffDocument.diff(patch: p, newLineCount: 20)
        let all = rows(doc)
        #expect(Array(all[0...4]) == [del(0, hunk: 0), del(1, hunk: 0), ctx(1), ctx(2), ctx(3)])
        #expect(all[5] == fold(line: 3, count: 17))
        #expect(all.count == 6)
    }

    @Test func insertionAtTop() {
        let p = patch(Hunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 2, deletedLines: 0..<0))
        let doc = DiffDocument.diff(patch: p, newLineCount: 20)
        let all = rows(doc)
        #expect(Array(all[0...4]) == [add(1, hunk: 0), add(2, hunk: 0), ctx(3), ctx(4), ctx(5)])
        #expect(all[5] == fold(line: 5, count: 15))
        #expect(doc.counterpart(ofRow: 0) == nil)
    }

    @Test func changeOnLastLine() {
        let p = patch(Hunk(oldStart: 20, oldCount: 1, newStart: 20, newCount: 1, deletedLines: 0..<1))
        let doc = DiffDocument.diff(patch: p, newLineCount: 20)
        let all = rows(doc)
        #expect(all.first == fold(line: 0, count: 16))
        #expect(Array(all.dropFirst()) == [ctx(17), ctx(18), ctx(19), del(0, hunk: 0), add(20, hunk: 0)])
    }

    @Test func deletionAtEnd() {
        let p = patch(Hunk(oldStart: 21, oldCount: 1, newStart: 20, newCount: 0, deletedLines: 0..<1))
        let all = rows(DiffDocument.diff(patch: p, newLineCount: 20))
        #expect(all.last == del(0, hunk: 0))
        #expect(all[all.count - 2] == ctx(20))
    }

    @Test func touchingContextMergesHunks() {
        // Hunks at lines 10 and 17: contexts 11...13 and 14...16 touch, no fold between.
        let p = patch(
            Hunk(oldStart: 10, oldCount: 0, newStart: 10, newCount: 1, deletedLines: 0..<0),
            Hunk(oldStart: 10, oldCount: 0, newStart: 17, newCount: 1, deletedLines: 0..<0))
        let doc = DiffDocument.diff(patch: p, newLineCount: 30)
        #expect(doc.foldCount == 2)
        let middle = rows(doc).dropFirst().dropLast()
        let three = [DiffRowKind](repeating: .context, count: 3)
        let six = [DiffRowKind](repeating: .context, count: 6)
        let expected: [DiffRowKind] = three + [.added] + six + [.added] + three
        #expect(Array(middle.map(\.kind)) == expected)
    }

    @Test func overlappingContextMergesHunks() {
        let p = patch(
            Hunk(oldStart: 10, oldCount: 0, newStart: 10, newCount: 1, deletedLines: 0..<0),
            Hunk(oldStart: 10, oldCount: 0, newStart: 13, newCount: 1, deletedLines: 0..<0))
        let doc = DiffDocument.diff(patch: p, newLineCount: 30)
        #expect(doc.foldCount == 2)
    }

    @Test(arguments: [(3, false), (4, true), (5, true)])
    func foldThreshold(hidden: Int, isFold: Bool) {
        // One change at line 20 hides lines 1...16 above it; a second one hides `hidden` lines in between.
        let second = 27 + hidden // hunk 1 context ends at line 23 (1-based), hunk 2 context starts at second - 3
        let p = patch(
            Hunk(oldStart: 20, oldCount: 0, newStart: 20, newCount: 1, deletedLines: 0..<0),
            Hunk(oldStart: 20, oldCount: 0, newStart: second, newCount: 1, deletedLines: 0..<0))
        let doc = DiffDocument.diff(patch: p, newLineCount: second + 3)
        #expect(doc.foldCount == (isFold ? 2 : 1))
        let all = rows(doc)
        #expect(all.contains(fold(line: 23, count: hidden)) == isFold)
    }

    @Test func zeroContext() {
        let p = patch(
            Hunk(oldStart: 10, oldCount: 1, newStart: 10, newCount: 1, deletedLines: 0..<1),
            Hunk(oldStart: 20, oldCount: 1, newStart: 20, newCount: 0, deletedLines: 1..<2))
        let doc = DiffDocument.diff(patch: p, newLineCount: 30, context: 0)
        let all = rows(doc)
        #expect(all == [
            fold(line: 0, count: 9), del(0, hunk: 0), add(10, hunk: 0),
            fold(line: 10, count: 10), del(1, hunk: 1), fold(line: 20, count: 10),
        ])
    }

    @Test func staleHunksAreClamped() {
        let p = patch(
            Hunk(oldStart: 3, oldCount: 1, newStart: 3, newCount: 2, deletedLines: 0..<1),
            Hunk(oldStart: 40, oldCount: 2, newStart: 90, newCount: 5, deletedLines: 1..<3),
            Hunk(oldStart: 99, oldCount: 1, newStart: 200, newCount: 0, deletedLines: 3..<4))
        for n in [0, 1, 2, 3, 5, 10] {
            let doc = DiffDocument.diff(patch: p, newLineCount: n)
            for r in rows(doc) {
                switch r.kind {
                case .context, .added: #expect(r.line >= 0 && r.line < n)
                case .fold: #expect(r.line >= 0 && r.line + r.count <= n)
                case .deleted: break
                }
            }
            #expect(doc.rowCount >= 0)
        }
    }

    @Test func extremeNumbersDoNotTrap() {
        let p = patch(Hunk(oldStart: Int.max, oldCount: Int.max, newStart: Int.min, newCount: Int.max, deletedLines: 0..<0))
        let doc = DiffDocument.diff(patch: p, newLineCount: 10, context: Int.max, minFoldLines: Int.min)
        #expect(doc.rowCount == 10)
        _ = DiffDocument.diff(patch: p, newLineCount: Int.max)
        _ = DiffDocument.diff(patch: p, newLineCount: -4)
    }

    @Test func outOfRangeQueriesAreClamped() {
        let doc = DiffDocument.diff(patch: FilePatch(hunks: workedHunks), newLineCount: 62)
        #expect(doc.row(at: -1) == doc.row(at: 0))
        #expect(doc.row(at: 1000) == doc.row(at: 26))
        #expect(doc.y(ofRow: 1000) == doc.contentHeight)
        #expect(doc.y(ofRow: -3) == 0)
        #expect(doc.rowIndex(atY: .nan) == 0)
        #expect(doc.rowIndex(atY: .infinity) == 26)
    }

    @Test func counterpartPairsKthWithKth() {
        let p = patch(
            Hunk(oldStart: 5, oldCount: 3, newStart: 5, newCount: 2, deletedLines: 0..<3),
            Hunk(oldStart: 40, oldCount: 1, newStart: 39, newCount: 3, deletedLines: 3..<4))
        let doc = DiffDocument.diff(patch: p, newLineCount: 60)
        let all = rows(doc)
        let d0 = all.firstIndex { $0.kind == .deleted }!
        // hunk 0: 3 deleted, 2 added
        #expect(doc.counterpart(ofRow: d0) == d0 + 3)
        #expect(doc.counterpart(ofRow: d0 + 1) == d0 + 4)
        #expect(doc.counterpart(ofRow: d0 + 2) == nil)
        #expect(doc.counterpart(ofRow: d0 + 3) == d0)
        #expect(doc.counterpart(ofRow: d0 + 4) == d0 + 1)
        // hunk 1: 1 deleted, 3 added
        let d1 = all.lastIndex { $0.kind == .deleted }!
        #expect(doc.counterpart(ofRow: d1) == d1 + 1)
        #expect(doc.counterpart(ofRow: d1 + 1) == d1)
        #expect(doc.counterpart(ofRow: d1 + 2) == nil)
        #expect(doc.counterpart(ofRow: d1 + 3) == nil)
    }

    @Test func adjacentHunksDoNotPairAcrossHunks() {
        // Hunk 0 only deletes, hunk 1 (next line) only adds: the rows must not pair.
        let p = patch(
            Hunk(oldStart: 5, oldCount: 1, newStart: 4, newCount: 0, deletedLines: 0..<1),
            Hunk(oldStart: 6, oldCount: 0, newStart: 6, newCount: 1, deletedLines: 1..<1))
        let doc = DiffDocument.diff(patch: p, newLineCount: 10)
        for i in 0..<doc.rowCount { #expect(doc.counterpart(ofRow: i) == nil) }
    }
}

@Suite struct DiffDocumentModeTests {
    @Test func fileMarks() {
        let doc = DiffDocument.file(patch: FilePatch(hunks: workedHunks), lineCount: 62)
        #expect(doc.rowCount == 62)
        #expect(doc.foldCount == 0)
        #expect(doc.contentHeight == 62 * 20)
        let all = rows(doc)
        for (i, r) in all.enumerated() {
            let number = i + 1
            #expect(r.kind == .context && r.line == i && r.number == number && r.hunk == -1 && r.count == 1)
            let expected: LineMark = number == 17 ? .modified : ((20...23).contains(number) || number == 48) ? .added : .none
            #expect(r.mark == expected, "line \(number)")
        }
    }

    @Test func fileStaleHunkIsClamped() {
        let p = patch(Hunk(oldStart: 1, oldCount: 0, newStart: 8, newCount: 10, deletedLines: 0..<0))
        let doc = DiffDocument.file(patch: p, lineCount: 10)
        #expect(doc.rowCount == 10)
        #expect(rows(doc).filter { $0.mark == .added }.count == 3)
    }

    @Test func deletedFile() {
        let doc = DiffDocument.deletedFile(lineCount: 7)
        #expect(doc.rowCount == 7)
        #expect(rows(doc) == (0..<7).map { DiffRow(kind: .deleted, line: $0, number: $0 + 1, hunk: -1) })
        #expect(DiffDocument.deletedFile(lineCount: 0).rowCount == 0)
    }

    @Test func plain() {
        let doc = DiffDocument.plain(lineCount: 12)
        #expect(rows(doc) == (1...12).map(ctx))
        #expect(doc.foldCount == 0)
        #expect(doc.counterpart(ofRow: 3) == nil)
        #expect(DiffDocument.plain(lineCount: 0).rowCount == 0)
        #expect(DiffDocument.plain(lineCount: -5).rowCount == 0)
    }

    @Test func hugePlainFileIsInstant() {
        let doc = DiffDocument.plain(lineCount: 5_000_000)
        #expect(doc.rowCount == 5_000_000)
        #expect(doc.contentHeight == 100_000_000)
        #expect(MemoryLayout<DiffDocument>.size < 128)
        #expect(doc.row(at: 4_999_999) == DiffRow(kind: .context, line: 4_999_999, number: 5_000_000))
        #expect(doc.row(at: 0) == ctx(1))
        #expect(doc.y(ofRow: 4_999_999) == 99_999_980)
        #expect(doc.rowIndex(atY: 99_999_990) == 4_999_999)
        #expect(doc.rowIndex(atY: 1_000_005) == 50_000)
    }

    @Test func hugeDiffUsesFewRuns() {
        let p = patch(Hunk(oldStart: 2_500_000, oldCount: 1, newStart: 2_500_000, newCount: 1, deletedLines: 0..<1))
        let doc = DiffDocument.diff(patch: p, newLineCount: 5_000_000)
        #expect(doc.rowCount == 3 + 3 + 2 + 2)
        #expect(doc.row(at: 0) == fold(line: 0, count: 2_499_996))
        #expect(doc.row(at: doc.rowCount - 1) == fold(line: 2_500_003, count: 5_000_000 - 2_500_003))
        #expect(doc.contentHeight == 2 * 26 + 8 * 20)
    }
}

@Suite struct DiffDocumentRandomTests {
    private struct Case {
        var hunks: [Hunk]
        var lineCount: Int
    }

    private static func makeCase(_ rng: inout SeededGenerator) -> Case {
        let n = Int.random(in: 0...120, using: &rng)
        var hunks: [Hunk] = []
        var p = 0 // new lines consumed
        var oldPos = 0
        var deleted = 0
        var first = true
        while true {
            let gap = (first ? Int.random(in: 0...8, using: &rng) : Int.random(in: 1...12, using: &rng))
            first = false
            p += gap
            oldPos += gap
            let d = Int.random(in: 0...3, using: &rng)
            let a = Int.random(in: 0...3, using: &rng)
            if d == 0 && a == 0 { continue }
            if p + a > n { break }
            if a > 0 {
                hunks.append(Hunk(oldStart: d == 0 ? oldPos : oldPos + 1, oldCount: d, newStart: p + 1, newCount: a, deletedLines: deleted..<(deleted + d)))
            } else {
                hunks.append(Hunk(oldStart: oldPos + 1, oldCount: d, newStart: p, newCount: 0, deletedLines: deleted..<(deleted + d)))
            }
            deleted += d
            oldPos += d
            p += a
        }
        return Case(hunks: hunks, lineCount: n)
    }

    /// Plain O(N) reference built straight from the spec text.
    private static func reference(_ c: Case, context: Int, minFold: Int) -> [DiffRow] {
        let n = c.lineCount
        var visible = [Bool](repeating: false, count: n)
        var addedBy = [Int](repeating: -1, count: n)
        var before = [[DiffRow]](repeating: [], count: n + 1)
        for (hi, h) in c.hunks.enumerated() {
            let lo1: Int, hi1: Int, at: Int
            if h.newCount > 0 {
                lo1 = h.newStart - context
                hi1 = h.newStart + h.newCount - 1 + context
                at = h.newStart - 1
                for l in h.newStart...(h.newStart + h.newCount - 1) { addedBy[l - 1] = hi }
            } else {
                lo1 = h.newStart - context + 1
                hi1 = h.newStart + context
                at = h.newStart
            }
            if lo1 <= hi1 { for l in max(lo1, 1)...max(min(hi1, n), 0) where l >= 1 && l <= n { visible[l - 1] = true } }
            for k in h.deletedLines { before[at].append(DiffRow(kind: .deleted, line: k, hunk: hi)) }
        }
        // Rows in order; hidden lines are marked with a placeholder and grouped afterwards.
        var stream: [(row: DiffRow, hidden: Bool)] = []
        for i in 0...n {
            for r in before[i] { stream.append((r, false)) }
            guard i < n else { break }
            if addedBy[i] >= 0 {
                stream.append((DiffRow(kind: .added, line: i, number: i + 1, hunk: addedBy[i]), false))
            } else {
                stream.append((DiffRow(kind: .context, line: i, number: i + 1), !visible[i] && !c.hunks.isEmpty))
            }
        }
        var out: [DiffRow] = []
        var i = 0
        while i < stream.count {
            guard stream[i].hidden else { out.append(stream[i].row); i += 1; continue }
            var j = i
            while j < stream.count, stream[j].hidden { j += 1 }
            if j - i >= minFold {
                out.append(DiffRow(kind: .fold, line: stream[i].row.line, count: j - i))
            } else {
                out.append(contentsOf: stream[i..<j].map(\.row))
            }
            i = j
        }
        return out
    }

    @Test(arguments: [(3, 4), (0, 4), (1, 1), (2, 6), (5, 2)])
    func matchesReference(context: Int, minFold: Int) throws {
        var rng = SeededGenerator(seed: UInt64(context * 100 + minFold))
        let metrics = RowMetrics(lineHeight: 18, foldHeight: 30)
        for _ in 0..<300 {
            let c = Self.makeCase(&rng)
            let expected = Self.reference(c, context: context, minFold: minFold)
            let doc = DiffDocument.diff(patch: FilePatch(hunks: c.hunks), newLineCount: c.lineCount, context: context, minFoldLines: minFold, metrics: metrics)
            try #require(doc.rowCount == expected.count, "hunks \(c.hunks) n \(c.lineCount)")
            var y = 0.0
            var folds = 0
            for (i, want) in expected.enumerated() {
                #expect(doc.row(at: i) == want, "row \(i) of hunks \(c.hunks) n \(c.lineCount)")
                #expect(doc.y(ofRow: i) == y)
                let h = want.kind == .fold ? 30.0 : 18.0
                #expect(doc.height(ofRow: i) == h)
                #expect(doc.rowIndex(atY: y) == i)
                #expect(doc.rowIndex(atY: y + h - 0.5) == i)
                if want.kind == .fold { folds += 1 }
                y += h
            }
            #expect(doc.y(ofRow: expected.count) == y)
            #expect(doc.contentHeight == y)
            #expect(doc.foldCount == folds)
            checkCounterparts(doc, hunks: c.hunks)
        }
    }

    private func checkCounterparts(_ doc: DiffDocument, hunks: [Hunk]) {
        for i in 0..<doc.rowCount {
            let r = doc.row(at: i)
            let partner = doc.counterpart(ofRow: i)
            guard r.hunk >= 0 else { #expect(partner == nil); continue }
            let h = hunks[r.hunk]
            let k = r.kind == .deleted ? r.line - h.deletedLines.lowerBound : r.line - (h.newStart - 1)
            if k < min(h.deletedLines.count, h.newCount) {
                #expect(partner != nil)
                if let p = partner {
                    let other = doc.row(at: p)
                    #expect(other.hunk == r.hunk)
                    #expect(other.kind == (r.kind == .deleted ? .added : .deleted))
                    #expect(doc.counterpart(ofRow: p) == i)
                }
            } else {
                #expect(partner == nil)
            }
        }
    }

    @Test func fileMatchesReference() {
        var rng = SeededGenerator(seed: 77)
        for _ in 0..<200 {
            let c = Self.makeCase(&rng)
            let doc = DiffDocument.file(patch: FilePatch(hunks: c.hunks), lineCount: c.lineCount)
            var marks = [LineMark](repeating: .none, count: c.lineCount)
            for h in c.hunks where h.newCount > 0 {
                for l in (h.newStart - 1)..<(h.newStart - 1 + h.newCount) { marks[l] = h.oldCount > 0 ? .modified : .added }
            }
            #expect(doc.rowCount == c.lineCount)
            for i in 0..<c.lineCount {
                #expect(doc.row(at: i) == DiffRow(kind: .context, line: i, number: i + 1, mark: marks[i]))
            }
        }
    }

    @Test func randomStalePatchesNeverCrash() {
        var rng = SeededGenerator(seed: 5)
        for _ in 0..<500 {
            let hunks = (0..<Int.random(in: 0...6, using: &rng)).map { _ -> Hunk in
                Hunk(oldStart: Int.random(in: -3...50, using: &rng), oldCount: Int.random(in: 0...4, using: &rng),
                     newStart: Int.random(in: -3...80, using: &rng), newCount: Int.random(in: 0...6, using: &rng),
                     deletedLines: 0..<Int.random(in: 0...4, using: &rng))
            }
            let n = Int.random(in: 0...40, using: &rng)
            let doc = DiffDocument.diff(patch: FilePatch(hunks: hunks), newLineCount: n, context: Int.random(in: 0...4, using: &rng))
            for i in 0..<doc.rowCount {
                let r = doc.row(at: i)
                if r.kind == .context || r.kind == .added { #expect(r.line >= 0 && r.line < n) }
                if r.kind == .fold { #expect(r.line + r.count <= n) }
                _ = doc.counterpart(ofRow: i)
            }
            _ = DiffDocument.file(patch: FilePatch(hunks: hunks), lineCount: n)
        }
    }
}
