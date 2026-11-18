import MicroDiffCore
import Testing

/// Token offsets are UTF-16 code units, whatever the UTF-8 byte layout of the line is.
@Suite("Lexer: UTF-16 offsets")
struct LexerUnicodeTests {
    @Test func accentedLettersBeforeAndInsideTokens() {
        let line = #"let café = "naïve" // über"#
        var lexer = LineLexer(file: "x.swift")
        let raw = lexer.rawTokens(line)
        #expect(slices(of: line, tokens: raw) == [
            T("let", .keyword), T("=", .punctuation), T(#""naïve""#, .string), T("// über", .comment),
        ])
        // "let café " is 9 units although it is 10 bytes.
        #expect(raw[1].start == 9)
    }

    @Test func cjkBeforeAndInsideTokens() {
        let line = #"日本語 = "文字列" + 1 // コメント"#
        #expect(lex("x.swift", line) == [
            T("=", .punctuation), T(#""文字列""#, .string), T("+", .punctuation), T("1", .number), T("// コメント", .comment),
        ])
    }

    @Test func emojiAreSurrogatePairsAndCountTwoUnits() {
        let line = #"let 😀 = "😀😀" // 🎉"#
        var lexer = LineLexer(file: "x.swift")
        let raw = lexer.rawTokens(line)
        #expect(slices(of: line, tokens: raw) == [
            T("let", .keyword), T("=", .punctuation), T(#""😀😀""#, .string), T("// 🎉", .comment),
        ])
        #expect(raw[1].start == 7)
        #expect(raw[2].length == 6)
    }

    @Test func combiningMarksAndZeroWidthJoiners() {
        let line = "x = \"e\u{301} 👨‍👩‍👧\" + 7 # ok"
        #expect(lex("x.py", line) == [
            T("=", .punctuation), T("\"e\u{301} 👨‍👩‍👧\"", .string), T("+", .punctuation), T("7", .number),
            T("# ok", .comment),
        ])
    }

    @Test func numbersAndFunctionsAfterEmoji() {
        #expect(lex("x.js", "😀😀 = foo(😀, 0xFF)") == [
            T("=", .punctuation), T("foo", .function), T("(", .punctuation), T(",", .punctuation),
            T("0xFF", .number), T(")", .punctuation),
        ])
    }

    @Test func rustCharLiteralsWithMultiByteCharacters() {
        #expect(lex("x.rs", "let a = 'é'; let b = '日'; let c = '😀'; // 🎉").filter { $0.kind == .string } == [
            T("'é'", .string), T("'日'", .string), T("'😀'", .string),
        ])
    }

    @Test func rustLifetimeAfterEmoji() {
        #expect(lex("x.rs", "/* 😀 */ fn f<'a>() {}").contains(T("'a", .keyword)))
    }

    @Test func markupWithAccentsAndEmoji() {
        let line = "<p título=\"é😀\">日本語</p> <!-- 🎉 -->"
        #expect(lex("x.html", line) == [
            T("<", .punctuation), T("p", .tag), T("título", .attribute), T("=", .punctuation), T("\"é😀\"", .string),
            T(">", .punctuation), T("</", .punctuation), T("p", .tag), T(">", .punctuation), T("<!-- 🎉 -->", .comment),
        ])
    }

    @Test func jsonWithNonASCIIKeysAndValues() {
        #expect(lexAll("x.json", #""clé 😀": "été", "n": 5"#) == [
            T(#""clé 😀""#, .variable), T(":", .punctuation), T(#""été""#, .string), T(",", .punctuation),
            T(#""n""#, .variable), T(":", .punctuation), T("5", .number),
        ])
    }

    @Test func keyValueWithNonASCIIKeys() {
        #expect(lexAll("x.yml", "clé: été # 🎉") == [T("clé", .variable), T(":", .punctuation), T("été", .string), T("# 🎉", .comment)])
        #expect(lexAll("x.toml", "日本 = \"😀\"") == [T("日本", .variable), T("=", .punctuation), T("\"😀\"", .string)])
    }

    @Test func markdownWithEmoji() {
        #expect(lex("x.md", "- 😀 use `é` and [日本](http://x/é)") == [
            T("-", .punctuation), T("`é`", .string), T("日本", .function), T("http://x/é", .string),
        ])
        #expect(lex("x.md", "# 😀 Title") == [T("# 😀 Title", .tag)])
    }

    @Test func continuedBlockCommentCoversTheWholeLineInUTF16Units() {
        let lines = ["/* 😀", "日本語 é", "end */ x"]
        var lexer = LineLexer(file: "x.c")
        for line in lines {
            let raw = lexer.rawTokens(line)
            #expect(raw.first?.start == 0)
            if line != lines.last { #expect(raw == [SyntaxToken(start: 0, length: line.utf16.count, kind: .comment)]) }
        }
    }

    @Test func fencedLineWithEmojiCoversTheWholeLine() {
        var lexer = LineLexer(file: "x.md")
        lexer.feed("```")
        let line = "let s = \"😀\""
        #expect(lexer.rawTokens(line) == [SyntaxToken(start: 0, length: line.utf16.count, kind: .string)])
    }

    @Test(arguments: ["x.swift", "x.py", "x.rs", "x.go", "x.js", "x.c", "x.sh", "x.html", "x.json", "x.css", "x.yml", "x.md", "x.sql"])
    func everyTokenOfARichLineSlicesCleanly(_ file: String) {
        let line = "𝔘𝔫𝔦 \"é😀\" 'ñ' // 日本語 /* ü */ <a b=\"é\"> `🎉` #fff 42 é: ü=1 [x](y😀) 😀"
        var lexer = LineLexer(file: file)
        for token in lexer.rawTokens(line) {
            #expect(token.start >= 0 && token.length > 0 && token.start + token.length <= line.utf16.count, "\(file): \(token)")
        }
    }

    // MARK: invalid UTF-8

    @Test(arguments: [
        [0xFF], [0x80], [0xC3], [0xE2, 0x82], [0xF0, 0x9F], [0xF0, 0x9F, 0x98], [0xF0, 0x41], [0xED, 0xA0, 0x80], [0xC0, 0x80],
        [0xF4, 0x90, 0x80, 0x80], [0xF8, 0x88, 0x80, 0x80, 0x80],
    ] as [[UInt8]])
    func offsetsAfterInvalidBytesMatchTheRepairedString(_ invalid: [UInt8]) {
        // The UI shows `String(decoding:)`, which turns each invalid piece into one U+FFFD.
        let bytes = [UInt8(ascii: "x")] + invalid + Array(" // end".utf8)
        let lexer = LineLexer(file: "x.swift").lexer
        var state = LexState.normal
        let tokens = bytes.withUnsafeBufferPointer { lexer.tokenize($0, state: &state) }
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(slices(of: text, tokens: tokens) == [T("// end", .comment)])
        #expect(tokens.last.map { $0.start + $0.length } == text.utf16.count)
    }

    @Test func stringAfterInvalidBytesSlicesExactly() {
        let bytes: [UInt8] = [0xFF, 0xF0, 0x9F, UInt8(ascii: " "), UInt8(ascii: "\"")] + Array("ab\" + 1".utf8)
        let lexer = LineLexer(file: "x.swift").lexer
        var state = LexState.normal
        let tokens = bytes.withUnsafeBufferPointer { lexer.tokenize($0, state: &state) }
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(slices(of: text, tokens: tokens) == [T("\"ab\"", .string), T("+", .punctuation), T("1", .number)])
    }
}
