import MicroDiffCore
import Testing

@Suite("Lexer: JSON and CSS")
struct LexerJSONCSSTests {
    @Test func jsonKeyIsAVariableAndValueIsAString() {
        #expect(lexAll("x.json", #"  "name": "micro","#) == [
            T(#""name""#, .variable), T(":", .punctuation), T(#""micro""#, .string), T(",", .punctuation),
        ])
    }

    @Test func jsonKeyWithSpaceBeforeColon() {
        #expect(lexAll("x.json", #""a" : 1"#) == [T(#""a""#, .variable), T(":", .punctuation), T("1", .number)])
    }

    @Test func jsonLiteralsAndNumbers() {
        #expect(lexAll("x.json", #""a": [true, false, null, -1.5e3, 42]"#) == [
            T(#""a""#, .variable), T(":", .punctuation), T("[", .punctuation), T("true", .number), T(",", .punctuation),
            T("false", .number), T(",", .punctuation), T("null", .number), T(",", .punctuation),
            T("-", .punctuation), T("1.5e3", .number), T(",", .punctuation), T("42", .number), T("]", .punctuation),
        ])
    }

    @Test func jsonStringsInArraysAreValues() {
        #expect(lexAll("x.json", #"["a", "b"]"#) == [
            T("[", .punctuation), T(#""a""#, .string), T(",", .punctuation), T(#""b""#, .string), T("]", .punctuation),
        ])
    }

    @Test func jsonStringContainingColonIsStillAValue() {
        #expect(lexAll("x.json", #""k": "a: b""#).last == T(#""a: b""#, .string))
    }

    @Test func jsonEscapedQuoteInKey() {
        #expect(lexAll("x.json", #""a\"b": 1"#).first == T(#""a\"b""#, .variable))
    }

    @Test func jsonCapitalizedWordsAreNotTypes() {
        #expect(lexAll("x.json", "Foo").isEmpty)
    }

    @Test func jsoncComments() {
        let lines = lexAll("x.jsonc", lines: [#"{ // note"#, "/* a", "b */ }"])
        #expect(lines[0].last == T("// note", .comment))
        #expect(lines[1] == [T("/* a", .comment)])
        #expect(lines[2] == [T("b */", .comment), T("}", .punctuation)])
    }

    // MARK: CSS

    @Test func cssPropertyNameIsPlainAndValuesAreNumbers() {
        #expect(lexAll("x.css", "  color: red;") == [T(":", .punctuation), T("red", .number), T(";", .punctuation)])
        #expect(lexAll("x.css", "  background: #fff;") == [
            T(":", .punctuation), T("#fff", .number), T(";", .punctuation),
        ])
        #expect(lexAll("x.css", "  border-color: #1a2b3c;").first == T(":", .punctuation))
    }

    @Test(arguments: ["#fff", "#FFF", "#aabbcc", "#abcdef12"])
    func cssHexColorIsOneNumber(_ color: String) {
        #expect(lexAll("x.css", "a { color: \(color); }").contains(T(color, .number)))
    }

    @Test(arguments: ["x.css", "x.scss", "x.less"])
    func cssHexColorStartingWithADigitIsOneNumber(_ file: String) {
        for color in ["#6caeef", "#6caeef80", "#123", "#0a0a"] {
            #expect(lexAll(file, "a { color: \(color); }").contains(T(color, .number)))
            #expect(!lexAll(file, "a { color: \(color); }").contains(T("#", .punctuation)))
        }
        #expect(!lexAll(file, "#1x { }").contains { $0.kind == .number })
    }

    @Test(arguments: ["#my-id", "#main", "#abc-def", "#face-card", "#header1"])
    func cssIdSelectorIsNotAColor(_ selector: String) {
        let tokens = lexAll("x.css", "\(selector) {")
        #expect(!tokens.contains { $0.kind == .number || $0.kind == .keyword }, "tokens: \(tokens)")
    }

    @Test func cssAtRuleIsAKeyword() {
        let tokens = lexAll("x.css", "@media (max-width: 600px) {")
        #expect(tokens.first == T("@media", .keyword))
        #expect(tokens.contains(T("600px", .number)))
    }

    @Test func cssAtRuleWithDashes() {
        #expect(lexAll("x.css", "@font-face {").first == T("@font-face", .keyword))
    }

    @Test func cssPseudoClassIsNotAProperty() {
        #expect(lexAll("x.css", "a:hover { }").contains { $0.kind == .type } == false)
    }

    @Test func cssPropertyIsFirstOfTheLineOrFollowsBraceOrSemicolon() {
        #expect(lexAll("x.css", "a { color: red }") == [
            T("a", .tag), T("{", .punctuation), T(":", .punctuation), T("red", .number), T("}", .punctuation),
        ])
    }

    @Test func cssNumbersWithUnits() {
        #expect(lexAll("x.css", "  margin: 0 1.5em .5rem;").filter { $0.kind == .number } == [
            T("0", .number), T("1.5em", .number), T(".5rem", .number),
        ])
    }

    @Test func cssBlockCommentsSpanLines() {
        let lines = lexAll("x.css", lines: ["/* a", "color: red; */", "color: blue;"])
        #expect(lines[0] == [T("/* a", .comment)])
        #expect(lines[1] == [T("color: red; */", .comment)])
        #expect(lines[2] == [T(":", .punctuation), T("blue", .number), T(";", .punctuation)])
    }

    @Test func cssStrings() {
        #expect(lexAll("x.css", #"  content: "a";"#).contains(T(#""a""#, .string)))
    }

    @Test func scssLineComment() {
        #expect(lexAll("x.scss", "$x: 1; // note").last == T("// note", .comment))
    }
}

