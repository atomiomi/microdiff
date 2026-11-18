import MicroDiffCore
import Testing

@Suite("Lexer: state, startStates and shared instances")
struct LexerStateTests {
    /// Multi-line samples that exercise state in every flavor.
    static let samples: [(file: String, lines: [String])] = [
        ("x.swift", ["let a = 1 /* open /* nested", "still", "*/ more */ let b = \"\"\"", "inside", "\"\"\"", "let c = 3"]),
        ("x.rs", ["/* a /* b", "*/ c", "*/ fn f<'a>() {", "let s = \"multi", "line\";", "}"]),
        ("x.py", ["x = \"\"\"doc", "more # not a comment", "end\"\"\"", "y = 'a", "z = 1"]),
        ("x.js", ["const s = `a", "${b}`; /* c", "d */ let e = 1;"]),
        ("x.c", ["int a; /* b", "c */ int d; // e", "int f;"]),
        ("x.go", ["s := `raw", "more` + 1", "/* c", "*/"]),
        ("x.html", ["<div", "  class=\"x\"", ">text<!-- c", "d -->", "<p>"]),
        ("x.md", ["# T", "```rust", "let x = 1;", "```", "- item `c`", "~~~", "x"]),
        ("x.css", ["a { color: red; } /* c", "d */ b { }"]),
        ("x.json", ["{", "  \"a\": [1, true],", "  \"b\": \"c\"", "}"]),
        ("x.yml", ["a: 1", "b: \"open", "- c"]),
        ("x.sh", ["echo \"a", "b\"; # c", "echo 'd", "e'"]),
    ]

    @Test(arguments: samples.indices)
    func advanceLeavesTheSameStateAsTokenizeOnEveryLine(_ index: Int) {
        let (file, lines) = Self.samples[index]
        let lexer = LineLexer(file: file).lexer
        var viaTokenize = LexState.normal
        var viaAdvance = LexState.normal
        for (number, line) in lines.enumerated() {
            var copy = line
            _ = copy.withUTF8 { lexer.tokenize($0, state: &viaTokenize) }
            copy.withUTF8 { lexer.advance($0, state: &viaAdvance) }
            #expect(viaTokenize == viaAdvance, "\(file) line \(number)")
        }
    }

    // MARK: startStates

    @Test func noStateCarriedGivesAnEmptyArray() {
        let lexer = LineLexer(file: "x.swift").lexer
        #expect(lexer.startStates(for: buffer(["let a = 1", "// c", "let b = \"x\""])) == [])
    }

    @Test func emptyBufferGivesAnEmptyArray() {
        #expect(LineLexer(file: "x.swift").lexer.startStates(for: .empty) == [])
    }

    @Test func oneStatePerLineAndFirstIsNormal() {
        let lexer = LineLexer(file: "x.swift").lexer
        let states = lexer.startStates(for: buffer(["/* a", "b", "c */", "let"]))
        #expect(states.count == 4)
        #expect(states[0] == .normal)
        #expect(states[1] != .normal)
        #expect(states[2] != .normal)
        #expect(states[3] == .normal)
    }

    @Test func startStatesMatchCarryingStateLineByLine() {
        for (file, lines) in Self.samples {
            let lexer = LineLexer(file: file).lexer
            let expected = lineStartStates(file, lines: lines)
            let actual = lexer.startStates(for: buffer(lines))
            if expected.allSatisfy({ $0 == .normal }) {
                #expect(actual == [], "\(file)")
            } else {
                #expect(actual == expected, "\(file)")
            }
        }
    }

    @Test func lastLineWithoutTerminatorCountsToo() {
        let lexer = LineLexer(file: "x.c").lexer
        let states = lexer.startStates(for: TextBuffer(Data("/* a\nb".utf8)))
        #expect(states.count == 2)
        #expect(states[1] != .normal)
    }

