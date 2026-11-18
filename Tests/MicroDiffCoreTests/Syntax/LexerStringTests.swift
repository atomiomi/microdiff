import MicroDiffCore
import Testing

@Suite("Lexer: strings and apostrophes")
struct LexerStringTests {
    @Test func escapedQuoteStaysInsideTheString() {
        #expect(lex("x.swift", #"let s = "a\"b" + 1"#) == [
            T("let", .keyword), T("=", .punctuation), T(#""a\"b""#, .string), T("+", .punctuation), T("1", .number),
        ])
    }

    @Test func escapedBackslashBeforeClosingQuote() {
        #expect(lex("x.swift", #""a\\" x"#) == [T(#""a\\""#, .string)])
    }

    @Test func emptyString() {
        #expect(lex("x.swift", #"x = """#) == [T("=", .punctuation), T("\"\"", .string)])
    }

    @Test func noEscapeCharacterInGoRawStringAndShellSingleQuotes() {
        #expect(lex("x.go", #"x := `a\` + 1"#) == [
            T(":=", .punctuation), T(#"`a\`"#, .string), T("+", .punctuation), T("1", .number),
        ])
        #expect(lex("x.sh", #"echo 'a\' b"#) == [T(#"'a\'"#, .string)])
    }

    @Test func stringsKeepTheirContentsUncolored() {
        #expect(lex("x.swift", #"x = "if 42 // not a comment /* nor this""#) == [
            T("=", .punctuation), T(#""if 42 // not a comment /* nor this""#, .string),
        ])
    }

    // MARK: single-line strings never carry over

    @Test(arguments: ["x.swift", "x.py", "x.c", "x.js", "x.go", "x.java", "x.ts"])
    func unterminatedSingleLineStringColorsToEndOfLineAndDoesNotCarry(_ file: String) {
        var lexer = LineLexer(file: file)
        #expect(lexer.feed(#"x = "abc // d"#).last == T(#""abc // d"#, .string))
        #expect(lexer.state == .normal)
    }

    @Test(arguments: ["x.swift", "x.py", "x.c", "x.java", "x.ts"])
    func nextLineAfterUnterminatedStringIsCode(_ file: String) {
        let lines = lex(file, lines: [#"x = "abc"#, "1"])
        #expect(lines[0].last == T(#""abc"#, .string))
        #expect(lines[1] == [T("1", .number)])
    }

    // MARK: multi-line strings

    @Test func pythonTripleQuotedStringSpansLines() {
        let lines = lex("x.py", lines: [#"x = """doc"#, "if 1 # not code", #"end""" + 2"#, "y = 3"])
        #expect(lines[0] == [T("=", .punctuation), T(#""""doc"#, .string)])
        #expect(lines[1] == [T("if 1 # not code", .string)])
        #expect(lines[2] == [T(#"end""""#, .string), T("+", .punctuation), T("2", .number)])
        #expect(lines[3] == [T("=", .punctuation), T("3", .number)])
    }

    @Test func pythonSingleQuoteTripleStringSpansLines() {
        let lines = lex("x.py", lines: ["x = '''a", "b'''"])
        #expect(lines[1] == [T("b'''", .string)])
    }

    @Test func tripleQuoteOpenerBeatsSingleQuote() {
        #expect(lex("x.py", #"x = """a" b""""#) == [T("=", .punctuation), T(#""""a" b""""#, .string)])
        #expect(endState("x.py", lines: [#"x = """a" b""""#]) == .normal)
        #expect(endState("x.py", lines: [#"x = """a" b"#]) != .normal)
    }

    @Test func swiftMultilineStringSpansLines() {
        let lines = lex("x.swift", lines: [#"let s = """"#, "    let x = 1", #"    """ + y"#, "let z = 2"])
        #expect(lines[0].last == T(#"""""#, .string))
        #expect(lines[1] == [T("    let x = 1", .string)])
        #expect(lines[2] == [T(#"    """"#, .string), T("+", .punctuation)])
        #expect(lines[3] == [T("let", .keyword), T("=", .punctuation), T("2", .number)])
    }

    @Test func javascriptTemplateLiteralSpansLines() {
        let lines = lex("x.js", lines: ["const s = `a", "  // b ${x}", "c` + 1;"])
        #expect(lines[0].last == T("`a", .string))
        #expect(lines[1] == [T("  // b ${x}", .string)])
        #expect(lines[2] == [T("c`", .string), T("+", .punctuation), T("1", .number), T(";", .punctuation)])
    }

    @Test func goRawStringSpansLines() {
        let lines = lex("x.go", lines: ["s := `a", "b \"c\"", "d` + x"])
        #expect(lines[1] == [T(#"b "c""#, .string)])
        #expect(lines[2] == [T("d`", .string), T("+", .punctuation)])
    }

    @Test func rustStringIsMultiline() {
        let lines = lex("x.rs", lines: [#"let s = "a"#, #"b";"#])
        #expect(lines[1] == [T(#"b""#, .string), T(";", .punctuation)])
    }

    @Test func escapeAtEndOfLineKeepsMultilineStringOpen() {
        var lexer = LineLexer(file: "x.js")
        lexer.feed("x = `abc\\")
        #expect(lexer.state != .normal)
        #expect(lexer.feed("def` + 1").first == T("def`", .string))
    }

    // MARK: apostrophes

    @Test func rustCharLiterals() {
        #expect(lex("x.rs", "let c = 'a';") == [
            T("let", .keyword), T("=", .punctuation), T("'a'", .string), T(";", .punctuation),
        ])
        #expect(lex("x.rs", #"let c = '\n';"#) == [
            T("let", .keyword), T("=", .punctuation), T(#"'\n'"#, .string), T(";", .punctuation),
        ])
        #expect(lex("x.rs", #"let q = '\'';"#).contains(T(#"'\''"#, .string)))
        #expect(lex("x.rs", "let e = 'é';").contains(T("'é'", .string)))
        #expect(lex("x.rs", "let e = '😀';").contains(T("'😀'", .string)))
    }

    @Test func rustLifetimesAreKeywordsAndSwallowNothing() {
        #expect(lex("x.rs", "fn f<'a>(x: &'a str) -> &'a str {") == [
            T("fn", .keyword), T("<", .punctuation), T("'a", .keyword), T(">(", .punctuation),
            T(":", .punctuation), T("&", .punctuation), T("'a", .keyword), T("str", .type), T(")", .punctuation),
            T("->", .punctuation), T("&", .punctuation), T("'a", .keyword), T("str", .type), T("{", .punctuation),
        ])
    }

    @Test func rustStaticLifetime() {
        #expect(lex("x.rs", "x: &'static str") == [
            T(":", .punctuation), T("&", .punctuation), T("'static", .keyword), T("str", .type),
        ])
    }

    @Test func rustTwoLifetimesInOneList() {
        #expect(lex("x.rs", "struct S<'a, 'b>").filter { $0.kind == .keyword } == [
            T("struct", .keyword), T("'a", .keyword), T("'b", .keyword),
        ])
    }

    @Test(arguments: ["x.c", "x.py", "x.swift", "x.js", "x.go", "x.rs", "x.java"])
    func loneApostropheThatNeverClosesIsPunctuationNotAString(_ file: String) {
        let tokens = lex(file, "x = ' + y")
        #expect(!tokens.contains { $0.kind == .string }, "tokens: \(tokens)")
        // The apostrophe is punctuation and coloring continues as code after it.
        #expect(tokens.first == T("=", .punctuation))
        #expect(tokens.dropFirst().first?.kind == .punctuation)
        #expect(tokens.dropFirst().first?.text == "'")
    }

    @Test func apostropheDoesNotCarryToNextLine() {
        let lines = lex("x.py", lines: ["x = ' a", "y = 1"])
        #expect(lines[1] == [T("=", .punctuation), T("1", .number)])
    }

    @Test func closedApostropheStringStillWorksWhereApostropheIsAQuote() {
        #expect(lex("x.py", "x = 'a b' + 1") == [
            T("=", .punctuation), T("'a b'", .string), T("+", .punctuation), T("1", .number),
        ])
        #expect(lex("x.c", #"c = '\'';"#).contains(T(#"'\''"#, .string)))
    }

    @Test func englishApostropheInACommentIsPartOfTheComment() {
        #expect(lex("x.c", "int x; // don't panic") == [
            T("int", .type), T(";", .punctuation), T("// don't panic", .comment),
        ])
    }
}
