import MicroDiffCore
import Testing

private func has(_ tokens: [T], _ text: String, _ kind: TokenKind) -> Bool {
    tokens.contains(T(text, kind))
}

private func texts(_ tokens: [T], _ kind: TokenKind) -> [String] {
    tokens.filter { $0.kind == kind }.map(\.text)
}

/// Tokens of every line colored from the stored per-line start states (what the diff view does).
private func tokensFromStartStates(_ file: String, _ lines: [String]) -> [[T]] {
    let lexer = LineLexer(file: file).lexer
    let text = buffer(lines)
    let states = lexer.startStates(for: text)
    return lines.indices.map { slices(of: text.line($0), tokens: lexer.tokens(forLine: $0, in: text, states: states)) }
}

private let vueFile = [
    "<template>",
    "  <div v-if=\"ok\" :title=\"t\" @click=\"go\">",
    "    {{ count + 1 }}",
    "  </div>",
    "</template>",
    "",
    "<script setup lang=\"ts\">",
    "import { ref } from 'vue'",
    "const count = ref<number>(0) // counter",
    "/* multi",
    "   line */ let x = \"s\"",
    "function go(): void {}",
    "</script>",
    "",
    "<style scoped lang=\"scss\">",
    "$c: red;",
    ".a { color: $c; // note",
    "}",
    "</style>",
    "<p class=\"after\">",
]

@Suite("Lexer: markup tags and attributes")
struct LexerMarkupKindTests {
    @Test func tagNamesAreTagsAndAttributesAreAttributes() {
        let tokens = lex("x.html", #"<div class="a" hidden>x</div>"#)
        #expect(texts(tokens, .tag) == ["div", "div"])
        #expect(texts(tokens, .attribute) == ["class", "hidden"])
        #expect(!tokens.contains { $0.kind == .keyword || $0.kind == .type })
    }
}

@Suite("Lexer: Vue single-file components")
struct LexerVueTests {
    static let file = "App.vue"

    @Test func templateTagsAndAttributes() {
        let line = lex(Self.file, lines: vueFile)[1]
        #expect(texts(line, .tag) == ["div"])
        #expect(texts(line, .attribute) == ["v-if", ":title", "@click"])
        #expect(texts(line, .string) == ["\"ok\"", "\"t\"", "\"go\""])
    }

