import MicroDiffCore
import Testing

/// Random and pathological input through every language. The lexer is approximate, but it must never
/// crash and never report a span that does not exist in the line.
@Suite("Lexer: invariants under fuzzing")
struct LexerFuzzTests {
    static let languageNames = LanguageRegistry.all.map(\.name)

    static func definition(_ name: String) -> LanguageDefinition {
        LanguageRegistry.all.first { $0.name == name }!
    }

    /// Building blocks for random lines: delimiters of the language plus generic noise.
    static func pieces(for definition: LanguageDefinition) -> [[UInt8]] {
        var pieces: [[UInt8]] = []
        for comment in definition.lineComments { pieces.append(Array(comment.utf8)) }
        for block in definition.blockComments {
            pieces.append(Array(block.open.utf8))
            pieces.append(Array(block.close.utf8))
        }
        for string in definition.strings {
            pieces.append(Array(string.open.utf8))
            pieces.append(Array(string.close.utf8))
            if let escape = string.escape { pieces.append(Array(String(escape).utf8)) }
        }
        for word in definition.keywords.sorted().prefix(6) + definition.types.sorted().prefix(3) + definition.constants.sorted().prefix(3) {
            pieces.append(Array(word.utf8))
        }
        for text in [
            "\"", "'", "`", "\\", "(", ")", "[", "]", "{", "}", "<", ">", "/", "*", "-", "=", "!", "?", ":", ";", ",", ".", "#", "@", "$",
            "<!--", "-->", "</", "/>", "```", "~~~", "[[", "]]", "---", "...", "0x", "1e", "e-", "42", "3.14", ".5", "0..1",
            "a", "Z", "_", "foo", "Foo", "foo(", "x1", "é", "日本語", "😀", "\u{301}", " ", " ", " ", "\t",
        ] {
            pieces.append(Array(text.utf8))
        }
        // Deliberately invalid UTF-8: stray continuation, truncated sequences, overlong, surrogates, 0xFF.
        let invalid: [[UInt8]] = [
            [0xFF], [0x80], [0xBF], [0xC3], [0xC0, 0x80], [0xE2, 0x82], [0xF0, 0x9F], [0xF0, 0x9F, 0x98], [0xED, 0xA0, 0x80],
            [0xF8, 0x88, 0x80, 0x80, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE0, 0x80, 0x80], [0xF0],
        ]
        pieces.append(contentsOf: invalid)
        return pieces
    }

    static func randomLine(_ pieces: [[UInt8]], _ rng: inout SeededGenerator) -> [UInt8] {
        let count = Int.random(in: 0...14, using: &rng)
        var line: [UInt8] = []
        for _ in 0..<count { line.append(contentsOf: pieces[Int.random(in: 0..<pieces.count, using: &rng)]) }
        return line
    }

    /// Describes the first broken invariant, or nil.
    static func violation(_ tokens: [SyntaxToken], in bytes: [UInt8]) -> String? {
        let limit = String(decoding: bytes, as: UTF8.self).utf16.count
        var previousEnd = 0
        for token in tokens {
            if token.start < 0 { return "negative start in \(token)" }
            if token.length <= 0 { return "empty token \(token)" }
            if token.kind == .plain { return "plain token \(token)" }
            if token.start < previousEnd { return "overlapping or unsorted token \(token), previous ended at \(previousEnd)" }
            if token.start + token.length > limit { return "token \(token) beyond UTF-16 length \(limit)" }
            previousEnd = token.start + token.length
        }
        return nil
    }

    static func run(_ lexer: Lexer, _ bytes: [UInt8], state: inout LexState) -> [SyntaxToken] {
        bytes.withUnsafeBufferPointer { lexer.tokenize($0, state: &state) }
    }

