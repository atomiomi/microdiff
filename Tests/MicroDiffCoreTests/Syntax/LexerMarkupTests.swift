import MicroDiffCore
import Testing

@Suite("Lexer: HTML and XML")
struct LexerMarkupTests {
    @Test func elementWithAttributes() {
        #expect(lex("x.html", #"<div class="a" id='b'>text</div>"#) == [
            T("<", .punctuation), T("div", .tag), T("class", .attribute), T("=", .punctuation), T("\"a\"", .string),
            T("id", .attribute), T("=", .punctuation), T("'b'", .string), T(">", .punctuation),
            T("</", .punctuation), T("div", .tag), T(">", .punctuation),
        ])
    }

    @Test func textContentIsPlain() {
        #expect(lex("x.html", "Hello, world! if 42 \"x\"").isEmpty)
        #expect(lex("x.html", "a < b and 5 > 3").isEmpty)
        #expect(lex("x.html", "x<5").isEmpty)
    }

    @Test func selfClosingTag() {
        #expect(lex("x.html", #"<img src="a.png" />"#) == [
            T("<", .punctuation), T("img", .tag), T("src", .attribute), T("=", .punctuation),
            T("\"a.png\"", .string), T("/>", .punctuation),
        ])
        #expect(lex("x.html", "<br/>") == [T("<", .punctuation), T("br", .tag), T("/>", .punctuation)])
    }

    @Test func attributeNamesMayContainDashesAndColons() {
        let tokens = lex("x.html", #"<a data-id="1" xlink:href="u">"#)
        #expect(tokens.contains(T("data-id", .attribute)))
        #expect(tokens.contains(T("xlink:href", .attribute)))
    }

    @Test func unquotedAttributeValueIsAName() {
        #expect(lex("x.html", "<a href=foo>").contains(T("foo", .attribute)))
    }

    @Test func attributeWithoutValue() {
        #expect(lex("x.html", "<input disabled>") == [
            T("<", .punctuation), T("input", .tag), T("disabled", .attribute), T(">", .punctuation),
        ])
    }

    @Test func doctypeAndProcessingInstruction() {
        #expect(lex("x.html", "<!DOCTYPE html>") == [
            T("<", .punctuation), T("!DOCTYPE", .tag), T("html", .attribute), T(">", .punctuation),
        ])
        #expect(lex("x.xml", #"<?xml version="1.0"?>"#) == [
            T("<", .punctuation), T("?xml", .tag), T("version", .attribute), T("=", .punctuation),
            T("\"1.0\"", .string), T("?>", .punctuation),
        ])
    }

    @Test func twoTagsOnOneLine() {
        #expect(lex("x.html", "<b>x</b><i>y</i>").filter { $0.kind == .tag } == [
            T("b", .tag), T("b", .tag), T("i", .tag), T("i", .tag),
        ])
    }

    @Test func attributeValueContainingAngleBracketsStaysAString() {
        #expect(lex("x.html", #"<a title="a > b">"#).contains(T("\"a > b\"", .string)))
    }

    @Test func unterminatedAttributeStringColorsToEndOfLineWithoutCarrying() {
        var lexer = LineLexer(file: "x.html")
        let tokens = lexer.feed(#"<a title="abc"#)
        #expect(tokens.last == T("\"abc", .string))
        #expect(lexer.state != .normal)  // still inside the tag
        #expect(lexer.feed(">") == [T(">", .punctuation)])
        #expect(lexer.state == .normal)
    }

    // MARK: comments

    @Test func commentOnOneLine() {
        #expect(lex("x.html", "<!-- hi --> <p>") == [
            T("<!-- hi -->", .comment), T("<", .punctuation), T("p", .tag), T(">", .punctuation),
        ])
    }

    @Test func commentSpansLines() {
        let lines = lex("x.html", lines: ["<p> <!-- a", "<b>not a tag</b>", "c --> <i>"])
        #expect(lines[0].last == T("<!-- a", .comment))
        #expect(lines[1] == [T("<b>not a tag</b>", .comment)])
        #expect(lines[2] == [T("c -->", .comment), T("<", .punctuation), T("i", .tag), T(">", .punctuation)])
    }

    @Test func emptyLineInsideCommentKeepsItOpen() {
        var lexer = LineLexer(file: "x.html")
        lexer.feed("<!-- a")
        let open = lexer.state
        lexer.feed("")
        #expect(lexer.state == open)
    }

    @Test func commentCloseWithoutOpenIsPlainText() {
        #expect(lex("x.html", "a --> b").isEmpty)
    }

    // MARK: tags split across lines

    @Test func tagSplitAcrossLinesCarriesTheTagState() {
        var lexer = LineLexer(file: "x.html")
        #expect(lexer.feed("<div") == [T("<", .punctuation), T("div", .tag)])
        #expect(lexer.state != .normal)
        #expect(lexer.feed(#"  class="x""#) == [T("class", .attribute), T("=", .punctuation), T("\"x\"", .string)])
        #expect(lexer.state != .normal)
        #expect(lexer.feed("  hidden") == [T("hidden", .attribute)])
        #expect(lexer.feed(">text") == [T(">", .punctuation)])
        #expect(lexer.state == .normal)
        #expect(lexer.feed("more text").isEmpty)
    }

    @Test func selfClosingEndOnItsOwnLine() {
        var lexer = LineLexer(file: "x.html")
        lexer.feed("<br")
        #expect(lexer.feed("/>") == [T("/>", .punctuation)])
        #expect(lexer.state == .normal)
    }

    @Test func emptyLineInsideTagKeepsItOpen() {
        var lexer = LineLexer(file: "x.html")
        lexer.feed("<div")
        let open = lexer.state
        #expect(lexer.feed("").isEmpty)
        #expect(lexer.state == open)
    }

    @Test func tagWithAttributeOnTheNextLineEndsInNormalState() {
        var lexer = LineLexer(file: "x.xml")
        lexer.feed("<a")
        lexer.feed("b='1'>")
        #expect(lexer.state == .normal)
    }

    @Test(arguments: ["x.xml", "x.svg", "x.plist", "x.vue", "x.svelte", "x.htm"])
    func otherMarkupLanguagesUseTheSameColoring(_ file: String) {
        #expect(lex(file, "<a b=\"c\"/>") == [
            T("<", .punctuation), T("a", .tag), T("b", .attribute), T("=", .punctuation),
            T("\"c\"", .string), T("/>", .punctuation),
        ])
    }

    @Test func nonASCIIInNamesAndText() {
        #expect(lex("x.html", "<p título=\"é\">日本語</p>").contains(T("título", .attribute)))
    }
}

