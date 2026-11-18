import MicroDiffCore
import Testing

@Suite("Indentation")
struct IndentationTests {
    @Test func aLineStartingWithATabMeansTabs() {
        #expect(Indentation.detect("func a() {\n\treturn 1\n}\n") == .tabs)
        #expect(Indentation.detect("a:\n  b: 1\n\tc: 2\n") == .tabs, "any tab-led line wins")
    }

    @Test func spacesUseTheSmallestIndent() {
        #expect(Indentation.detect("def a():\n    if b:\n        return 1\n") == .spaces(4))
        #expect(Indentation.detect("a:\n  b:\n    c: 1\n") == .spaces(2))
        #expect(Indentation.detect("x\n   three\n      six\n") == .spaces(3))
    }

    @Test func theUnitStaysWithinOneToEight() {
        #expect(Indentation.detect("x\n            twelve\n") == .spaces(8))
        #expect(Indentation.detect("/*\n * c\n */\n") == .spaces(1))
    }

    @Test func nothingIndentedMeansFourSpaces() {
        #expect(Indentation.detect("") == .spaces(4))
        #expect(Indentation.detect("a\nb\nc") == .spaces(4))
    }

    @Test func blankLinesDoNotCount() {
        #expect(Indentation.detect("a\n  \n    b\n") == .spaces(4))
        #expect(Indentation.detect("a\n \t\n  b\n") == .spaces(2), "a tab after spaces on a blank line is not a tab-led line")
        #expect(Indentation.detect("a\r\n  b\r\n") == .spaces(2))
    }

    @Test func onlyTheFirstFewHundredLinesAreLookedAt() {
        let top = String(repeating: "x\n", count: Indentation.sampleLines)
        #expect(Indentation.detect(top + "\tlate tab\n") == .spaces(4))
        #expect(Indentation.detect("  early\n" + top + "\tlate tab\n") == .spaces(2))
    }
}
