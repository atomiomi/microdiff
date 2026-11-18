import MicroDiffCore
import Testing

@Suite("Lexer: code classification")
struct LexerCodeTests {
    // MARK: design samples

    @Test func rustLetStatement() {
        #expect(lex("x.rs", "        let mut tree = Tree::new();") == [
            T("let", .keyword), T("mut", .keyword), T("=", .punctuation), T("Tree", .type),
            T("::", .punctuation), T("new", .function), T("();", .punctuation),
        ])
    }

    @Test func rustMatchArm() {
        #expect(lex("x.rs", "            Key::Char('j') => Action::Down,") == [
            T("Key", .type), T("::", .punctuation), T("Char", .type), T("(", .punctuation),
            T("'j'", .string), T(")", .punctuation), T("=>", .punctuation),
            T("Action", .type), T("::", .punctuation), T("Down", .type), T(",", .punctuation),
        ])
    }

    // MARK: classification order

    @Test func keywordBuiltinTypeConstantCapitalizedFunctionPlain() {
        #expect(lex("x.rs", "fn u32 true Foo bar() baz") == [
            T("fn", .keyword), T("u32", .type), T("true", .number), T("Foo", .type),
            T("bar", .function), T("()", .punctuation),
        ])
    }

    @Test func keywordBeatsCapitalizedType() {
        // `Self` is capitalized but listed as a keyword in Rust.
        #expect(lex("x.rs", "Self") == [T("Self", .keyword)])
    }

    @Test func capitalizedIdentifierBeatsFunctionCall() {
        #expect(lex("x.swift", "Foo(1)") == [
            T("Foo", .type), T("(", .punctuation), T("1", .number), T(")", .punctuation),
        ])
    }

    @Test func functionCallAllowsSpaceBeforeParenthesis() {
        #expect(lex("x.swift", "run (1)").first == T("run", .function))
    }

    @Test func identifierWithoutParenthesisIsPlain() {
        #expect(lex("x.swift", "value other").isEmpty)
    }

    @Test func constantsAreColoredLikeNumbers() {
        #expect(lex("x.swift", "nil") == [T("nil", .number)])
        #expect(lex("x.py", "None") == [T("None", .number)])
        #expect(lex("x.js", "undefined") == [T("undefined", .number)])
    }

    @Test func languageWithoutCapitalizedTypesLeavesCapitalizedPlain() {
        #expect(lex("x.sh", "Foo bar") == [])
    }

    @Test func caseInsensitiveLanguageMatchesAnyCase() {
        #expect(lex("q.sql", "SELECT select Select") == [
            T("SELECT", .keyword), T("select", .keyword), T("Select", .keyword),
        ])
    }

    @Test func caseSensitiveLanguageDoesNotMatchOtherCase() {
        #expect(lex("x.swift", "LET").first == T("LET", .type))
        #expect(lex("x.c", "IF") == [T("IF", .type)])
    }

    @Test func rustMacroCallIncludesTheBang() {
        #expect(lex("x.rs", #"println!("hi");"#) == [
            T("println!", .function), T("(", .punctuation), T("\"hi\"", .string), T(");", .punctuation),
        ])
        #expect(lex("x.rs", "vec![1, 2]").first == T("vec!", .function))
        #expect(lex("x.rs", "thing!{}").first == T("thing!", .function))
    }

    @Test func rustBangWithoutBracketIsNotAMacro() {
        #expect(lex("x.rs", "a != b") == [T("!=", .punctuation)])
        #expect(lex("x.rs", "a!=b") == [T("!=", .punctuation)])
    }

    @Test func bangIsNotAMacroOutsideRust() {
        #expect(lex("x.swift", "foo!(1)") == [
            T("!(", .punctuation), T("1", .number), T(")", .punctuation),
        ])
    }

    @Test func adjacentPunctuationMergesButIsSplitByOtherTokens() {
        #expect(lex("x.c", "a[i]=(b);") == [T("[", .punctuation), T("]=(", .punctuation), T(");", .punctuation)])
        #expect(lex("x.c", "{ }") == [T("{", .punctuation), T("}", .punctuation)])
    }

    @Test func identifierExtrasBelongToTheIdentifier() {
        #expect(lex("x.js", "$el.foo()") == [T(".", .punctuation), T("foo", .function), T("()", .punctuation)])
        #expect(lex("x.rb", "empty?") == [])
    }

    @Test func nonASCIIIdentifierStaysWholeAndPlain() {
        #expect(lex("x.swift", "café = 日本語") == [T("=", .punctuation)])
    }

    // MARK: numbers

    @Test(arguments: ["42", "3.14", "0xFF", "1_000", "1e-3", "1E+10", "0b1010", "10px", ".5", "1.5f"])
    func numberIsOneToken(_ source: String) {
        #expect(lex("x.swift", source) == [T(source, .number)])
    }

    @Test func rangeIsTwoNumbersAndPunctuation() {
        #expect(lex("x.rs", "0..10") == [T("0", .number), T("..", .punctuation), T("10", .number)])
        #expect(lex("x.swift", "1...3") == [T("1", .number), T("...", .punctuation), T("3", .number)])
    }

    @Test func dotWithoutDigitEndsTheNumber() {
        #expect(lex("x.rs", "1.max(2)") == [
            T("1", .number), T(".", .punctuation), T("max", .function), T("(", .punctuation),
            T("2", .number), T(")", .punctuation),
        ])
    }

    @Test func hexNumberDoesNotTakeASignAfterE() {
        #expect(lex("x.c", "0x1e-3") == [T("0x1e", .number), T("-", .punctuation), T("3", .number)])
    }

    @Test func exponentSignOnlyAfterE() {
        #expect(lex("x.c", "2-3") == [T("2", .number), T("-", .punctuation), T("3", .number)])
    }

    @Test func tupleAccessIsAPunctuationDotAndANumber() {
        #expect(lex("x.rs", "x.1") == [T(".", .punctuation), T("1", .number)])
        #expect(lex("x.rs", "f(a)[0].1") == [
            T("f", .function), T("(", .punctuation), T(")[", .punctuation), T("0", .number),
            T("].", .punctuation), T("1", .number),
        ])
    }

    @Test func leadingDotNumberAfterAnOperatorOrOpeningBracket() {
        #expect(lex("x.js", "x = .5") == [T("=", .punctuation), T(".5", .number)])
        #expect(lex("x.js", "f(.5)") == [T("f", .function), T("(", .punctuation), T(".5", .number), T(")", .punctuation)])
    }

    @Test func digitsInsideAnIdentifierAreNotANumber() {
        #expect(lex("x.swift", "x1 y2z").isEmpty)
    }

    // MARK: attributes and directives

    @Test func attributesAreKeywordsInSwiftPythonJava() {
        #expect(lex("x.swift", "@objc func f() {}") == [
            T("@objc", .keyword), T("func", .keyword), T("f", .function), T("()", .punctuation), T("{}", .punctuation),
        ])
        #expect(lex("x.py", "@property").first == T("@property", .keyword))
        #expect(lex("x.java", "@Override") == [T("@Override", .keyword)])
    }

    @Test func atSignIsASigilInRubyShellPerlPHP() {
        #expect(lex("x.rb", "@ivar = 1") == [T("@", .punctuation), T("=", .punctuation), T("1", .number)])
        #expect(lex("x.rb", "@Foo") == [T("@", .punctuation), T("Foo", .type)])
        #expect(lex("x.pl", "@list").first == T("@", .punctuation))
    }

    @Test func atFollowedByNonLetterIsPunctuation() {
        #expect(lex("x.swift", "@ 1") == [T("@", .punctuation), T("1", .number)])
    }

    @Test func hashDirectivesAreKeywordsInCAndSwift() {
        #expect(lex("x.c", "#include <stdio.h>").first == T("#include", .keyword))
        #expect(lex("x.c", "#define N 3").prefix(2) == [T("#define", .keyword), T("N", .type)])
        #expect(lex("x.swift", "#if DEBUG") == [T("#if", .keyword), T("DEBUG", .type)])
    }

    @Test func hashBeforeNonLetterIsPunctuation() {
        #expect(lex("x.rs", "#[derive(Debug)]") == [
            T("#[", .punctuation), T("derive", .function), T("(", .punctuation), T("Debug", .type), T(")]", .punctuation),
        ])
    }

    @Test func hashIsNeverADirectiveInLanguagesWithHashComments() {
        // In Python `#include` is a comment; mid-line after a value it is not even a keyword.
        #expect(lex("x.py", "x #include") == [T("#include", .comment)])
    }

    // MARK: other languages

    @Test func pythonDefinition() {
        #expect(lex("x.py", "def add(self, x: int) -> bool:") == [
            T("def", .keyword), T("add", .function), T("(", .punctuation), T("self", .keyword), T(",", .punctuation),
            T(":", .punctuation), T("int", .type), T(")", .punctuation), T("->", .punctuation),
            T("bool", .type), T(":", .punctuation),
        ])
    }

    @Test func goFunction() {
        #expect(lex("x.go", "func main() { x := 1 }") == [
            T("func", .keyword), T("main", .function), T("()", .punctuation), T("{", .punctuation), T(":=", .punctuation),
            T("1", .number), T("}", .punctuation),
        ])
    }

    @Test func luaBlockCommentOpenerWinsOverLineComment() {
        // `--[[` must start a block comment, not a line comment, so that it can span lines.
        let lines = lex("x.lua", lines: ["--[[ one", "two ]] local x", "-- plain"])
        #expect(lines[0] == [T("--[[ one", .comment)])
        #expect(lines[1] == [T("two ]]", .comment), T("local", .keyword)])
        #expect(lines[2] == [T("-- plain", .comment)])
    }
}