@Suite("Lexer: key = value formats")
struct LexerKeyValueTests {
    @Test func yamlKeyAndPlainValue() {
        #expect(lexAll("x.yml", "name: John") == [T("name", .variable), T(":", .punctuation), T("John", .string)])
    }

    @Test func yamlNumbersAndBooleans() {
        #expect(lexAll("x.yml", "count: 42") == [T("count", .variable), T(":", .punctuation), T("42", .number)])
        #expect(lexAll("x.yml", "debug: true").last == T("true", .number))
        #expect(lexAll("x.yml", "x: null").last == T("null", .number))
        #expect(lexAll("x.yml", "ratio: -1.5e3").last == T("-1.5e3", .number))
    }

    @Test func yamlQuotedValue() {
        #expect(lexAll("x.yml", #"title: "a b""#).last == T(#""a b""#, .string))
        #expect(lexAll("x.yml", "title: 'a b'").last == T("'a b'", .string))
    }

    @Test func yamlQuotedKey() {
        #expect(lexAll("x.yml", #""my key": 1"#) == [T(#""my key""#, .variable), T(":", .punctuation), T("1", .number)])
        #expect(lexAll("x.yml", #""a:b": 1"#).first == T(#""a:b""#, .variable))
        #expect(lexAll("x.yml", "'k': v").first == T("'k'", .variable))
    }

    @Test func yamlCommentLine() {
        #expect(lexAll("x.yml", "# note") == [T("# note", .comment)])
        #expect(lexAll("x.yml", "   # note") == [T("# note", .comment)])
    }

