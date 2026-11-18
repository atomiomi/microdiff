import MicroDiffCore
import Testing

private func variables(_ file: String, _ line: String) -> [String] {
    lexAll(file, line).filter { $0.kind == .variable }.map(\.text)
}

@Suite("Lexer: variable tokens")
struct LexerVariableTests {
    @Test func ordinaryIdentifiersInCodeAreVariables() {
        #expect(lexAll("x.ts", "const props = draft.value + 1") == [
            T("const", .keyword), T("props", .variable), T("=", .operator), T("draft", .variable),
            T(".", .punctuation), T("value", .variable), T("+", .operator), T("1", .number),
        ])
        #expect(variables("x.ts", "{ method: 'POST', body }") == ["method", "body"])
        #expect(variables("x.ts", "function f(a, b: number) {}") == ["a", "b"])
        #expect(variables("x.rs", "let mut tree = foo;") == ["tree", "foo"])
        #expect(variables("x.py", "s = other") == ["s", "other"])
    }

    @Test func otherKindsKeepPriority() {
        let tokens = lexAll("x.ts", "if (ok) return Foo.bar(true, null, x)")
        #expect(tokens.filter { $0.kind == .variable }.map(\.text) == ["ok", "x"])
        #expect(tokens.contains(T("bar", .function)) && tokens.contains(T("Foo", .type)))
        #expect(tokens.contains(T("true", .number)))
    }

    @Test func variablesInsideStringsAndCommentsAreNot() {
        #expect(variables("x.ts", "'abc def' // ghi") == [])
        #expect(variables("x.ts", "/* abc */ x") == ["x"])
    }

    @Test func embeddedScriptAndMustache() {
        var l = LineLexer(file: "A.vue")
        l.feedAll("<script setup lang=\"ts\">")
        #expect(l.feedAll("const draft = ref('')").contains(T("draft", .variable)))
        l.feedAll("</script>")
        #expect(l.feedAll("<p>plain text {{ count + other }}</p>").filter { $0.kind == .variable }.map(\.text) == ["count", "other"])
        var html = LineLexer(file: "a.html")
        html.feedAll("<script>")
        #expect(html.feedAll("let n = 1").contains(T("n", .variable)))
    }

    @Test(arguments: ["a.html", "A.vue", "a.svelte"])
    func markupTextStaysPlain(_ file: String) {
        #expect(lexAll(file, "<p class=\"a\">some words here</p>").allSatisfy { $0.kind != .variable })
    }

    @Test func proseAndStylesheetsHaveNoVariablesExceptCssOnes() {
        for (file, line) in [
            ("a.md", "# Title with words"), ("a.md", "text *em* `code` [link](url)"),
            ("a.css", ".chat { display: flex; color: #6caeef; }"), ("a.css", "#id div:hover { margin: 12px }"),
        ] {
            #expect(lexAll(file, line).allSatisfy { $0.kind != .variable }, "\(file): \(line)")
        }
    }
}
