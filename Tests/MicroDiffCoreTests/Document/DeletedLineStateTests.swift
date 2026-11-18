import MicroDiffCore
import Testing

/// Deleted lines of a diff start in the lexer state the new file has where their hunk sits.
@Suite("DocumentLoader: deleted line coloring")
struct DeletedLineStateTests {
    private let vue = [
        "<script setup lang=\"ts\">", "const a = 1", "const b = 2", "</script>",
        "<template>", "  <MessageList :m=\"m\" />", "  <p>hi</p>", "</template>",
        "<style scoped lang=\"scss\">", ".chat { color: red; }", "&:hover { margin: 0 }", "</style>",
    ]

    /// Commits `old`, writes `new`, and returns the colored deleted lines in order.
    private func deleted(_ file: String, old: [String], new: [String]) throws -> [[T]] {
        let repo = TestRepo()
        repo.write(file, old.map { $0 + "\n" }.joined())
        repo.commitAll("initial")
        repo.write(file, new.map { $0 + "\n" }.joined())
        let root = RepoScanner().scan(root: repo.path).repos[0]
        let request = DocumentRequest(path: repo.path + "/" + file, repo: root, change: root.changes.first { $0.path == file }, mode: .diff)
        guard case .text(let document) = DocumentLoader().load(request), let lexer = document.lexer else {
            Issue.record("no text document")
            return []
        }
        return (0..<document.oldText.lineCount).map { line in
            slices(of: document.oldText.line(line), tokens: lexer.tokens(forLine: line, in: document.oldText, states: document.oldStates))
        }
    }

    private func without(_ lines: [String], _ index: Int) -> [String] {
        var copy = lines
        copy.remove(at: index)
        return copy
    }

    @Test func deletedScriptLineInAVueFileIsCode() throws {
        let result = try deleted("A.vue", old: vue, new: without(vue, 1))
        #expect(result.count == 1)
        #expect(result[0].contains(T("const", .keyword)) && result[0].contains(T("1", .number)))
    }

    @Test func changedScriptLineKeepsItsColorsToo() throws {
        var new = vue
        new[1] = "const a = 2"
        let result = try deleted("A.vue", old: vue, new: new)
        #expect(result[0].contains(T("const", .keyword)))
    }

    @Test func deletedStyleLineInAVueFileIsStyle() throws {
        let result = try deleted("A.vue", old: vue, new: without(vue, 9))
        #expect(result.count == 1)
        #expect(result[0].contains(T(".chat", .attribute)) && result[0].contains(T("red", .number)))
    }

    @Test func deletedTemplateLineIsMarkup() throws {
        let result = try deleted("A.vue", old: vue, new: without(vue, 5))
        #expect(result[0].contains(T("MessageList", .type)))
        #expect(!result[0].contains { $0.kind == .keyword || $0.kind == .number })
    }

    @Test func deletedLineInsideABlockComment() throws {
        let old = ["let a = 1", "/*", "  let x = 1", "  more", "*/", "let b = 2"]
        let result = try deleted("a.ts", old: old, new: without(old, 2))
        #expect(result.count == 1)
        #expect(!result[0].isEmpty && result[0].allSatisfy { $0.kind == .comment })
        // The same line outside a comment is code.
        let outside = try deleted("a.ts", old: old, new: without(old, 0))
        #expect(outside[0].contains(T("let", .keyword)))
    }

    @Test func pureDeletionAtTheTopInTheMiddleAndAtTheEnd() throws {
        let ts = ["let a = 1", "let b = 2", "/* open", "text", "let c = 3"]
        // Top.
        let top = try deleted("a.ts", old: ts, new: without(ts, 0))
        #expect(top[0].contains(T("let", .keyword)))
        // Middle: the new file is inside the comment at that place.
        let middle = try deleted("a.ts", old: ts, new: without(ts, 3))
        #expect(middle[0].isEmpty || middle[0].allSatisfy { $0.kind == .comment })
        #expect(middle[0].isEmpty == false)
        // End: the new file ends inside the comment, so the removed last line is comment text.
        let old = ["let a = 1", "/* open", "let gone = 2"]
        let end = try deleted("a.ts", old: old, new: Array(old.dropLast()))
        #expect(!end[0].isEmpty && end[0].allSatisfy { $0.kind == .comment })
        // End, but outside any comment: code.
        let plain = try deleted("a.ts", old: ["let a = 1", "let gone = 2"], new: ["let a = 1"])
        #expect(plain[0].contains(T("let", .keyword)))
    }

    @Test func pureDeletionInVueAtTheTopAndEnd() throws {
        // Top of the file: markup.
        let top = try deleted("A.vue", old: ["<template>", "<p>x</p>", "</template>"], new: ["<p>x</p>", "</template>"])
        #expect(top[0].contains(T("template", .tag)))
        // End of a file that ends inside <script>: script state.
        let old = ["<script>", "let a = 1", "let gone = 2"]
        let end = try deleted("A.vue", old: old, new: Array(old.dropLast()))
        #expect(end[0].contains(T("let", .keyword)))
    }

    @Test func severalHunksEachGetTheirOwnState() throws {
        let old = ["<template>", "<p>a</p>", "</template>", "<script>", "let a = 1", "let z = 2", "</script>", "<p>b</p>"]
        var new = old
        new.remove(at: 5)  // script line
        new.remove(at: 1)  // template line
        let result = try deleted("A.vue", old: old, new: new)
        #expect(result.count == 2)
        #expect(result[0].contains(T("p", .tag)))
        #expect(result[1].contains(T("let", .keyword)))
    }
}