    @Test func mustacheIsJavaScript() {
        #expect(lex(Self.file, "<p>{{ count + 1 }}</p>") == [
            T("<", .punctuation), T("p", .tag), T(">{{", .punctuation),
            T("+", .punctuation), T("1", .number), T("}}</", .punctuation),
            T("p", .tag), T(">", .punctuation),
        ])
        #expect(lex(Self.file, "{{ ok ? 'a' : \"b\" }}") == [
            T("{{", .punctuation), T("?", .punctuation), T("'a'", .string), T(":", .punctuation),
            T("\"b\"", .string), T("}}", .punctuation),
        ])
        #expect(has(lex(Self.file, "{{ items.map(f) }}"), "map", .function))
    }

    @Test func mustacheOnlyInVue() {
        #expect(lex("a.html", "<p>{{ 1 }}</p>").filter { $0.kind == .number }.isEmpty)
        #expect(lex("a.svelte", "<p>{{ 1 }}</p>").filter { $0.kind == .number }.isEmpty)
    }

    @Test func unclosedMustacheColorsToEndOfLine() {
        let tokens = lex(Self.file, "<p>{{ a + 1")
        #expect(has(tokens, "1", .number))
        #expect(tokens.last == T("1", .number))
    }

    @Test func scriptSetupBodyIsTypeScript() {
        let lines = lex(Self.file, lines: vueFile)
        #expect(lines[6] == [
            T("<", .punctuation), T("script", .tag), T("setup", .attribute), T("lang", .attribute), T("=", .punctuation),
            T("\"ts\"", .string), T(">", .punctuation),
        ])
        #expect(has(lines[7], "import", .keyword) && has(lines[7], "'vue'", .string))
        #expect(has(lines[8], "const", .keyword) && has(lines[8], "number", .type))
        #expect(has(lines[8], "ref", .function), "generic call: \(lines[8])")
        #expect(has(lines[8], "0", .number) && has(lines[8], "// counter", .comment))
        #expect(lines[9] == [T("/* multi", .comment)])
        #expect(lines[10] == [
            T("   line */", .comment), T("let", .keyword), T("=", .punctuation), T("\"s\"", .string),
        ])
        #expect(has(lines[11], "function", .keyword) && has(lines[11], "void", .type))
    }

    @Test func tsOnlyWordsAreColoredBecauseLangIsTs() {
        var ts = LineLexer(file: Self.file)
        ts.feed("<script lang=\"ts\">")
        var js = LineLexer(file: Self.file)
        js.feed("<script>")
        #expect(has(ts.feed("abstract A {}"), "abstract", .keyword))
        #expect(!has(js.feed("abstract A {}"), "abstract", .keyword))
    }

    @Test func styleScopedScssBody() {
        let lines = lex(Self.file, lines: vueFile)
        #expect(lines[14] == [
            T("<", .punctuation), T("style", .tag), T("scoped", .attribute), T("lang", .attribute), T("=", .punctuation),
            T("\"scss\"", .string), T(">", .punctuation),
        ])
        #expect(!lines[15].isEmpty)
        #expect(has(lines[16], "// note", .comment), "// is a comment in SCSS: \(lines[16])")
    }

    @Test func plainStyleIsCssWhereSlashSlashIsNotAComment() {
        var lexer = LineLexer(file: Self.file)
        lexer.feed("<style>")
        #expect(lexer.feed("a { color: red; /* c */ }").contains(T("/* c */", .comment)))
        #expect(!lexer.feed("a { x: 1 } // not a comment in css").contains { $0.kind == .comment })
        var scss = LineLexer(file: Self.file)
        scss.feed("<style lang=\"scss\">")
        #expect(scss.feed("a { x: 1 } // comment").last == T("// comment", .comment))
        var less = LineLexer(file: Self.file)
        less.feed("<style lang='less'>")
        #expect(less.feed("a { x: 1 } // comment").last == T("// comment", .comment))
    }

    @Test func plainScriptIsJavaScript() {
        var lexer = LineLexer(file: Self.file)
        lexer.feed("<script>")
        let tokens = lexer.feed("const a = 'x' // c")
        #expect(has(tokens, "const", .keyword) && has(tokens, "'x'", .string) && has(tokens, "// c", .comment))
        #expect(lexer.state != .normal)
    }

    @Test func colorsReturnToMarkupAfterClosingTags() {
        let lines = lex(Self.file, lines: vueFile)
        #expect(lines[12] == [T("</", .punctuation), T("script", .tag), T(">", .punctuation)])
        #expect(lines[18] == [T("</", .punctuation), T("style", .tag), T(">", .punctuation)])
        #expect(lines[19] == [
            T("<", .punctuation), T("p", .tag), T("class", .attribute), T("=", .punctuation),
            T("\"after\"", .string), T(">", .punctuation),
        ])
        #expect(endState(Self.file, lines: vueFile) == .normal)
        #expect(endState(Self.file, lines: Array(vueFile.dropLast()) + ["<p"]) != .normal, "an unfinished tag after </style> is markup state")
    }

    @Test func closingTagOnTheSameLineAsCode() {
        var lexer = LineLexer(file: Self.file)
        lexer.feed("<script>")
        #expect(lexer.feed("let a = 1</script><p>") == [
            T("let", .keyword), T("=", .punctuation), T("1", .number),
            T("</", .punctuation), T("script", .tag), T("><", .punctuation),
            T("p", .tag), T(">", .punctuation),
        ])
        #expect(lexer.state == .normal)
        #expect(lexer.feed("let b = 2").isEmpty, "back in markup, text is plain")

        lexer.feed("<style>")
        let css = lexer.feed("a { color: red }</style> text <b>")
        #expect(Array(css.suffix(5)) == [
            T("style", .tag), T(">", .punctuation), T("<", .punctuation), T("b", .tag), T(">", .punctuation),
        ])
    }

    @Test func openAndCloseOnOneLine() {
        let tokens = lex(Self.file, "<script>let a = 1</script>")
        #expect(texts(tokens, .keyword) == ["let"])
        #expect(texts(tokens, .tag) == ["script", "script"])
        #expect(lex(Self.file, "<script>let a = 1</script>").last == T(">", .punctuation))
        #expect(endState(Self.file, lines: ["<script>let a = 1</script>"]) == .normal)
    }

    @Test func closingTagIsCaseInsensitive() {
        var lexer = LineLexer(file: Self.file)
        lexer.feed("<SCRIPT>")
        #expect(has(lexer.feed("let a"), "let", .keyword))
        lexer.feed("</SCRIPT>")
        #expect(lexer.state == .normal)
    }

    @Test func scriptTagSplitAcrossLines() {
        var lexer = LineLexer(file: Self.file)
        lexer.feed("<script")
        lexer.feed("  setup")
        lexer.feed("  lang=\"ts\"")
        lexer.feed(">")
        #expect(has(lexer.feed("let a: string"), "string", .type))
    }

    @Test func unknownLangKeepsTheDefaultLanguage() {
        var lexer = LineLexer(file: Self.file)
        lexer.feed("<script lang=\"coffee\">")
        #expect(has(lexer.feed("const a = 1"), "const", .keyword))
        var style = LineLexer(file: Self.file)
        style.feed("<style lang=\"stylus\">")
        #expect(style.feed("a { x: 1 } /* c */").contains(T("/* c */", .comment)))
    }

    @Test func langOfTheOtherFamilyIsIgnored() {
        var style = LineLexer(file: Self.file)
        style.feed("<style lang=\"ts\">")
        #expect(!has(style.feed("const a = 1"), "const", .keyword))
    }

    @Test func srcScriptWithoutBodyStillClosesCleanly() {
        let lines = lex(Self.file, lines: ["<script src=\"a.js\"></script>", "text"])
        #expect(lines[1].isEmpty)
        #expect(endState(Self.file, lines: ["<script src=\"a.js\"></script>"]) == .normal)
    }

    @Test func selfClosingScriptDoesNotOpenARegion() {
        #expect(endState(Self.file, lines: ["<script src=\"a.js\" />"]) == .normal)
    }

    @Test func templateIsNotARegion() {
        #expect(lex(Self.file, lines: ["<template>", "let a = 1"])[1].isEmpty)
    }

    // MARK: start states

    @Test func startStatesGiveTheSameTokensAsLexingFromTheTop() {
        #expect(tokensFromStartStates(Self.file, vueFile) == lex(Self.file, lines: vueFile))
    }

    @Test func startStatesMatchCarryingStateLineByLine() {
        let expected = lineStartStates(Self.file, lines: vueFile)
        #expect(LineLexer(file: Self.file).lexer.startStates(for: buffer(vueFile)) == expected)
    }

    @Test func startingInTheMiddleOfAScriptBlock() {
        let lexer = LineLexer(file: Self.file).lexer
        let text = buffer(vueFile)
        let states = lexer.startStates(for: text)
        let top = lex(Self.file, lines: vueFile)
        // Lines 7 to 11 are the TypeScript body, including the multi-line comment.
        for line in 7...11 {
            #expect(states[line] != .normal, "line \(line)")
            #expect(slices(of: text.line(line), tokens: lexer.tokens(forLine: line, in: text, states: states)) == top[line], "line \(line)")
        }
        // Line 10 starts inside the block comment that is inside the script.
        #expect(top[10].first == T("   line */", .comment))
        // Same inside the style block.
        for line in 15...17 {
            #expect(slices(of: text.line(line), tokens: lexer.tokens(forLine: line, in: text, states: states)) == top[line], "line \(line)")
        }
    }

    @Test func advanceAndTokenizeAgreeOnVueStates() {
        let lexer = LineLexer(file: Self.file).lexer
        var a = LexState.normal
        var b = LexState.normal
        for line in vueFile {
            var copy = line
            _ = copy.withUTF8 { lexer.tokenize($0, state: &a) }
            copy.withUTF8 { lexer.advance($0, state: &b) }
            #expect(a == b, "\(line)")
        }
    }

    @Test func resetInsideAScriptBlockStartsAgainAsMarkup() {
        let lexer = LineLexer(file: Self.file).lexer
        let states = lexer.startStates(for: buffer(vueFile), resets: [(line: 8, state: .normal)])
        #expect(states[8] == .normal)
    }

    @Test func startStatesWithAMultiLineTemplateLiteralInsideScript() {
        let lines = ["<script>", "const s = `a", "b ${c}`", "</script>", "<p>"]
        #expect(tokensFromStartStates(Self.file, lines) == lex(Self.file, lines: lines))
        #expect(lex(Self.file, lines: lines)[2].first == T("b ${c}`", .string))
        #expect(lex(Self.file, lines: lines)[3] == [T("</", .punctuation), T("script", .tag), T(">", .punctuation)])
    }

    @Test func openTemplateLiteralDoesNotSwallowTheClosingTag() {
        var lexer = LineLexer(file: Self.file)
        lexer.feed("<script>")
        #expect(has(lexer.feed("const s = `a</script>"), "script", .tag))
        #expect(lexer.state == .normal)
    }
}

