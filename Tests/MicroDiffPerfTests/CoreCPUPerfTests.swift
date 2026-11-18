import MicroDiffCore
import Testing

/// Every perf test lives under this suite so `.serialized` covers all of them: parallel tests would distort timings.
@Suite(.serialized, .enabled(if: perfBuildIsOptimized, "budgets only mean something in an optimized build: use scripts/perf.sh"))
struct PerfSuite {}

extension PerfSuite {
    @Suite struct CoreCPU {
        @Test func statusParse() {
            let data = Fixtures.statusData
            #expect(StatusParser.parse(data).changes.count > 9_000) // the input really is 10k records
            let m = measure { blackHole(StatusParser.parse(data)) }
            #expect(report("status-parse-10k", m, budgetMs: 5))
        }

        @Test func changesTree() {
            let snapshot = Fixtures.changesSnapshot
            #expect(ChangesTree(snapshot: snapshot).rows().count > 10_000)
            let m = measure { blackHole(ChangesTree(snapshot: snapshot).rows()) }
            #expect(report("changes-tree-build+rows-10k", m, budgetMs: 15))

            let tree = ChangesTree(snapshot: snapshot)
            let rows = measure { blackHole(tree.rows()) }
            #expect(report("changes-tree-rows-10k", rows, budgetMs: 5))
        }

        @Test func textBufferBuild() {
            let data = Fixtures.bigBuffer
            #expect(TextBuffer(data).lineCount == 200_000 && data.count == 10_000_000)
            let m = measure { blackHole(TextBuffer(data)) }
            #expect(report("textbuffer-build-10mb", m, budgetMs: 15))
        }

        @Test func diffParse() {
            let data = Fixtures.patchData
            #expect(DiffParser.parse(data).hunks.count == 50_000 && data.count > 5_000_000)
            let m = measure { blackHole(DiffParser.parse(data)) }
            #expect(report("diff-parse-5mb-50k-hunks", m, budgetMs: 40))
        }

        @Test func diffDocument() {
            let patch = Generate.filePatch(hunks: 50_000)
            #expect(DiffDocument.diff(patch: patch, newLineCount: 1_000_000).foldCount == 50_000)
            let build = measure { blackHole(DiffDocument.diff(patch: patch, newLineCount: 1_000_000)) }
            #expect(report("diffdocument-build-50k-hunks", build, budgetMs: 15))

            let doc = DiffDocument.diff(patch: patch, newLineCount: 1_000_000)
            let rowCount = doc.rowCount
            let height = doc.contentHeight
            let rowAt = measure {
                var rng = SeededRandom(seed: 7)
                var sum = 0
                for _ in 0..<1_000_000 { sum &+= doc.row(at: Int.random(in: 0..<rowCount, using: &rng)).line }
                blackHole(sum)
            }
            #expect(report("diffdocument-row-at-1m", rowAt, budgetMs: 150))

            let rowAtY = measure {
                var rng = SeededRandom(seed: 8)
                var sum = 0
                for _ in 0..<1_000_000 { sum &+= doc.rowIndex(atY: Double.random(in: 0..<height, using: &rng)) }
                blackHole(sum)
            }
            #expect(report("diffdocument-rowindex-aty-1m", rowAtY, budgetMs: 150))
        }

        @Test func wordDiff() {
            let pairs = Generate.wordDiffPairs
            #expect(WordDiff.changedRanges(old: pairs[0].old, new: pairs[0].new) != nil) // a real diff, not the early exit
            let m = measure {
                var sum = 0
                for i in 0..<1000 {
                    let pair = pairs[i % pairs.count]
                    sum &+= WordDiff.changedRanges(old: pair.old, new: pair.new)?.new.count ?? -1
                }
                blackHole(sum)
            }
            #expect(report("worddiff-80chars-per-call", m, budgetMs: 0.05, perCall: 1000))
        }

        @Test func lexer() throws {
            let lexer = try #require(Lexer.forFileName("main.swift"))
            let buffer = Fixtures.swift100k
            #expect(buffer.lineCount == 100_000 && buffer.byteCount > 3_200_000)
            let states = measure(iterations: 5, warmup: 1) { blackHole(lexer.startStates(for: buffer)) }
            #expect(report("lexer-startstates-100k-lines", states, budgetMs: 120))

            let screen = measure {
                var state = LexState.normal
                var sum = 0
                for line in 0..<60 { sum &+= buffer.withLineBytes(line) { lexer.tokenize($0, state: &state) }.count }
                blackHole(sum)
            }
            #expect(report("lexer-tokenize-60-lines", screen, budgetMs: 0.3))
        }

        @Test func lexerVueSingleFileComponent() throws {
            let lexer = try #require(Lexer.forFileName("App.vue"))
            let buffer = Fixtures.vue50k
            #expect(buffer.lineCount == 50_000)
            let states = lexer.startStates(for: buffer)
            #expect(states.count == 50_000, "script and style bodies carry state")
            let walk = measure(iterations: 5, warmup: 1) { blackHole(lexer.startStates(for: buffer)) }
            #expect(report("lexer-startstates-vue-50k-lines", walk, budgetMs: 60))

            // A screen taken from the middle of the file, started from the stored state.
            let screen = measure {
                var sum = 0
                for line in 25_000..<25_060 {
                    sum &+= lexer.tokens(forLine: line, in: buffer, states: states).count
                }
                blackHole(sum)
            }
            #expect(report("lexer-tokenize-vue-60-lines", screen, budgetMs: 0.3))
        }

        @Test func languageLookup() {
            let names = Generate.fileNames
            let m = measure {
                var sum = 0
                for i in 0..<100_000 { sum &+= LanguageRegistry.language(forFileName: names[i % names.count])?.name.utf8.count ?? 0 }
                blackHole(sum)
            }
            #expect(report("language-lookup-100k", m, budgetMs: 20))
        }

        @Test func tabBarLayout() {
            var rng = SeededRandom(seed: 3)
            let widths = (0..<200).map { _ in Double.random(in: 80...260, using: &rng) }
            let m = measure {
                var sum = 0
                for i in 0..<1000 {
                    sum &+= TabBarLayout.compute(naturalWidths: widths, viewportWidth: 1400, activeIndex: i % 200, scrollX: 0).frames.count
                }
                blackHole(sum)
            }
            #expect(report("tabbar-layout-200-tabs-per-call", m, budgetMs: 0.05, perCall: 1000))
        }

        @Test func svgPath() {
            let path = Generate.folderPath
            let m = measure { var sum = 0
                for _ in 0..<1000 { sum &+= SVGPath.parse(path).count }
                blackHole(sum) }
            #expect(report("svgpath-parse-folder-x1000", m, budgetMs: 10))
        }
    }
}
