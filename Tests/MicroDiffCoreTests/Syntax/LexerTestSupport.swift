import MicroDiffCore

/// One colored span as text plus kind, so expectations read like `[T("let", .keyword)]`.
struct T: Equatable, CustomStringConvertible {
    var text: String
    var kind: TokenKind

    init(_ text: String, _ kind: TokenKind) {
        self.text = text
        self.kind = kind
    }

    var description: String { "(\(text), \(kind))" }
}

/// Lexes lines of one file type one after the other, carrying the state like the real views do.
struct LineLexer {
    let lexer: Lexer
    var state = LexState.normal

    init(_ lexer: Lexer) {
        self.lexer = lexer
    }

    /// The shared lexer for a file name. Fails the test (by trapping) only when the language is missing,
    /// which the registry tests rule out.
    init(file: String) {
        guard let lexer = Lexer.forFileName(file) else { fatalError("no lexer for \(file)") }
        self.lexer = lexer
    }

    /// Tokens of the next line without `.variable` tokens: most tests are about the other kinds and read better
    /// without every plain identifier in the list. Use `feedAll` when variables matter.
    @discardableResult
    mutating func feed(_ line: String) -> [T] {
        slices(of: line, tokens: allRawTokens(line))
    }

    /// Tokens of the next line, variables included.
    @discardableResult
    mutating func feedAll(_ line: String) -> [T] {
        slices(of: line, tokens: allRawTokens(line), keepVariables: true)
    }

    /// Tokens as most tests see them: without `.variable`, operators counted as punctuation (adjacent ones merged).
    /// Most tests are about the other kinds; `lexAll` shows everything.
    mutating func rawTokens(_ line: String) -> [SyntaxToken] {
        simplified(allRawTokens(line))
    }

    mutating func allRawTokens(_ line: String) -> [SyntaxToken] {
        var copy = line
        return copy.withUTF8 { lexer.tokenize($0, state: &state) }
    }

    /// Tokens of every line, state carried.
    mutating func feed(lines: [String]) -> [[T]] {
        lines.map { feed($0) }
    }
}

/// The text each token covers, cut out of `line` by UTF-16 offsets.
/// Unless `keepVariables`, tokens are simplified: see `simplified`.
func slices(of line: String, tokens: [SyntaxToken], keepVariables: Bool = false) -> [T] {
    let units = Array(line.utf16)
    return (keepVariables ? tokens : simplified(tokens)).map { token in
        guard token.start >= 0, token.length >= 0, token.start + token.length <= units.count else {
            return T("<out of range \(token.start)+\(token.length) of \(units.count)>", token.kind)
        }
        return T(String(decoding: units[token.start..<token.start + token.length], as: UTF16.self), token.kind)
    }
}

/// Tokens of a single line lexed from a fresh state.
func lex(_ file: String, _ line: String) -> [T] {
    var lexer = LineLexer(file: file)
    return lexer.feed(line)
}

/// Like `lex` but keeps `.variable` tokens.
func lexAll(_ file: String, _ line: String) -> [T] {
    var lexer = LineLexer(file: file)
    return lexer.feedAll(line)
}

/// Like `lex(_:lines:)` but keeps `.variable` tokens.
func lexAll(_ file: String, lines: [String]) -> [[T]] {
    var lexer = LineLexer(file: file)
    return lines.map { lexer.feedAll($0) }
}

/// Tokens of several lines of one file, state carried from line to line.
func lex(_ file: String, lines: [String]) -> [[T]] {
    var lexer = LineLexer(file: file)
    return lexer.feed(lines: lines)
}

/// The state after lexing `lines` in order.
func endState(_ file: String, lines: [String]) -> LexState {
    var lexer = LineLexer(file: file)
    for line in lines { lexer.feed(line) }
    return lexer.state
}

/// The state at the start of every line of `lines` (`states[0]` is `.normal`).
func lineStartStates(_ file: String, lines: [String]) -> [LexState] {
    var lexer = LineLexer(file: file)
    return lines.map { line in
        let before = lexer.state
        lexer.feed(line)
        return before
    }
}

func buffer(_ lines: [String]) -> TextBuffer {
    TextBuffer(Data(lines.map { $0 + "\n" }.joined().utf8))
}

/// Drops `.variable` tokens and counts operators as punctuation, merging adjacent punctuation like the lexer did before.
func simplified(_ tokens: [SyntaxToken]) -> [SyntaxToken] {
    var result: [SyntaxToken] = []
    for var token in tokens where token.kind != .variable {
        if token.kind == .operator { token.kind = .punctuation }
        if token.kind == .punctuation, let last = result.last, last.kind == .punctuation, last.start + last.length == token.start {
            result[result.count - 1].length += token.length
        } else {
            result.append(token)
        }
    }
    return result
}
