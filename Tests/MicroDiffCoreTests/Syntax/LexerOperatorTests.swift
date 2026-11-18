import MicroDiffCore
import Testing

private func operators(_ file: String, _ line: String) -> [String] {
    lexAll(file, line).filter { $0.kind == .operator }.map(\.text)
}

@Suite("Lexer: operators")
struct LexerOperatorTests {
    @Test func typeScriptOperators() {
        #expect(operators("x.ts", "a = b === c !== d && e || !f ?? g") == ["=", "===", "!==", "&&", "||", "!", "??"])
        #expect(operators("x.ts", "x += 1; y -= 2; z = a + b - c * d / e % f") == ["+=", "-=", "=", "+", "-", "*", "/", "%"])
        #expect(operators("x.ts", "a <= b, c >= d, e < f, g > h") == ["<=", ">=", "<", ">"])
        #expect(operators("x.ts", "a & b | c ^ d ~ e") == ["&", "|", "^", "~"])
        #expect(operators("x.ts", "ok ? a : b") == ["?"])
        #expect(operators("x.ts", "a?.b ?? c") == ["?.", "??"])
        #expect(operators("x.ts", "f(...args)") == ["..."])
    }

    @Test func punctuationStaysPunctuation() {
        let tokens = lexAll("x.ts", "f(a, [b]) { return c.d; } x: y")
        #expect(tokens.filter { $0.kind == .operator }.isEmpty)
        #expect(tokens.contains(T(",", .punctuation)) && tokens.contains(T(".", .punctuation)) && tokens.contains(T(":", .punctuation)))
        #expect(tokens.contains(T(";", .punctuation)))
    }

    @Test(arguments: ["x.js", "x.ts", "x.tsx"])
    func arrowIsAKeyword(_ file: String) {
        let tokens = lexAll(file, "const f = (a) => a + 1; g = x=>y")
        #expect(tokens.filter { $0.kind == .keyword }.map(\.text) == ["const", "=>", "=>"])
        #expect(tokens.filter { $0.kind == .operator }.map(\.text) == ["=", "+", "="])
    }

    @Test func arrowInsideVueMustache() {
        var l = LineLexer(file: "A.vue")
        l.feedAll("<script setup lang=\"ts\">")
        #expect(l.feedAll("const f = () => a ?? b").contains(T("=>", .keyword)))
        l.feedAll("</script>")
        let mustache = l.feedAll("<p>{{ a + b }}</p>")
        #expect(mustache.contains(T("+", .operator)))
        // Markup around it has no operators.
        #expect(mustache.filter { $0.kind == .operator }.count == 1)
    }

    @Test func swiftPythonAndRust() {
        #expect(operators("x.swift", "let a = b + c -> d ?? e") == ["=", "+", "->", "??"])
        #expect(operators("x.swift", "for i in 0..<10 { x = a ... b }") == ["..<", "=", "..."])
        #expect(operators("x.py", "x = a ** b // c != d") == ["=", "**", "//", "!="])
        #expect(operators("x.py", "def f(a) -> int:") == ["->"])
        #expect(operators("x.rs", "let x = a::b() -> c; for i in 0..10 { }") == ["=", "::", "->", ".."])
        #expect(operators("x.rs", "a & &b | c => d") == ["&", "&", "|", "=>"])
        #expect(operators("x.cpp", "std::cout << a;") == ["::", "<<"])
        #expect(operators("x.go", "x := 1; y <- ch") == [":=", "<-"])
    }

    @Test func nearMissesDivisionRegexAndJsx() {
        // Division is an operator, a regex literal is a string.
        let division = lexAll("x.ts", "a / b / c")
        #expect(division.filter { $0.kind == .operator }.map(\.text) == ["/", "/"])
        let regex = lexAll("x.ts", "x = /ab+c/g.test(s)")
        #expect(regex.contains(T("/ab+c/g", .string)) && operators("x.ts", "x = /ab+c/g.test(s)") == ["="])
        #expect(lexAll("x.ts", "ok = !/y/.test(a)").contains(T("/y/", .string)))
        #expect(lexAll("x.js", "a = b && /y/.test(a)").contains(T("/y/", .string)))
        // Comparison versus JSX versus generic call.
        #expect(operators("x.ts", "a < b") == ["<"])
        #expect(operators("x.ts", "if (a<b) {}") == ["<"])
        let jsx = lexAll("a.tsx", "const e = <div className=\"x\">hi</div>;")
        #expect(jsx.filter { $0.kind == .operator }.map(\.text) == ["="])
        #expect(jsx.contains(T("div", .tag)) && jsx.contains(T("className", .attribute)))
        let selfClosing = lexAll("a.jsx", "const e = <Foo a=\"1\" />;")
        #expect(selfClosing.filter { $0.kind == .operator }.map(\.text) == ["="])
        let generic = lexAll("x.ts", "const m = ref<number>(0)")
        #expect(generic.contains(T("ref", .function)))
        #expect(generic.filter { $0.kind == .operator }.map(\.text) == ["=", "<", ">"])
        #expect(operators("a.jsx", "a = x && <div/>").first == "=")
    }

