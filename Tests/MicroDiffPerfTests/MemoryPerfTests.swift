import MicroDiffCore
import Testing

extension PerfSuite {
    /// Needs the allocator setting that `scripts/perf.sh` passes in its second pass (see there for why).
    @Suite(.enabled(if: memoryPassIsConfigured, "memory numbers are only exact with MallocLargeCache=0: use scripts/perf.sh"))
    struct Memory {
        @Test func textBuffer() {
            let source = Fixtures.bigBuffer
            // 10 MB of bytes plus the line index (about 1.5 MB reserved).
            let growth = footprintGrowth { TextBuffer(Fixtures.freshCopy(source)) }
            #expect(reportMemory("mem-textbuffer-10mb", growthBytes: growth, budgetMB: 11.5))
        }

        /// The same buffer the real way, read from disk. Foundation sizes the read buffer generously.
        @Test func textBufferFromFile() {
            let path = Fixtures.bigFile
            let growth = footprintGrowth { try? TextBuffer(contentsOfFile: path) }
            #expect(reportMemory("mem-textbuffer-file-10mb", growthBytes: growth, budgetMB: 11.5))
        }

        @Test func plainDocument() {
            let growth = footprintGrowth { DiffDocument.plain(lineCount: 5_000_000) }
            #expect(reportMemory("mem-diffdocument-plain-5m-lines", growthBytes: growth, budgetMB: 0.1))
        }

        @Test func changesTree() {
            let snapshot = Fixtures.changesSnapshot
            let growth = footprintGrowth {
                let tree = ChangesTree(snapshot: snapshot)
                return (tree, tree.rows())
            }
            #expect(reportMemory("mem-changestree-10k", growthBytes: growth, budgetMB: 12))
        }

        @Test func lexerStates() throws {
            let lexer = try #require(Lexer.forFileName("main.swift"))
            let buffer = Fixtures.swift100k
            let growth = footprintGrowth { lexer.startStates(for: buffer) }
            #expect(reportMemory("mem-lexer-startstates-100k-lines", growthBytes: growth, budgetMB: 1))
        }
    }
}