@Suite("Lexer: HTML and Svelte embed script and style too")
struct LexerEmbeddingInHtmlAndSvelteTests {
    @Test(arguments: ["a.html", "a.htm", "a.svelte"])
    func scriptAndStyleBodies(_ file: String) {
        let lines = [
            "<script lang=\"ts\">", "  let n: number = 1", "</script>", "<style lang=\"scss\">", "  a { b: c } // s", "</style>", "<b>",
        ]
        let out = lex(file, lines: lines)
        #expect(has(out[1], "let", .keyword) && has(out[1], "number", .type))
        #expect(has(out[4], "// s", .comment))
        #expect(out[2] == [T("</", .punctuation), T("script", .tag), T(">", .punctuation)])
        #expect(out[6] == [T("<", .punctuation), T("b", .tag), T(">", .punctuation)])
        #expect(tokensFromStartStates(file, lines) == out)
    }

    @Test(arguments: ["a.html", "a.svelte"])
    func plainScriptAndStyle(_ file: String) {
        var lexer = LineLexer(file: file)
        lexer.feed("<script>")
        #expect(has(lexer.feed("return 1"), "return", .keyword))
        lexer.feed("</script>")
        lexer.feed("<style>")
        #expect(lexer.feed("a { color: red } // not a comment").contains { $0.kind == .comment } == false)
        lexer.feed("</style>")
        #expect(lexer.state == .normal)
    }

