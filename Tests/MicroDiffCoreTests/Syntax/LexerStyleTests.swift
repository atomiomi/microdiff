import MicroDiffCore
import Testing

private func kinds(_ file: String, _ line: String, _ kind: TokenKind) -> [String] {
    lexAll(file, line).filter { $0.kind == kind }.map(\.text)
}

@Suite("Lexer: CSS / SCSS / Less selectors and values")
struct LexerStyleTests {
    @Test(arguments: ["x.css", "x.scss", "x.less"])
    func selectorKinds(_ file: String) {
        let tokens = lexAll(file, ".chat .btn-primary #app div > button, a:hover::before {")
        #expect(tokens.filter { $0.kind == .attribute }.map(\.text) == [".chat", ".btn-primary"])
        #expect(tokens.filter { $0.kind == .function }.map(\.text) == ["#app"])
        #expect(tokens.filter { $0.kind == .tag }.map(\.text) == ["div", "button", "a"])
        #expect(tokens.filter { $0.kind == .operator }.map(\.text) == [">", "hover", "before"])
        #expect(tokens.contains(T("::", .punctuation)) && tokens.contains(T(":", .punctuation)))
    }

    @Test func attributeAndNotSelectors() {
        let tokens = lexAll("x.css", #"input[type="text"]:not(.off):nth-child(2n+1) {"#)
        #expect(tokens.contains(T("input", .tag)))
        #expect(tokens.contains(T("type", .attribute)) && tokens.contains(T(#""text""#, .string)))
        #expect(tokens.contains(T("not", .operator)) && tokens.contains(T("nth-child", .operator)))
        #expect(tokens.contains(T(".off", .attribute)))
    }

    @Test func scssAmpersandAndNesting() {
        #expect(lexAll("x.scss", "&:hover {").prefix(3) == [T("&", .keyword), T(":", .punctuation), T("hover", .operator)])
        #expect(lexAll("x.scss", "&-suffix, &__elem {").filter { $0.kind == .keyword }.map(\.text) == ["&-suffix", "&__elem"])
        let nested = lexAll("x.scss", lines: [".a {", "  .b {", "    color: red;", "    &:hover { color: blue; }", "  }", "}"])
        #expect(nested[1].contains(T(".b", .attribute)))
        #expect(nested[2] == [T(":", .punctuation), T("red", .number), T(";", .punctuation)])
        #expect(nested[3].contains(T("hover", .operator)) && nested[3].contains(T("blue", .number)))
        #expect(!nested[3].contains { $0.kind == .tag })
        #expect(lexAll("x.scss", ".a { .b { color: red; } }").filter { $0.kind == .attribute }.map(\.text) == [".a", ".b"])
    }

    @Test(arguments: ["x.css", "x.scss"])
    func propertyNamesAreNotTokensAndValueWordsAreNumbers(_ file: String) {
        let tokens = lexAll(file, "  display: flex;")
        #expect(tokens == [T(":", .punctuation), T("flex", .number), T(";", .punctuation)])
        #expect(kinds(file, "a { margin: 0 auto; border: 1px solid #fff }", .number) == ["0", "auto", "1px", "solid", "#fff"])
        #expect(kinds(file, "a { text-align: center; float: none }", .number) == ["center", "none"])
    }

    @Test func oneLineRulesAndSelectorVersusDeclaration() {
        let hover = lexAll("x.scss", "&:hover { color: #6caeef; }")
        #expect(hover == [
            T("&", .keyword), T(":", .punctuation), T("hover", .operator), T("{", .punctuation), T(":", .punctuation),
            T("#6caeef", .number), T(";", .punctuation), T("}", .punctuation),
        ])
        // `a:hover {` is a selector, `color:red;` a declaration, even without spaces.
        #expect(kinds("x.scss", "a:hover { }", .tag) == ["a"])
        #expect(kinds("x.scss", "color:red;", .tag) == [])
        #expect(kinds("x.scss", "color:red;", .number) == ["red"])
        #expect(kinds("x.css", "a{color:red}b{margin:0}", .tag) == ["a", "b"])
        // No `{` and no `;` on the line: a colon means declaration, a trailing comma means a selector list.
        #expect(kinds("x.css", "color: red", .number) == ["red"])
        #expect(kinds("x.css", "h1,", .tag) == ["h1"])
        #expect(kinds("x.css", ".btn", .attribute) == [".btn"])
    }

    @Test func selectorListsAcrossLines() {
        let lines = lexAll("x.css", lines: ["h1,", "h2,", ".x {", "  color: red;", "}"])
        #expect(lines[0].contains(T("h1", .tag)) && lines[1].contains(T("h2", .tag)))
        #expect(lines[2].contains(T(".x", .attribute)))
    }

    @Test func valuesCarryOverLines() {
        let lines = lexAll("x.css", lines: [
            ".a {", "  transition:", "    opacity .2s,", "    color red;", "  margin: 0;", "}",
        ])
        #expect(lines[2] == [T("opacity", .number), T(".2s", .number), T(",", .punctuation)])
        #expect(lines[3] == [T("color", .number), T("red", .number), T(";", .punctuation)])
        #expect(lines[4].first == T(":", .punctuation))
        // A plain word list that continues is not a selector.
        let list = lexAll("x.css", lines: ["a {", "  font-family: Arial,", "    sans-serif;", "}"])
        #expect(list[2] == [T("sans-serif", .number), T(";", .punctuation)])
    }

    @Test func variablesAndCustomProperties() {
        #expect(kinds("x.scss", "$gap: 12px;", .variable) == ["$gap"])
        #expect(kinds("x.scss", "a { margin: $gap $gap-lg; }", .variable) == ["$gap", "$gap-lg"])
        #expect(kinds("x.css", ":root { --brand-color: #fff; }", .variable) == ["--brand-color"])
        #expect(kinds("x.css", "a { color: var(--brand-color); }", .variable) == ["--brand-color"])
    }

    @Test func atRulesStayKeywords() {
        for line in ["@media (max-width: 600px) {", "@use \"x\" as y;", "@include foo($a);", "@mixin m($a) {", "@import 'a';"] {
            let tokens = lexAll("x.scss", line)
            #expect(tokens.first?.kind == .keyword)
            #expect(!tokens.contains { $0.kind == .tag })
        }
        let media = lexAll("x.css", "@media (max-width: 600px) {")
        #expect(media.contains(T("600px", .number)))
        #expect(lexAll("x.scss", "@include foo($a);").contains(T("foo", .function)))
        #expect(lexAll("x.less", "@color: red;") == [T("@color", .keyword), T(":", .punctuation), T("red", .number), T(";", .punctuation)])
    }

    @Test func functionsStringsAndUrls() {
        let value = lexAll("x.css", #"a { background: url(img/a.png) rgba(0, 0, 0, .5), calc(1px + 2px); content: "x"; }"#)
        #expect(value.filter { $0.kind == .function }.map(\.text) == ["url", "rgba", "calc"])
        #expect(value.contains(T("img/a.png", .string)) && value.contains(T(#""x""#, .string)))
        #expect(lexAll("x.css", #"a { background: url("a.png"); }"#).contains(T(#""a.png""#, .string)))
        #expect(lexAll("x.css", "a { color: red !important; }").contains(T("!important", .keyword)))
    }

    @Test func idSelectorsAreNotHexColors() {
        // In selector position `#fff` is an id, in a value it is a color.
        #expect(lexAll("x.css", "#fff { color: #fff }").filter { $0.kind == .function }.map(\.text) == ["#fff"])
        #expect(lexAll("x.css", "#fff { color: #fff }").filter { $0.kind == .number }.map(\.text) == ["#fff"])
    }

    @Test func interpolationDoesNotEndTheStatement() {
        let tokens = lexAll("x.scss", ".a-#{$name} { width: calc(100% - #{$gap}); }")
        #expect(tokens.contains(T("$name", .variable)) && tokens.contains(T("$gap", .variable)))
        #expect(tokens.contains(T("width", .tag)) == false)
    }

    @Test func insideVueStyleBlock() {
        var l = LineLexer(file: "A.vue")
        l.feedAll("<style scoped lang=\"scss\">")
        #expect(l.feedAll(".chat {").contains(T(".chat", .attribute)))
        #expect(l.feedAll("  display: flex;") == [T(":", .punctuation), T("flex", .number), T(";", .punctuation)])
        #expect(l.feedAll("  &:hover { color: #6caeef; }").contains(T("hover", .operator)))
    }

    @Test func plainLinesNeverCarryStateWithoutAContinuation() {
        var l = LineLexer(file: "x.css")
        l.feedAll("a { color: red }")
        #expect(l.state == .normal)
        l.feedAll("a { color: red,")
        #expect(l.state != .normal)
        l.feedAll("blue; }")
        #expect(l.state == .normal)
    }
}