    @Test func crlfLinesAreLexedWithoutTheCarriageReturn() {
        let lexer = LineLexer(file: "x.c").lexer
        let text = TextBuffer(Data("/* a\r\nb */ int\r\nint x;\r\n".utf8))
        let states = lexer.startStates(for: text)
        #expect(states.count == 3)
        #expect(states[2] == .normal)
        #expect(slices(of: text.line(1), tokens: lexer.tokens(forLine: 1, in: text, states: states)) == [
            T("b */", .comment), T("int", .type),
        ])
    }

    @Test func plainFlavorHasNoStates() throws {
        let definition = try #require(LanguageRegistry.language(forFileName: "a.txt"))
        #expect(Lexer(definition).startStates(for: buffer(["a", "b"])) == [])
    }

    // MARK: resetAt

    private let openComment = ["/* open", "inside", "let x = 1", "*/ let y = 2"]

    @Test func lineAfterAnOpenCommentIsCommentWithoutReset() {
        let lexer = LineLexer(file: "x.swift").lexer
        let text = buffer(openComment)
        let states = lexer.startStates(for: text)
        #expect(slices(of: text.line(2), tokens: lexer.tokens(forLine: 2, in: text, states: states)) == [T("let x = 1", .comment)])
    }

    @Test func resetLineIsLexedAsCodeAgain() {
        let lexer = LineLexer(file: "x.swift").lexer
        let text = buffer(openComment)
        let states = lexer.startStates(for: text, resets: [(line: 2, state: .normal)])
        #expect(states[2] == .normal)
        #expect(slices(of: text.line(2), tokens: lexer.tokens(forLine: 2, in: text, states: states)) == [
            T("let", .keyword), T("=", .punctuation), T("1", .number),
        ])
        // The state before the reset is untouched.
        #expect(states[1] != .normal)
    }

    @Test func resetRestartsTheStateButTheCommentOpensAgainIfTheLineOpensOne() {
        let lexer = LineLexer(file: "x.swift").lexer
        let text = buffer(["/* a", "/* b", "c", "d"])
        let states = lexer.startStates(for: text, resets: [(line: 1, state: .normal)])
        #expect(states[1] == .normal)
        // Line 1 opens a fresh comment at depth 1; line 2 starts inside it.
        #expect(states[2] != .normal)
        #expect(states[2] != states[1])
    }

    @Test func resettingEveryOpenLineLeavesNoCarriedState() {
        let lexer = LineLexer(file: "x.swift").lexer
        #expect(lexer.startStates(for: buffer(openComment), resets: [(line: 1, state: .normal), (line: 2, state: .normal), (line: 3, state: .normal)]) == [])
    }

    @Test func resetAtZeroDuplicatesAndOutOfRangeAreHarmless() {
        let lexer = LineLexer(file: "x.swift").lexer
        let text = buffer(openComment)
        let plain = lexer.startStates(for: text)
        #expect(lexer.startStates(for: text, resets: [(line: 0, state: .normal), (line: 0, state: .normal), (line: 99, state: .normal), (line: 100, state: .normal)]) == plain)
    }

    @Test func severalResetsEachRestartTheState() {
        let lexer = LineLexer(file: "x.c").lexer
        let text = buffer(["/* a", "b", "/* c", "d", "e"])
        let states = lexer.startStates(for: text, resets: [(line: 2, state: .normal), (line: 4, state: .normal)])
        #expect(states[2] == .normal)
        #expect(states[3] != .normal)
        #expect(states[4] == .normal)
    }

    // MARK: tokens(forLine:in:states:)

    @Test func tokensForLineMatchTokenizingLineByLine() {
        for (file, lines) in Self.samples {
            let lexer = LineLexer(file: file).lexer
            let text = buffer(lines)
            let states = lexer.startStates(for: text)
            var reference = LineLexer(lexer)
            for (number, line) in lines.enumerated() {
                let expected = reference.feed(line)
                let actual = slices(of: line, tokens: lexer.tokens(forLine: number, in: text, states: states))
                #expect(actual == expected, "\(file) line \(number)")
            }
        }
    }

    @Test func tokensForLineOutOfRangeIsEmpty() {
        let lexer = LineLexer(file: "x.swift").lexer
        let text = buffer(["let a = 1"])
        #expect(lexer.tokens(forLine: -1, in: text, states: []).isEmpty)
        #expect(lexer.tokens(forLine: 1, in: text, states: []).isEmpty)
        #expect(lexer.tokens(forLine: 0, in: .empty, states: []).isEmpty)
    }

    @Test func shortStatesArrayMeansNormalForTheRest() {
        let lexer = LineLexer(file: "x.swift").lexer
        let text = buffer(["let a", "let b"])
        #expect(lexer.tokens(forLine: 1, in: text, states: [.normal]).filter { $0.kind != .variable }.count == 1)
    }

    @Test func tokensForLineStartFromTheGivenState() {
        let lexer = LineLexer(file: "x.c").lexer
        let text = buffer(["/* a", "b */ int"])
        let states = lexer.startStates(for: text)
        #expect(slices(of: "b */ int", tokens: lexer.tokens(forLine: 1, in: text, states: states)) == [
            T("b */", .comment), T("int", .type),
        ])
        #expect(slices(of: "b */ int", tokens: lexer.tokens(forLine: 1, in: text, states: [])) == [
            T("*/", .punctuation), T("int", .type),
        ])
    }

    // MARK: shared lexers

    private func shared(_ fileName: String) throws -> Lexer {
        try #require(Lexer.forFileName(fileName))
    }

    @Test func sameLanguageSharesOneInstance() throws {
        let a = try shared("a.rs")
        let b = try shared("deep.name.RS")
        #expect(a === b)
        let c = try shared("a.c")
        let h = try shared("b.h")
        #expect(c === h)
        let env = try shared(".env")
        let ini = try shared("x.ini")
        #expect(env === ini)
    }

    @Test func differentLanguagesGetDifferentInstances() throws {
        let rust = try shared("a.rs")
        let c = try shared("a.c")
        #expect(rust !== c)
        #expect(c.definition.name == "C")
    }

    @Test func manyThreadsGetTheSameInstance() async throws {
        let names = ["race.zig", "race.kt", "race.dart", "race.lua", "race.scala"]
        for name in names {
            let lexers = await withTaskGroup(of: Lexer?.self) { group in
                for _ in 0..<64 { group.addTask { Lexer.forFileName(name) } }
                var result: [Lexer?] = []
                for await lexer in group { result.append(lexer) }
                return result
            }
            let first = try #require(lexers.first ?? nil)
            #expect(lexers.count == 64)
            #expect(lexers.allSatisfy { $0 === first }, "\(name)")
        }
    }
}