    @Test(arguments: ["a.html", "a.svelte"])
    func closingTagOnTheSameLineAsCode(_ file: String) {
        var lexer = LineLexer(file: file)
        lexer.feed("<script>")
        #expect(lexer.feed("let a = 1</script>") == [
            T("let", .keyword), T("=", .punctuation), T("1", .number),
            T("</", .punctuation), T("script", .tag), T(">", .punctuation),
        ])
        #expect(lexer.state == .normal)
    }

    @Test func xmlDoesNotEmbedAnything() {
        var lexer = LineLexer(file: "a.xml")
        lexer.feed("<script>")
        #expect(lexer.feed("let a = 1").isEmpty)
    }
}

@Suite("Lexer: JavaScript regular expressions")
struct LexerRegexTests {
    @Test(arguments: ["a.js", "a.ts", "a.jsx", "a.tsx"])
    func regexAfterOperatorsAndKeywords(_ file: String) {
        #expect(has(lex(file, "const r = /ab+c/gi;"), "/ab+c/gi", .string))
        #expect(has(lex(file, "f(/x/)"), "/x/", .string))
        #expect(has(lex(file, "f(a, /x/g)"), "/x/g", .string))
        #expect(has(lex(file, "return /x/.test(s)"), "/x/", .string))
        #expect(has(lex(file, "typeof /x/"), "/x/", .string))
        #expect(lex(file, "/^a+$/.test(s)").first == T("/^a+$/", .string))
        #expect(has(lex(file, "x = a || /y/"), "/y/", .string))
        #expect(has(lex(file, "!/y/.test(a)"), "/y/", .string))
    }

    @Test func flagsAreIncluded() {
        #expect(lex("a.js", "/a/gimsuyd") == [T("/a/gimsuyd", .string)])
        #expect(lex("a.js", "x = /a/g.test(s)").contains(T("/a/g", .string)))
        #expect(lex("a.js", "x = /a/").last == T("/a/", .string))
    }