@Suite("Lexer: Markdown")
struct LexerMarkdownTests {
    @Test func headings() {
        #expect(lex("x.md", "# Title") == [T("# Title", .tag)])
        #expect(lex("x.md", "###### Small") == [T("###### Small", .tag)])
        #expect(lex("x.md", "  ## Indented") == [T("## Indented", .tag)])
        #expect(lex("x.md", "#") == [T("#", .tag)])
    }

    @Test func notHeadings() {
        #expect(lex("x.md", "####### seven").isEmpty)
        #expect(lex("x.md", "#hashtag").isEmpty)
    }

    @Test func blockQuote() {
        #expect(lex("x.md", "> quoted `x` text") == [T("> quoted `x` text", .comment)])
        #expect(lex("x.md", "  > quoted") == [T("> quoted", .comment)])
    }

    @Test func backtickFenceSpansLines() {
        let lines = lex("x.md", lines: ["```rust", "let x = 1; # not a heading", "> not a quote", "```", "# Heading"])
        #expect(lines[0] == [T("```rust", .string)])
        #expect(lines[1] == [T("let x = 1; # not a heading", .string)])
        #expect(lines[2] == [T("> not a quote", .string)])
        #expect(lines[3] == [T("```", .string)])
        #expect(lines[4] == [T("# Heading", .tag)])
    }

    @Test func tildeFenceSpansLines() {
        let lines = lex("x.md", lines: ["~~~", "- code", "~~~", "- item"])
        #expect(lines[1] == [T("- code", .string)])
        #expect(lines[2] == [T("~~~", .string)])
        #expect(lines[3] == [T("-", .punctuation)])
    }

    @Test func indentedFence() {
        let lines = lex("x.md", lines: ["  ```", "code", "  ```"])
        #expect(lines[0] == [T("  ```", .string)])
        #expect(lines[1] == [T("code", .string)])
        #expect(endState("x.md", lines: ["  ```", "code", "  ```"]) == .normal)
    }