    @Test func yamlTrailingComment() {
        #expect(lexAll("x.yml", "a: 1 # note") == [
            T("a", .variable), T(":", .punctuation), T("1", .number), T("# note", .comment),
        ])
        #expect(lexAll("x.yml", "a: b # note").last == T("# note", .comment))
    }

    @Test func yamlHashInsideAWordIsNotAComment() {
        #expect(!lexAll("x.yml", "color: red#blue").contains { $0.kind == .comment })
        #expect(!lexAll("x.yml", #"s: "a # b""#).contains { $0.kind == .comment })
    }

    @Test func yamlListMarkers() {
        #expect(lexAll("x.yml", "- item") == [T("-", .punctuation), T("item", .string)])
        #expect(lexAll("x.yml", "  - 42") == [T("-", .punctuation), T("42", .number)])
        #expect(lexAll("x.yml", "- name: x") == [T("-", .punctuation), T("name", .variable), T(":", .punctuation), T("x", .string)])
        #expect(lexAll("x.yml", "- - nested") == [T("-", .punctuation), T("-", .punctuation), T("nested", .string)])
    }

    @Test func yamlDocumentMarkers() {
        #expect(lexAll("x.yml", "---") == [T("---", .punctuation)])
        #expect(lexAll("x.yml", "...") == [T("...", .punctuation)])
    }

    @Test func yamlKeyWithEmptyValueAtEndOfLine() {
        #expect(lexAll("x.yml", "services:") == [T("services", .variable), T(":", .punctuation)])
    }

    @Test func yamlFlowCollections() {
        #expect(lexAll("x.yml", "a: [1, two, 3]") == [
            T("a", .variable), T(":", .punctuation), T("[", .punctuation), T("1", .number), T(",", .punctuation),
            T("two", .string), T(",", .punctuation), T("3", .number), T("]", .punctuation),
        ])
        #expect(lexAll("x.yml", "a: {b: 1}").contains(T("{", .punctuation)))
    }

    @Test func yamlUrlValueKeepsHttpOutOfTheKeyAndIsNotAComment() {
        #expect(lexAll("x.yml", "url: http://example.com") == [T("url", .variable), T(":", .punctuation), T("http://example.com", .string)])
        #expect(lexAll("x.yml", "- http://example.com/a#b").isEmpty == false)
        #expect(!lexAll("x.yml", "url: http://example.com/a#frag").contains { $0.kind == .comment })
    }

    @Test func yamlColonWithoutSpaceDoesNotSplitTheKey() {
        // "a:b" is one plain scalar, not a key.
        #expect(lexAll("x.yml", "a:b") == [T("a:b", .string)])
    }

    @Test func yamlTimestampIsANumber() {
        #expect(lexAll("x.yml", "at: 2024-01-02T03:04:05Z").last == T("2024-01-02T03:04:05Z", .number))
    }

    @Test func tomlKeyAndStringValue() {
        #expect(lexAll("x.toml", #"name = "micro""#) == [T("name", .variable), T("=", .punctuation), T(#""micro""#, .string)])
        #expect(lexAll("x.toml", "n = 1_000") == [T("n", .variable), T("=", .punctuation), T("1_000", .number)])
        #expect(lexAll("x.toml", "b = true").last == T("true", .number))
    }

    @Test func tomlSectionHeader() {
        #expect(lexAll("x.toml", "[package]") == [T("[", .punctuation), T("package", .keyword), T("]", .punctuation)])
        #expect(lexAll("x.toml", "[a.b]").contains(T("a.b", .keyword)))
    }

    @Test func tomlTableArrayHeader() {
        #expect(lexAll("x.toml", "[[bin]]") == [T("[[", .punctuation), T("bin", .keyword), T("]]", .punctuation)])
    }

    @Test func tomlHeaderWithTrailingComment() {
        #expect(lexAll("x.toml", "[a] # note") == [
            T("[", .punctuation), T("a", .keyword), T("]", .punctuation), T("# note", .comment),
        ])
    }

    @Test func tomlInlineArrayValueIsNotAHeader() {
        let tokens = lexAll("x.toml", "deps = [1, 2]")
        #expect(tokens.first == T("deps", .variable))
        #expect(!tokens.contains { $0.kind == .keyword })
    }

    @Test func tomlTrailingCommentAfterValue() {
        #expect(lexAll("x.toml", "a = 1 # note").last == T("# note", .comment))
    }

    @Test func iniSectionAndSemicolonComment() {
        #expect(lexAll("x.ini", "[core]") == [T("[", .punctuation), T("core", .keyword), T("]", .punctuation)])
        #expect(lexAll("x.ini", "; note") == [T("; note", .comment)])
        #expect(lexAll("x.ini", "# note") == [T("# note", .comment)])
        #expect(lexAll("x.ini", "a = 1 ; note").last == T("; note", .comment))
    }

    @Test func iniKeyValueWithoutSpaces() {
        #expect(lexAll("x.ini", "key=value") == [T("key", .variable), T("=", .punctuation), T("value", .string)])
        #expect(lexAll("x.ini", "key = 5") == [T("key", .variable), T("=", .punctuation), T("5", .number)])
    }

    @Test(arguments: [".env", "prod.env", ".gitconfig"])
    func dotEnvStyleFilesUseKeyValueColoring(_ file: String) {
        #expect(lexAll(file, "KEY=value") == [T("KEY", .variable), T("=", .punctuation), T("value", .string)])
        #expect(lexAll(file, "PORT=8080") == [T("PORT", .variable), T("=", .punctuation), T("8080", .number)])
        #expect(lexAll(file, "DEBUG=true").last == T("true", .number))
        #expect(lexAll(file, #"NAME="a b" # note"#) == [
            T("NAME", .variable), T("=", .punctuation), T(#""a b""#, .string), T("# note", .comment),
        ])
    }

    @Test func urlValueAfterEqualsIsNotAComment() {
        #expect(lexAll(".env", "URL=http://example.com/path").isEmpty == false)
        #expect(lexAll(".env", "URL=http://example.com/path#frag") == [T("URL", .variable), T("=", .punctuation), T("http://example.com/path#frag", .string)])
    }

    @Test func blankAndWhitespaceOnlyLines() {
        #expect(lexAll("x.yml", "").isEmpty)
        #expect(lexAll("x.yml", "   \t").isEmpty)
    }

    @Test func keyValueLinesNeverCarryState() {
        var lexer = LineLexer(file: "x.yml")
        lexer.feed(#"a: "unterminated"#)
        #expect(lexer.state == .normal)
        #expect(lexer.feed("b: 1").last == T("1", .number))
    }
}