    @Test func slashInsideACharacterClass() {
        #expect(has(lex("a.js", "x = /[/]/g"), "/[/]/g", .string))
        #expect(has(lex("a.js", "x = /a[/\\]/]b/"), "/a[/\\]/]b/", .string))
    }

    @Test func escapedSlash() {
        #expect(has(lex("a.js", "x = /a\\/b/i"), "/a\\/b/i", .string))
        #expect(has(lex("a.ts", "x = /\\//"), "/\\//", .string))
    }

    @Test func regexContentIsNotLexedAsCode() {
        let tokens = lex("a.js", "x = /if \"(\" 12/")
        #expect(tokens == [T("=", .punctuation), T("/if \"(\" 12/", .string)])
    }

    @Test(arguments: ["a.js", "a.ts"])
    func divisionIsNotARegex(_ file: String) {
        for line in ["a / b", "x) / 2", "arr[0] / 2", "a / b / c", "a/b/c", "n++ / 2", "1 / 2 / 3", "a /b/ c", "x = (a+b)/2/3"] {
            let tokens = lex(file, line)
            #expect(!tokens.contains { $0.kind == .string }, "\(line): \(tokens)")
        }
    }

    @Test func divisionAfterStringStaysDivision() {
        let tokens = lex("a.js", "'a' / 2 / 3")
        #expect(tokens.filter { $0.kind == .string }.map(\.text) == ["'a'"])
    }

    @Test func divisionAfterNumberAndIdentifier() {
        #expect(lex("a.js", "2 / x / 3").contains { $0.kind == .string } == false)
    }

    @Test func commentsStillWinOverRegex() {
        #expect(lex("a.js", "x = 1 // a / b / c").last == T("// a / b / c", .comment))
        #expect(lex("a.js", "x = /* c */ 1").contains(T("/* c */", .comment)))
        #expect(lex("a.js", "// /x/").first == T("// /x/", .comment))
    }

    @Test func unterminatedRegexIsNotColored() {
        let tokens = lex("a.js", "x = /abc")
        #expect(!tokens.contains { $0.kind == .string })
    }

    @Test func slashSpaceAfterOperatorIsNotARegex() {
        #expect(!lex("a.js", "x = / y /").contains { $0.kind == .string })
    }

    @Test func otherLanguagesDoNotGetRegexLiterals() {
        for file in ["a.swift", "a.c", "a.java", "a.go", "a.rs"] {
            #expect(!lex(file, "x = /ab+c/g").contains { $0.kind == .string }, "\(file)")
        }
    }

    @Test func urlOutsideAStringIsNotARegex() {
        #expect(!lex("a.js", "see http://example.com/a").contains { $0.kind == .string })
    }
}

