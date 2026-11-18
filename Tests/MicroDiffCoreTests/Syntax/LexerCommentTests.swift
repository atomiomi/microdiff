import MicroDiffCore
import Testing

@Suite("Lexer: comments")
struct LexerCommentTests {
    @Test(arguments: [("x.swift", "//"), ("x.c", "//"), ("x.py", "#"), ("x.sql", "--"), ("x.rb", "#"), ("x.lua", "--")])
    func lineCommentColorsToEndOfLine(_ file: String, _ marker: String) {
        let comment = "\(marker) note \"quoted\" /* x */"
        #expect(lex(file, "x \(comment)").last == T(comment, .comment))
        #expect(lex(file, comment) == [T(comment, .comment)])
    }

    @Test func lineCommentDoesNotCarryToNextLine() {
        var lexer = LineLexer(file: "x.swift")
        lexer.feed("// a")
        #expect(lexer.state == .normal)
        #expect(lexer.feed("let") == [T("let", .keyword)])
    }

    // MARK: block comments

    @Test func blockCommentOnOneLine() {
        #expect(lex("x.c", "int /* a */ x;") == [T("int", .type), T("/* a */", .comment), T(";", .punctuation)])
    }

    @Test func blockCommentSpansLinesAndCodeResumesAfterIt() {
        let lines = lex("x.c", lines: ["int a; /* start", "still // inside", "end */ int b;"])
        #expect(lines[0] == [T("int", .type), T(";", .punctuation), T("/* start", .comment)])
        #expect(lines[1] == [T("still // inside", .comment)])
        #expect(lines[2] == [T("end */", .comment), T("int", .type), T(";", .punctuation)])
    }

    @Test func emptyLineInsideBlockCommentKeepsItOpen() {
        var lexer = LineLexer(file: "x.c")
        lexer.feed("/* a")
        let open = lexer.state
        #expect(lexer.feed("").isEmpty)
        #expect(lexer.state == open)
        #expect(lexer.feed("*/").count == 1)
        #expect(lexer.state == .normal)
    }

    @Test func blockCommentsNotNestedInC() {
        #expect(lex("x.c", "/* a /* b */ int x;") == [
            T("/* a /* b */", .comment), T("int", .type), T(";", .punctuation),
        ])
        #expect(endState("x.c", lines: ["/* a /* b */"]) == .normal)
    }

    @Test(arguments: ["x.swift", "x.rs"])
    func nestedBlockCommentsOnOneLine(_ file: String) {
        #expect(lex(file, "/* a /* b */ c */ let") == [T("/* a /* b */ c */", .comment), T("let", .keyword)])
    }

    @Test(arguments: ["x.swift", "x.rs"])
    func nestedBlockCommentDepthIsCarriedAcrossLines(_ file: String) {
        let lines = lex(file, lines: ["/* a /* b", "*/ still comment", "*/ let x", "let"])
        #expect(lines[0] == [T("/* a /* b", .comment)])
        #expect(lines[1] == [T("*/ still comment", .comment)])
        #expect(lines[2] == [T("*/", .comment), T("let", .keyword)])
        #expect(lines[3] == [T("let", .keyword)])
    }

    @Test func nestedDepthIsPartOfTheState() {
        let one = endState("x.swift", lines: ["/* a"])
        let two = endState("x.swift", lines: ["/* a /* b"])
        #expect(one != .normal)
        #expect(two != .normal)
        #expect(one != two)
    }

    @Test func unmatchedCloseOutsideCommentIsPunctuation() {
        #expect(lex("x.c", "a */ b") == [T("*/", .punctuation)])
    }

    @Test func htmlStyleCommentInCodeLanguageIsNotAComment() {
        #expect(lex("x.c", "a <!-- b").contains { $0.kind == .comment } == false)
    }

    @Test func rubyBeginEndBlock() {
        let lines = lex("x.rb", lines: ["=begin", "text", "=end", "x = 1"])
        #expect(lines[0] == [T("=begin", .comment)])
        #expect(lines[1] == [T("text", .comment)])
        #expect(lines[2] == [T("=end", .comment)])
        #expect(lines[3] == [T("=", .punctuation), T("1", .number)])
    }

    @Test func luaLongBracketCommentSpansLines() {
        let lines = lex("x.lua", lines: ["--[[ a", "b ]] local", "-- c"])
        #expect(lines[0] == [T("--[[ a", .comment)])
        #expect(lines[1] == [T("b ]]", .comment), T("local", .keyword)])
        #expect(lines[2] == [T("-- c", .comment)])
    }

    // MARK: "#" comments

    @Test(arguments: [" ", "\t", ";", ")", "}", ","])
    func hashStartsACommentAfterTheseCharacters(_ before: String) {
        let tokens = lex("x.sh", "x\(before)# note")
        #expect(tokens.last == T("# note", .comment))
    }

    @Test func hashAtLineStartIsAComment() {
        #expect(lex("x.sh", "# note") == [T("# note", .comment)])
        #expect(lex("x.py", "    # note") == [T("# note", .comment)])
        #expect(lex("x.py", "#!/usr/bin/env python") == [T("#!/usr/bin/env python", .comment)])
    }

    @Test(arguments: ["echo $#", "echo ${#x}", "echo ${#arr[@]}", "x=a#b", "url#fragment"])
    func shellHashInsideWordsIsNotAComment(_ line: String) {
        #expect(!lex("x.sh", line).contains { $0.kind == .comment }, "line: \(line)")
    }

    @Test func hashAfterNumberOrIdentifierIsNotAComment() {
        #expect(!lex("x.py", "x = 1#y").contains { $0.kind == .comment })
    }

    @Test func hashInsideStringIsNotAComment() {
        #expect(lex("x.py", #"s = "a # b" # real"#) == [
            T("=", .punctuation), T(#""a # b""#, .string), T("# real", .comment),
        ])
    }

    // MARK: "//" after a colon

    @Test(arguments: ["x.swift", "x.c", "x.js", "x.java"])
    func doubleSlashRightAfterColonIsNotAComment(_ file: String) {
        let tokens = lex(file, "see http://example.com/a")
        #expect(!tokens.contains { $0.kind == .comment }, "tokens: \(tokens)")
        #expect(tokens == [T("://", .punctuation), T(".", .punctuation), T("/", .punctuation)])
    }

    @Test func doubleSlashAfterSpaceOrNothingIsAComment() {
        #expect(lex("x.js", "a: // note").last == T("// note", .comment))
        #expect(lex("x.js", "a;// note").last == T("// note", .comment))
    }
}