    @Test func fenceStateIsOpenUntilClosed() {
        #expect(endState("x.md", lines: ["```", "a"]) != .normal)
        #expect(endState("x.md", lines: ["```", "a", "```"]) == .normal)
    }

    @Test func onlyTheMatchingBareFenceClosesABlock() {
        // A tilde fence inside a backtick block, and a fence with a language tag, are content.
        let inside = ["```", "~~~", "```js", "still code"]
        #expect(endState("x.md", lines: inside) != .normal)
        #expect(lex("x.md", lines: inside + ["# not a heading"]).last == [T("# not a heading", .string)])
        #expect(endState("x.md", lines: inside + ["```  "]) == .normal)
        #expect(endState("x.md", lines: ["~~~", "```", "~~~~"]) == .normal)
    }

    @Test func emptyLineInsideFenceKeepsItOpen() {
        var lexer = LineLexer(file: "x.md")
        lexer.feed("```")
        lexer.feed("")
        #expect(lexer.state != .normal)
    }

    @Test func inlineCode() {
        #expect(lex("x.md", "use `foo()` here") == [T("`foo()`", .string)])
        #expect(lex("x.md", "a `b` c `d`") == [T("`b`", .string), T("`d`", .string)])
    }

    @Test func unterminatedInlineCodeColorsToEndOfLine() {
        var lexer = LineLexer(file: "x.md")
        #expect(lexer.feed("a `b c") == [T("`b c", .string)])
        #expect(lexer.state == .normal)
    }

    @Test func listMarkers() {
        #expect(lex("x.md", "- item") == [T("-", .punctuation)])
        #expect(lex("x.md", "* item") == [T("*", .punctuation)])
        #expect(lex("x.md", "+ item") == [T("+", .punctuation)])
        #expect(lex("x.md", "  - nested") == [T("-", .punctuation)])
        #expect(lex("x.md", "1. first") == [T("1.", .punctuation)])
        #expect(lex("x.md", "12) twelfth") == [T("12)", .punctuation)])
    }

    @Test func notListMarkers() {
        #expect(lex("x.md", "---").isEmpty)
        #expect(lex("x.md", "-item").isEmpty)
        #expect(lex("x.md", "2024 was a year").isEmpty)
        #expect(lex("x.md", "1.5 is a number").isEmpty)
    }

    @Test func listItemWithInlineCode() {
        #expect(lex("x.md", "- run `make`") == [T("-", .punctuation), T("`make`", .string)])
    }

    @Test func linkUrlIsColored() {
        #expect(lex("x.md", "see [docs](https://example.com/a) now") == [T("docs", .function), T("https://example.com/a", .string)])
        #expect(lex("x.md", "![alt](img.png)") == [T("alt", .function), T("img.png", .string)])
    }

    @Test func unclosedLinkUrlColorsToEndOfLine() {
        #expect(lex("x.md", "[a](b c") == [T("a", .function), T("b c", .string)])
    }

    @Test func bracketWithoutUrlIsPlain() {
        #expect(lex("x.md", "[a] and [b]").isEmpty)
    }

    @Test func plainParagraphAndBlankLine() {
        #expect(lex("x.md", "Just some words, 42 of them.").isEmpty)
        #expect(lex("x.md", "").isEmpty)
        #expect(lex("x.md", "   ").isEmpty)
    }

    @Test func headingStateNeverCarries() {
        #expect(endState("x.md", lines: ["# a", "> b", "- c", "`d"]) == .normal)
    }
}

@Suite("Lexer: files without coloring")
struct LexerPlainTests {
    @Test(arguments: ["notes.txt", "unknown.xyz", "noextension", "debug.log", "a.", ""])
    func noLexerForPlainOrUnknownFiles(_ file: String) {
        #expect(Lexer.forFileName(file) == nil)
    }

    @Test func lexerForPlainFlavorDefinitionNeverColorsAnything() throws {
        let definition = try #require(LanguageRegistry.language(forFileName: "notes.txt"))
        var lexer = LineLexer(Lexer(definition))
        #expect(lexer.feed("let x = \"a\" // b 42").isEmpty)
        #expect(lexer.state == .normal)
        #expect(Lexer(definition).startStates(for: buffer(["a", "b"])) == [])
        #expect(Lexer(definition).tokens(forLine: 0, in: buffer(["a"]), states: []) == [])
    }
}