@Suite("Lexer: JSX and TSX")
struct LexerJSXTests {
    @Test(arguments: ["a.jsx", "a.tsx", "a.js", "a.ts"])
    func lowercaseTagIsATag(_ file: String) {
        #expect(lex(file, "const e = <div className=\"x\">hi</div>;") == [
            T("const", .keyword), T("=", .punctuation),
            T("<", .punctuation), T("div", .tag), T("className", .attribute),
            T("=", .punctuation), T("\"x\"", .string), T(">", .punctuation),
            T("</", .punctuation), T("div", .tag), T(">;", .punctuation),
        ], "\(file)")
    }

    @Test func attributeNamesInJsxOpeningTags() {
        let tokens = lexAll("a.jsx", "x = <a href=\"u\" onClick={f}>")
        #expect(texts(tokens, .attribute) == ["href", "onClick"])
        #expect(texts(tokens, .tag) == ["a"])
        // Inside `{}` it is code again, and after the tag closes too.
        #expect(texts(tokens, .variable) == ["x", "f"])
        let after = lexAll("a.tsx", "<div id={a} className=\"x\">text {value}</div>")
        #expect(texts(after, .attribute) == ["id", "className"])
        #expect(texts(after, .variable) == ["a", "text", "value"])
        let selfClosing = lexAll("a.jsx", "<Foo bar={b} baz />; x")
        #expect(texts(selfClosing, .attribute) == ["bar", "baz"])
        #expect(texts(selfClosing, .variable) == ["b", "x"])
        // Keywords used as attribute names, and arrows inside braces.
        let keyword = lexAll("a.jsx", "<label for=\"a\" onClick={() => go()} class=\"c\">")
        #expect(texts(keyword, .attribute) == ["for", "onClick", "class"])
        // Closing tags and comparisons do not start attribute mode.
        #expect(texts(lexAll("a.jsx", "</div> a b"), .attribute).isEmpty)
        #expect(texts(lexAll("a.js", "if (a < b) c"), .attribute).isEmpty)
    }

    @Test func componentNameIsAType() {
        let tokens = lex("a.tsx", "return <Component a=\"1\" />")
        #expect(has(tokens, "Component", .type))
        #expect(texts(tokens, .tag).isEmpty)
        #expect(tokens.last == T("/>", .punctuation))
    }

    @Test func selfClosingLowercaseAndMemberTags() {
        #expect(has(lex("a.jsx", "x = <br />"), "br", .tag))
        #expect(has(lex("a.jsx", "x = <motion.div>"), "motion.div", .tag))
        #expect(has(lex("a.jsx", "x = <Foo.Bar>"), "Foo.Bar", .type))
        #expect(has(lex("a.jsx", "x = <my-element>"), "my-element", .tag))
    }

    @Test func closingTags() {
        #expect(lex("a.jsx", "</div>") == [T("</", .punctuation), T("div", .tag), T(">", .punctuation)])
        #expect(lex("a.jsx", "</Component>") == [T("</", .punctuation), T("Component", .type), T(">", .punctuation)])
        // A closing tag counts as one even after a value (text before it in the JSX body).
        #expect(has(lex("a.jsx", "hello</b>"), "b", .tag))
    }

    @Test func fragmentsAreOnlyPunctuation() {
        #expect(lex("a.jsx", "return <>") == [T("return", .keyword), T("<>", .punctuation)])
        #expect(lex("a.jsx", "</>") == [T("</>", .punctuation)])
    }

    @Test func tagAtLineStartOfAMultilineJsx() {
        #expect(has(lex("a.tsx", "  <ul className=\"l\">"), "ul", .tag))
        #expect(has(lex("a.tsx", "(<li key={i}>"), "li", .tag))
        #expect(has(lex("a.tsx", "cond ? <b/> : <i/>"), "b", .tag))
    }

    @Test(arguments: ["a.js", "a.ts", "a.tsx"])
    func comparisonsStayComparisons(_ file: String) {
        for line in ["a < b", "a<b", "if (a < b) {}", "1 < 2", "x.y < z", "f(a) < b", "arr[0] < b", "i < n; i++", "a <b"] {
            let tokens = lex(file, line)
            #expect(!tokens.contains { $0.kind == .tag } && !has(tokens, "b", .type), "\(line): \(tokens)")
        }
    }

    @Test(arguments: ["a.ts", "a.tsx"])
    func genericsAfterANameAreNotTags(_ file: String) {
        for line in ["a<b>(c)", "foo<T>(x)", "const m: Map<string, number> = new Map<string, number>()", "class A extends B<C> {}", "let x: Array<string>"] {
            let tokens = lex(file, line)
            #expect(!tokens.contains { $0.kind == .tag }, "\(line): \(tokens)")
        }
        #expect(!has(lex(file, "a<b>(c)"), "b", .type))
    }

    /// Ambiguous on purpose: after `=`, `(`, `return` and friends a `<name` is read as a JSX tag even in `.ts`,
    /// so a type assertion `<string>x` or an arrow generic `<T>(x) => x` is colored like JSX.
    @Test func typeAssertionAndArrowGenericAreReadAsTags() {
        #expect(has(lex("a.ts", "const y = <string>value"), "string", .tag))
        #expect(has(lex("a.ts", "const f = <T>(x: T) => x"), "T", .type))
    }

    @Test func nonJsLanguagesNeverGetTags() {
        for file in ["a.swift", "a.java", "a.rs", "a.cs", "a.dart"] {
            #expect(!lex(file, "x = <div>").contains { $0.kind == .tag }, "\(file)")
        }
    }

    @Test func tagsInsideBlockCommentsAndStringsStayThere() {
        #expect(lex("a.jsx", "/* <div> */").map(\.kind) == [.comment])
        #expect(lex("a.jsx", "x = \"<div>\"").last == T("\"<div>\"", .string))
    }
}

