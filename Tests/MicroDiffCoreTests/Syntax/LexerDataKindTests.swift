import MicroDiffCore
import Testing

@Suite("Lexer: data file keys and values")
struct LexerDataKindTests {
    @Test(arguments: ["x.yml", "x.toml", "x.ini", ".env", "x.properties"])
    func keysAreVariables(_ file: String) {
        let separator = file.hasSuffix("yml") ? ": " : "="
        #expect(lexAll(file, "name\(separator)5").first == T("name", .variable))
    }

    @Test func jsonKeysAreVariablesAndValuesKeepTheirKinds() {
        let tokens = lexAll("x.json", #"{ "key": "v", "n": 1, "t": true, "z": null, "list": ["a"] }"#)
        #expect(tokens.filter { $0.kind == .variable }.map(\.text) == [#""key""#, #""n""#, #""t""#, #""z""#, #""list""#])
        #expect(tokens.filter { $0.kind == .string }.map(\.text) == [#""v""#, #""a""#])
        #expect(tokens.filter { $0.kind == .number }.map(\.text) == ["1", "true", "null"])
        #expect(lexAll("x.json", #""k": "a: b""#).last == T(#""a: b""#, .string))
    }

    @Test func tomlSectionNamesStayKeywords() {
        #expect(lexAll("x.toml", "[package]") == [T("[", .punctuation), T("package", .keyword), T("]", .punctuation)])
        #expect(lexAll("x.ini", "[core]").contains(T("core", .keyword)))
    }

    @Test(arguments: [("x.yml", "a: hello world"), ("x.toml", "a = hello"), ("x.ini", "a = hello world"), (".env", "A=hello world")])
    func bareValuesAreStrings(_ file: String, _ line: String) {
        let tokens = lexAll(file, line)
        #expect(tokens.last?.kind == .string)
        #expect(tokens.last?.text.hasPrefix("hello") == true)
    }

    @Test func bareValueRunsToTheCommentAsOneToken() {
        #expect(lexAll("x.yml", "a: hello big world # note") == [
            T("a", .variable), T(":", .punctuation), T("hello big world", .string), T("# note", .comment),
        ])
        #expect(lexAll("x.ini", "a = x y ; note").last == T("; note", .comment))
        #expect(lexAll(".env", "PATH=/usr/bin:/bin").last == T("/usr/bin:/bin", .string))
    }

    @Test(arguments: ["true", "false", "yes", "no", "null", "~", "True", "NO", "Null", "42", "-1.5", "0x1F", "2024-01-02"])
    func literalsAndNumbersAreNumbers(_ value: String) {
        #expect(lexAll("x.yml", "a: \(value)").last == T(value, .number))
        #expect(lexAll(".env", "A=\(value)").last == T(value, .number))
    }

    @Test(arguments: ["yesterday", "nothing", "nullable", "1password", "truely", "42 apples"])
    func lookAlikesAreStrings(_ value: String) {
        #expect(lexAll("x.yml", "a: \(value)").last == T(value, .string))
    }

    @Test func yamlListItems() {
        #expect(lexAll("x.yml", "- item") == [T("-", .punctuation), T("item", .string)])
        #expect(lexAll("x.yml", "  - 42") == [T("-", .punctuation), T("42", .number)])
        #expect(lexAll("x.yml", "- true").last == T("true", .number))
        #expect(lexAll("x.yml", "- name: x") == [T("-", .punctuation), T("name", .variable), T(":", .punctuation), T("x", .string)])
    }

    @Test func yamlMappingStartHasNoValueToken() {
        #expect(lexAll("x.yml", "services:") == [T("services", .variable), T(":", .punctuation)])
        #expect(lexAll("x.yml", "services: # note") == [T("services", .variable), T(":", .punctuation), T("# note", .comment)])
        #expect(lexAll("x.yml", "- name:") == [T("-", .punctuation), T("name", .variable), T(":", .punctuation)])
    }

    @Test func yamlAnchorsAliasesAndTagsStayPlain() {
        #expect(lexAll("x.yml", "a: &base value").last == T("value", .string))
        #expect(lexAll("x.yml", "b: *base") == [T("b", .variable), T(":", .punctuation)])
        #expect(lexAll("x.yml", "c: !!str 5") == [T("c", .variable), T(":", .punctuation), T("5", .number)])
    }

    @Test func yamlFlowCollections() {
        #expect(lexAll("x.yml", "a: [x, 1, true]").filter { $0.kind != .punctuation } == [
            T("a", .variable), T("x", .string), T("1", .number), T("true", .number),
        ])
        #expect(lexAll("x.yml", "a: {b: 1, c: two}").filter { $0.kind != .punctuation } == [
            T("a", .variable), T("b", .variable), T("1", .number), T("c", .variable), T("two", .string),
        ])
    }

    @Test func yamlBlockScalars() {
        let lines = lexAll("x.yml", lines: [
            "key: |", "  first line", "", "  second: not a key", "next: 1", "list:", "  - a: >-", "      folded", "      more", "    sibling: yes", "tail: x",
        ])
        #expect(lines[0] == [T("key", .variable), T(":", .punctuation), T("|", .punctuation)])
        #expect(lines[1] == [T("first line", .string)])
        #expect(lines[2].isEmpty)
        #expect(lines[3] == [T("second: not a key", .string)])
        #expect(lines[4] == [T("next", .variable), T(":", .punctuation), T("1", .number)])
        #expect(lines[6] == [T("-", .punctuation), T("a", .variable), T(":", .punctuation), T(">-", .punctuation)])
        #expect(lines[7] == [T("folded", .string)] && lines[8] == [T("more", .string)])
        // A sibling key at the column of `a` ends the block.
        #expect(lines[9] == [T("sibling", .variable), T(":", .punctuation), T("yes", .number)])
        #expect(lines[10].first == T("tail", .variable))
    }

    @Test func blockScalarMarkerOnlyCountsAloneAndOnlyInYaml() {
        #expect(lexAll("x.yml", "a: |x").last == T("|x", .string))
        var l = LineLexer(file: "x.yml")
        l.feedAll("a: | # c")
        #expect(l.state != .normal)
        l.feedAll("b: 1")
        #expect(l.state == .normal)
        var ini = LineLexer(file: "x.ini")
        ini.feedAll("a = |")
        #expect(ini.state == .normal)
    }

    @Test func tomlArrayLinesSplitOnCommas() {
        #expect(lexAll("x.toml", "  1, 2, 3,").filter { $0.kind == .number }.map(\.text) == ["1", "2", "3"])
        #expect(lexAll("x.toml", #"  "a", b,"#).filter { $0.kind == .string }.map(\.text) == [#""a""#, "b"])
        #expect(lexAll("x.toml", "t = { a = 1, b = \"x\" }").filter { $0.kind == .variable }.map(\.text) == ["t", "a", "b"])
    }
}