@Suite("Lexer: component tags in templates")
struct LexerComponentTagTests {
    @Test(arguments: ["A.vue", "A.svelte"])
    func uppercaseTagNamesAreTypesAndLowercaseAreTags(_ file: String) {
        let tokens = lexAll(file, #"<MessageList :messages="m" /><div></div><NuxtLink to="/">x</NuxtLink>"#)
        #expect(tokens.filter { $0.kind == .type }.map(\.text) == ["MessageList", "NuxtLink", "NuxtLink"])
        #expect(tokens.filter { $0.kind == .tag }.map(\.text) == ["div", "div"])
        #expect(lexAll(file, "</MessageList>").contains(T("MessageList", .type)))
    }

    @Test(arguments: ["a.html", "a.xml", "a.svg"])
    func plainMarkupKeepsTags(_ file: String) {
        let tokens = lexAll(file, "<Foo><bar></bar></Foo>")
        #expect(tokens.filter { $0.kind == .type }.isEmpty)
        #expect(tokens.filter { $0.kind == .tag }.map(\.text) == ["Foo", "bar", "bar", "Foo"])
    }

    @Test func vueTemplateLineInsideAFile() {
        var l = LineLexer(file: "A.vue")
        l.feedAll("<template>")
        #expect(l.feedAll("  <MessageList :messages=\"messages\" />").contains(T("MessageList", .type)))
        #expect(l.feedAll("  <section class=\"chat\">").contains(T("section", .tag)))
    }
}

@Suite("Lexer: CSS comments across lines")
struct LexerStyleMultilineTests {
    @Test func aBlockCommentOverSeveralLinesStaysACommentAndEndsWhereItEnds() {
        let rows = lexAll("x.css", lines: ["/* one", "two", "three */ a { color: red }"])
        #expect(rows[1] == [T("two", .comment)])
        #expect(rows[2].first == T("three */", .comment))
        #expect(rows[2].contains(T("red", .number)))
    }
}