@Suite("Lexer: Pug")
struct LexerPugTests {
    @Test func definition() throws {
        let def = try #require(LanguageRegistry.language(forFileName: "a.pug"))
        #expect(def.flavor == .code)
        #expect(def.lineComments == ["//"])
        #expect(def.keywords.contains("mixin") && def.keywords.contains("each") && def.keywords.contains("include"))
    }

    @Test func tagNameAtLineStartIsPlain() {
        #expect(lex("a.pug", "div").isEmpty)
        #expect(lex("a.pug", "  p Hello world").isEmpty)
    }

    @Test func idShorthandIsAKeywordAndClassDotIsPunctuation() {
        #expect(lex("a.pug", "#main") == [T("#main", .keyword)])
        #expect(lex("a.pug", "div#main.box") == [T("#main", .keyword), T(".", .punctuation)])
        #expect(lex("a.pug", ".card") == [T(".", .punctuation)])
    }

    @Test func attributesInParentheses() {
        #expect(lex("a.pug", "a(href=\"/x\", target='_blank') link") == [
            T("a", .function), T("(", .punctuation), T("=", .punctuation), T("\"/x\"", .string),
            T(",", .punctuation), T("=", .punctuation), T("'_blank'", .string), T(")", .punctuation),
        ])
    }

    @Test func classAndIdFollowedByAttributes() {
        let tokens = lex("a.pug", "div.card(data-id=\"1\")")
        #expect(has(tokens, "card", .function))
        #expect(has(tokens, "\"1\"", .string))
    }

    @Test func commentsAreLineComments() {
        #expect(lex("a.pug", "// a comment") == [T("// a comment", .comment)])
        #expect(lex("a.pug", "  //- hidden") == [T("//- hidden", .comment)])
        #expect(lex("a.pug", "p text // trailing").last == T("// trailing", .comment))
    }

    @Test func stringsAndKeywords() {
        #expect(lex("a.pug", "if user") == [T("if", .keyword)])
        #expect(lex("a.pug", "each item in items") == [T("each", .keyword), T("in", .keyword)])
        #expect(lex("a.pug", "mixin card(title)") == [T("mixin", .keyword), T("card", .function), T("(", .punctuation), T(")", .punctuation)])
        #expect(lex("a.pug", "include header.pug") == [T("include", .keyword), T(".", .punctuation)])
        #expect(lex("a.pug", "p= \"text\"").contains(T("\"text\"", .string)))
        #expect(lex("a.pug", "- var x = true").contains(T("true", .number)))
    }

    @Test func nothingCarriesBetweenLines() {
        #expect(endState("a.pug", lines: ["// c", "p(a=\"b", "c\")"]) == .normal)
    }
}

@Suite("Lexer: data file types")
struct LexerNewFileTypeTests {
    @Test func jsonlLinesAreJson() {
        #expect(lexAll("a.jsonl", #"{"a": 1, "b": "x"}"#).contains(T("\"a\"", .variable)))
        #expect(lex("a.jsonl", #"{"a": 1}"#).contains(T("1", .number)))
    }

    @Test func mdcIsMarkdown() {
        #expect(lex("a.mdc", "# Title") == [T("# Title", .tag)])
    }

    @Test func mjmlIsMarkup() {
        #expect(lex("a.mjml", "<mj-text>") == [T("<", .punctuation), T("mj-text", .tag), T(">", .punctuation)])
    }

    @Test(arguments: [".env", ".env.local", ".env.production", ".nuxtrc", ".yarnrc"])
    func iniStyleKeyValues(_ file: String) {
        #expect(lexAll(file, "KEY=value # c") == [T("KEY", .variable), T("=", .punctuation), T("value", .string), T("# c", .comment)])
        #expect(lex(file, "# note") == [T("# note", .comment)])
    }

    @Test func gitBlameIgnoreRevsHasHashComments() {
        #expect(lex(".git-blame-ignore-revs", "# reformat").first == T("# reformat", .comment))
        #expect(lex(".git-blame-ignore-revs", "deadbeef").isEmpty)
    }
}