    @Test func numberSignsAreSeparateOperators() {
        // A sign is an operator and the digits stay a number.
        #expect(lexAll("x.ts", "x = -1").filter { $0.kind != .variable } == [T("=", .operator), T("-", .operator), T("1", .number)])
        #expect(operators("x.ts", "f(-1.5)") == ["-"])
        #expect(operators("x.ts", "x = 2-1") == ["=", "-"])
    }

    @Test func arrowsAndPathsInLanguagesThatHaveThem() {
        #expect(operators("x.rs", "fn f() -> u8 { Foo::new() }") == ["->", "::"])
        #expect(operators("x.php", "$a->b; A::c();") == ["->", "::"])
        #expect(operators("x.rb", "A::B.new") == ["::"])
    }

    @Test func nothingInsideStringsOrComments() {
        #expect(operators("x.ts", #"s = "a + b => c" // x == y"#) == ["="])
        #expect(operators("x.ts", "/* a + b */ x") == [])
        #expect(operators("x.py", #"s = '''a -> b'''  # c == d"#) == ["="])
        #expect(operators("x.rs", "let u = \"http://x\"; // a -> b") == ["="])
    }

    @Test func noOperatorsOutsideCode() {
        for (file, line) in [
            ("a.html", "<a href=\"x\">1 + 2 = 3</a>"), ("a.json", #"{"a": -1, "b": "x=y"}"#),
            ("a.yml", "a: b + c"), ("a.toml", "a = 1"), ("a.ini", "a=b"), (".env", "A=b==c"),
            ("a.md", "1 + 2 = 3 -> **x**"), ("a.xml", "<a b=\"1\"/>"),
        ] {
            #expect(lexAll(file, line).allSatisfy { $0.kind != .operator }, "\(file)")
        }
    }

    @Test func adjacentOperatorsMergeIntoOneToken() {
        #expect(lexAll("x.ts", "a===b").filter { $0.kind == .operator } == [T("===", .operator)])
        #expect(lexAll("x.c", "a<<=b").filter { $0.kind == .operator } == [T("<<=", .operator)])
    }
}

@Suite("Lexer: this and super")
struct LexerThisSuperTests {
    @Test(arguments: ["x.js", "x.ts", "x.tsx", "x.jsx"])
    func thisAndSuperAreTypes(_ file: String) {
        let tokens = lexAll(file, "this.a = super.b(this)")
        #expect(tokens.filter { $0.kind == .type }.map(\.text) == ["this", "super", "this"])
    }

    @Test func otherLanguagesKeepThem() {
        #expect(lexAll("x.java", "this.a = super.b()").filter { $0.kind == .keyword }.map(\.text) == ["this", "super"])
        #expect(lexAll("x.py", "self.a").contains(T("self", .keyword)))
    }

    @Test func insideVueScript() {
        var l = LineLexer(file: "A.vue")
        l.feedAll("<script>")
        #expect(l.feedAll("this.x = 1").contains(T("this", .type)))
    }
}

@Suite("Lexer: CSS pseudo classes and combinators")
struct LexerStyleOperatorTests {
    @Test(arguments: ["x.css", "x.scss", "x.less"])
    func pseudoClassesAndCombinators(_ file: String) {
        let tokens = lexAll(file, "ul > li + li ~ a:hover::before, a:not(.x):first-child {")
        #expect(tokens.filter { $0.kind == .operator }.map(\.text) == [">", "+", "~", "hover", "before", "not", "first-child"])
        #expect(tokens.filter { $0.kind == .keyword }.isEmpty)
        #expect(tokens.contains(T(":", .punctuation)) && tokens.contains(T("::", .punctuation)))
    }

    @Test func valuesAndAtRulesHaveNoOperators() {
        let value = lexAll("x.scss", "a { width: calc(1px + 2px); margin: -1px; }")
        #expect(value.allSatisfy { $0.kind != .operator })
        #expect(lexAll("x.css", "@media (min-width: 1px) and (a > b) {").allSatisfy { $0.kind != .operator })
    }

    @Test func scssAmpersandStaysAKeyword() {
        #expect(lexAll("x.scss", "&:hover {").prefix(3) == [T("&", .keyword), T(":", .punctuation), T("hover", .operator)])
    }
}