@Suite("Lexer: Markdown inline kinds")
struct LexerMarkdownInlineTests {
    @Test func headingsAreTags() {
        #expect(lexAll("x.md", "## Heading with *words*") == [T("## Heading with *words*", .tag)])
    }

    @Test func boldAndItalic() {
        #expect(lexAll("x.md", "a **bold** and __also__ b") == [T("**bold**", .attribute), T("__also__", .attribute)])
        #expect(lexAll("x.md", "a *it* and _also_ b") == [T("*it*", .keyword), T("_also_", .keyword)])
        #expect(lexAll("x.md", "**bold**.") == [T("**bold**", .attribute)])
        #expect(lexAll("x.md", "*one **two** three*").first?.kind == .keyword)
    }

    @Test(arguments: ["snake_case_words", "a_b and c_d", "2 * 3 * 4", "2*3*4", "a * b", "just * alone", "*unclosed", "** spaced **", "_ x _", "path/to/my_file_name.txt", "http://x/a_b_c"])
    func nearMissesAreNotEmphasis(_ line: String) {
        #expect(lexAll("x.md", line).isEmpty)
    }

    @Test func emphasisClosesOnTheSameLineOnly() {
        var l = LineLexer(file: "x.md")
        #expect(l.feedAll("an *open").isEmpty)
        #expect(l.feedAll("close* here").isEmpty)
    }

    @Test func codeSpansAndFencesStayAsTheyAre() {
        #expect(lexAll("x.md", "use `a*b*c` and `__x__`") == [T("`a*b*c`", .string), T("`__x__`", .string)])
        #expect(lexAll("x.md", "*it `code*` x*").first?.kind == .keyword)
        let lines = lexAll("x.md", lines: ["```", "**not bold** [a](b)", "```"])
        #expect(lines[1] == [T("**not bold** [a](b)", .string)])
    }

    @Test func linkTextIsAFunctionAndUrlAString() {
        #expect(lexAll("x.md", "see [the docs](https://x.io/a_b) now") == [T("the docs", .function), T("https://x.io/a_b", .string)])
        #expect(lexAll("x.md", "[a] and [b] but (c)").isEmpty)
        #expect(lexAll("x.md", "[](x)") == [T("x", .string)])
    }

    @Test func listMarkersAndQuotesAreUnchanged() {
        #expect(lexAll("x.md", "- *it* item") == [T("-", .punctuation), T("*it*", .keyword)])
        #expect(lexAll("x.md", "* item") == [T("*", .punctuation)])
        #expect(lexAll("x.md", "1. first") == [T("1.", .punctuation)])
        #expect(lexAll("x.md", "> quote **x**") == [T("> quote **x**", .comment)])
    }

    @Test func escapedStarIsNotAnOpener() {
        #expect(lexAll("x.md", #"\*not\* emphasis"#).isEmpty)
    }
}