    @Test(arguments: languageNames)
    func randomLinesKeepTheTokenInvariantsAndStateAgreesWithAdvance(_ name: String) {
        let definition = Self.definition(name)
        let lexer = Lexer(definition)
        let pieces = Self.pieces(for: definition)
        var rng = SeededGenerator(seed: UInt64(truncatingIfNeeded: name.hashValueStable) ^ 0xC0FFEE)
        var state = LexState.normal
        var advanced = LexState.normal
        for lineNumber in 0..<3000 {
            let bytes = Self.randomLine(pieces, &rng)
            let tokens = Self.run(lexer, bytes, state: &state)
            bytes.withUnsafeBufferPointer { lexer.advance($0, state: &advanced) }
            if let problem = Self.violation(tokens, in: bytes) {
                Issue.record("\(name) line \(lineNumber): \(problem); bytes \(bytes)")
                return
            }
            if state != advanced {
                Issue.record("\(name) line \(lineNumber): advance ended in a different state than tokenize; bytes \(bytes)")
                return
            }
        }
    }

    @Test(arguments: languageNames)
    func everyLineAlsoWorksFromAFreshStateAndFromAnyCarriedState(_ name: String) {
        let definition = Self.definition(name)
        let lexer = Lexer(definition)
        let pieces = Self.pieces(for: definition)
        var rng = SeededGenerator(seed: 99)
        // Collect states that really occur, then start lines from each of them.
        var states: Set<LexState> = [.normal]
        var carried = LexState.normal
        for _ in 0..<400 {
            _ = Self.run(lexer, Self.randomLine(pieces, &rng), state: &carried)
            states.insert(carried)
        }
        for state in states {
            for _ in 0..<150 {
                let bytes = Self.randomLine(pieces, &rng)
                var copy = state
                let tokens = Self.run(lexer, bytes, state: &copy)
                if let problem = Self.violation(tokens, in: bytes) {
                    Issue.record("\(name) from state \(state.raw): \(problem); bytes \(bytes)")
                    return
                }
            }
        }
    }

    @Test(arguments: languageNames)
    func arbitraryStateValuesNeverCrash(_ name: String) {
        let definition = Self.definition(name)
        let lexer = Lexer(definition)
        let pieces = Self.pieces(for: definition)
        var rng = SeededGenerator(seed: 5)
        for _ in 0..<300 {
            let bytes = Self.randomLine(pieces, &rng)
            var state = LexState(raw: UInt32(truncatingIfNeeded: rng.next()))
            let tokens = Self.run(lexer, bytes, state: &state)
            if let problem = Self.violation(tokens, in: bytes) {
                Issue.record("\(name) from raw state: \(problem); bytes \(bytes)")
                return
            }
        }
    }

    @Test(arguments: languageNames)
    func emptyLineIsFine(_ name: String) {
        let lexer = Lexer(Self.definition(name))
        var state = LexState.normal
        #expect(Self.run(lexer, [], state: &state).isEmpty)
        var advanced = LexState.normal
        [UInt8]().withUnsafeBufferPointer { lexer.advance($0, state: &advanced) }
        #expect(advanced == state)
    }

    @Test(arguments: languageNames)
    func hugeLinesAreFine(_ name: String) {
        let definition = Self.definition(name)
        let lexer = Lexer(definition)
        let pieces = Self.pieces(for: definition)
        var rng = SeededGenerator(seed: 7)
        var mixed: [UInt8] = []
        while mixed.count < 100_000 { mixed.append(contentsOf: pieces[Int.random(in: 0..<pieces.count, using: &rng)]) }

        var lines: [[UInt8]] = [mixed, [UInt8](repeating: UInt8(ascii: "a"), count: 100_000)]
        for text in ["\"", "'", "`", "/*", "*/", "<", "<!--", "[", "(", "\\", "#", "1", ".", "é", "😀", "-"] {
            lines.append(Array(String(repeating: text, count: 100_000 / text.utf8.count).utf8))
        }
        for bytes in lines {
            var state = LexState.normal
            let tokens = Self.run(lexer, bytes, state: &state)
            if let problem = Self.violation(tokens, in: bytes) {
                Issue.record("\(name) huge line starting \(bytes.prefix(6)): \(problem)")
                return
            }
        }
    }
}

extension String {
    /// A hash that is the same in every run (unlike `hashValue`), so fuzz seeds stay reproducible.
    fileprivate var hashValueStable: UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return hash
    }
}
