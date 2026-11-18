import MicroDiffCore
import Testing

private func kind(_ file: String, _ line: String, _ text: String, nth: Int = 0) -> TokenKind? {
    lex(file, line).filter { $0.text == text }.dropFirst(nth).first?.kind
}

@Suite("Lexer: from / as / of keywords")
struct LexerContextualKeywordTests {
    @Test(arguments: ["x.js", "x.ts", "x.tsx"])
    func keywordsInKeywordPosition(_ file: String) {
        #expect(kind(file, "import { ref } from 'vue'", "from") == .keyword)
        #expect(kind(file, "import * as x from 'y'", "as") == .keyword)
        #expect(kind(file, "import * as x from 'y'", "from") == .keyword)
        #expect(kind(file, "export { a as b }", "as") == .keyword)
        #expect(kind(file, "for (const x of list) {}", "of") == .keyword)
        #expect(kind(file, "const v = value as string", "as") == .keyword)
        #expect(kind(file, "} from 'vue'", "from") == .keyword)
    }

    @Test(arguments: ["x.js", "x.ts"])
    func ordinaryNamesStayPlain(_ file: String) {
        #expect(kind(file, "Array.from(x)", "from") == .function)
        #expect(kind(file, "Object.of", "of") == nil)
        #expect(kind(file, "a.as", "as") == nil)
        #expect(kind(file, "a. as", "as") == nil)
        #expect(kind(file, "from(x)", "from") == .function)
        #expect(kind(file, "from = 1", "from") == nil)
        #expect(kind(file, "const x = { from: 1 }", "from") == nil)
        #expect(kind(file, "fn(from, to)", "from") == nil)
        #expect(kind(file, "fn(a, from)", "from") == nil)
        #expect(kind(file, "const of = 2", "of") == nil)
        #expect(kind(file, "as;", "as") == nil)
        #expect(kind(file, "return from", "from") == nil)
        #expect(kind(file, "const { from } = x", "from") == nil)
    }

    @Test func otherLanguagesAreUntouched() {
        #expect(kind("x.rs", "let x = a as u32", "as") == .keyword)
        #expect(kind("x.py", "import a as b", "as") == .keyword)
    }

    @Test func insideVueScript() {
        var l = LineLexer(file: "A.vue")
        l.feed("<script setup lang=\"ts\">")
        #expect(l.feed("import { ref } from 'vue'").contains(T("from", .keyword)))
        #expect(l.feed("Array.from(x)").contains(T("from", .function)))
    }
}

@Suite("Lexer: TypeScript generic calls")
struct LexerGenericCallTests {
    @Test(arguments: [
        "ref<number>(0)", "ref<Message[]>([])", "computed<string | null>(() => x)",
        "defineProps<{ roomId: string }>()", "useState<Map<string, number>>(new Map())",
        "defineProps<{ onClick: () => void }>()", "this.ref<number>(0)",
    ])
    func genericCallNameIsAFunction(_ line: String) {
        let name = String(line.drop(while: { $0 != "." }).dropFirst().prefix(while: { $0 != "<" }))
        let word = line.contains(".") && line.hasPrefix("this") ? name : String(line.prefix(while: { $0 != "<" }))
        #expect(kind("x.ts", line, word) == .function, "\(line)")
        #expect(kind("x.mts", line, word) == .function)
    }

    @Test func multiLineOpenBrace() {
        var l = LineLexer(file: "x.ts")
        #expect(l.feed("const props = defineProps<{").contains(T("defineProps", .function)))
        #expect(l.feed("  roomId: string").contains(T("string", .type)))
        #expect(l.feed("}>()").isEmpty == false)
    }

    @Test(arguments: ["a < b", "a<b", "i<n;", "if (a<b) {", "x < y > (z)", "const m: Map<string, number> = x", "a<b && c>(d)"])
    func comparisonsAndTypesStayAsTheyWere(_ line: String) {
        for t in lex("x.ts", line) { #expect(t.kind != .function, "\(line): \(t)") }
    }

    @Test func capitalizedKeepsItsKind() {
        #expect(kind("x.ts", "Array<Foo>(x)", "Array") == .type)
        #expect(kind("x.ts", "const a: Array<Foo> = []", "Array") == .type)
    }

    @Test func javaScriptIsNotAffected() {
        #expect(kind("x.js", "ref<number>(0)", "ref") == nil)
        #expect(kind("x.js", "const p = defineProps<{", "defineProps") == nil)
    }

    @Test func jsxInTsxStays() {
        #expect(lex("x.tsx", "return <div>(hi)</div>").contains(T("div", .tag)))
        #expect(lex("x.tsx", "<Component />").contains(T("Component", .type)))
    }

    @Test func lookaheadIsBounded() {
        let long = "f<" + String(repeating: "a", count: 300) + ">(x)"
        #expect(kind("x.ts", long, "f") == nil)
    }

    @Test func insideVueScriptLangTs() {
        var l = LineLexer(file: "A.vue")
        l.feed("<script setup lang=\"ts\">")
        #expect(l.feed("const messages = ref<Message[]>([])").contains(T("ref", .function)))
    }
}
