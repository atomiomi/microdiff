import Foundation
import os

/// What the lexer is in the middle of when a line ends (a block comment, a multi-line string, ...).
/// One value per line start lets any line be colored without re-reading the lines above it.
package struct LexState: Sendable, Hashable {
    package var raw: UInt32

    package static let normal = LexState(raw: 0)

    package init(raw: UInt32) {
        self.raw = raw
    }

    fileprivate enum Mode: UInt32 {
        case normal = 0
        case blockComment = 1
        case string = 2
        case markupTag = 3
        case markupComment = 4
        case fence = 5
        /// CSS: the line ended inside a declaration value that continues on the next line.
        case styleValue = 6
        /// YAML: inside a `|` or `>` block scalar; `index` is the column its owner key starts at.
        case blockScalar = 7
    }

    fileprivate init(_ mode: Mode, index: Int = 0, depth: Int = 0) {
        raw = mode.rawValue | (UInt32(truncatingIfNeeded: index & 0xFF) << 8) | (UInt32(truncatingIfNeeded: min(depth, 0xFF)) << 16)
    }

    fileprivate var mode: Mode { Mode(rawValue: raw & 0xFF) ?? .normal }
    fileprivate var index: Int { Int((raw >> 8) & 0xFF) }
    fileprivate var depth: Int { Int((raw >> 16) & 0xFF) }

    /// Which embedded language the line is inside (0 = none): the low 24 bits then hold that language's own state.
    fileprivate var region: Int { Int((raw >> 24) & 0xF) }
    fileprivate var inner: LexState { LexState(raw: raw & 0x00FF_FFFF) }
    fileprivate func inside(region: Int) -> LexState { LexState(raw: (raw & 0x00FF_FFFF) | (UInt32(region & 0xF) << 24)) }
}

/// Colors one line at a time for one language. Built once per language and shared; immutable and thread-safe.
///
/// It is a hand-written scanner over UTF-8 bytes (no grammar files, no regex), which keeps it fast
/// and small. It is approximate by design: good-looking colors, not a parser.
package final class Lexer: Sendable {
    package let definition: LanguageDefinition

    private struct Delimiter: Sendable {
        var open: [UInt8]
        var close: [UInt8]
        /// 0 = no escape character.
        var escape: UInt8
        var multiline: Bool
    }

    private let flavor: LanguageDefinition.Flavor
    /// Word hash -> TokenKind raw value.
    private let words: [UInt64: UInt8]
    private let lineComments: [[UInt8]]
    private let blockComments: [Delimiter]
    private let strings: [Delimiter]
    /// Per first byte: bit 0 = may start a line comment, bit 1 = block comment, bit 2 = string.
    private let startFlags: [UInt8]
    private let identifierExtra: [Bool]
    private let caseInsensitive: Bool
    private let capitalizedIsType: Bool
    private let nestedBlockComments: Bool
    private let atStartsKeyword: Bool
    private let hashStartsKeyword: Bool
    private let bangMacros: Bool
    private let jsLike: Bool
    private let isYAML: Bool
    /// Vue and Svelte templates: `<MessageList>` is a component (a type), `<div>` an element (a tag).
    private let componentTags: Bool
    /// TOML: commas separate values even outside brackets (multi-line arrays).
    private let splitsOnCommas: Bool
    /// JavaScript and TypeScript: `from`, `as`, `of` are keywords only in keyword position.
    private let contextualKeywords: Bool
    /// TypeScript: `name<Type>(...)` is a call.
    private let genericCalls: Bool
    /// Lexers for what sits inside `<script>` and `<style>`: JavaScript, TypeScript, CSS, SCSS, Less (regions 1...5).
    private let embedded: [Lexer]
    /// Vue templates: `{{ expression }}` is JavaScript.
    private let mustache: Bool

    package init(_ definition: LanguageDefinition) {
        self.definition = definition
        flavor = definition.flavor
        caseInsensitive = definition.caseInsensitive
        capitalizedIsType = definition.capitalizedIsType
        nestedBlockComments = definition.nestedBlockComments

        var table: [UInt64: UInt8] = [:]
        func add(_ set: Set<String>, _ kind: TokenKind) {
            for word in set {
                let bytes = Array((definition.caseInsensitive ? word.lowercased() : word).utf8)
                bytes.withUnsafeBufferPointer { table[Lexer.hash($0, 0, $0.count, lowercase: false)] = kind.rawValue }
            }
        }
        add(definition.constants, .number)
        add(definition.types, .type)
        add(definition.keywords, .keyword)
        words = table

        lineComments = definition.lineComments.map { Array($0.utf8) }.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        blockComments = definition.blockComments
            .map { Delimiter(open: Array($0.open.utf8), close: Array($0.close.utf8), escape: 0, multiline: true) }
            .filter { !$0.open.isEmpty && !$0.close.isEmpty }
        // Longest opener first so `"""` wins over `"`.
        strings = definition.strings
            .map { d in
                let escape = d.escape.flatMap { $0.asciiValue } ?? 0
                return Delimiter(open: Array(d.open.utf8), close: Array(d.close.utf8), escape: escape, multiline: d.multiline)
            }
            .filter { !$0.open.isEmpty && !$0.close.isEmpty }
            .sorted { $0.open.count > $1.open.count }

        var flags = [UInt8](repeating: 0, count: 256)
        for c in lineComments { flags[Int(c[0])] |= 1 }
        for c in blockComments { flags[Int(c.open[0])] |= 2 }
        for s in strings { flags[Int(s.open[0])] |= 4 }
        startFlags = flags

        var extra = [Bool](repeating: false, count: 256)
        for byte in definition.identifierExtras.utf8 { extra[Int(byte)] = true }
        identifierExtra = extra

        // "@" is a sigil for variables in these, not an attribute/decorator marker.
        atStartsKeyword = !["Ruby", "Perl", "PHP", "Shell", "Makefile", "PowerShell"].contains(definition.name)
        // "#include" / "#if" only where "#" is not the comment character.
        hashStartsKeyword = !definition.lineComments.contains("#")
        bangMacros = definition.name == "Rust"
        jsLike = definition.slashRegexAndTags
        isYAML = definition.name == "YAML"
        componentTags = definition.name == "Vue" || definition.name == "Svelte"
        splitsOnCommas = definition.name == "TOML"
        contextualKeywords = definition.slashRegexAndTags && (definition.name == "JavaScript" || definition.name == "TypeScript")
        genericCalls = definition.slashRegexAndTags && definition.name == "TypeScript"
        mustache = definition.embedsScriptAndStyle && definition.name == "Vue"
        if definition.embedsScriptAndStyle {
            let inner = ["a.js", "a.ts", "a.css", "a.scss", "a.less"].compactMap { LanguageRegistry.language(forFileName: $0) }
            // None of these embed anything themselves, so this cannot recurse.
            embedded = inner.count == 5 && !inner.contains(where: \.embedsScriptAndStyle) ? inner.map(Lexer.init) : []
        } else {
            embedded = []
        }
    }

    // MARK: - Public API

    /// Colors one line. `bytes` is the UTF-8 of the line without its terminator.
    /// Returns only the non-plain spans, sorted, never overlapping, as UTF-16 offsets.
    /// `state` goes in as the state at the start of the line and comes out as the state at its end.
    package func tokenize(_ bytes: UnsafeBufferPointer<UInt8>, state: inout LexState) -> [SyntaxToken] {
        var sink = Sink(enabled: true)
        scan(bytes, state: &state, sink: &sink)
        if !sink.tokens.isEmpty, Lexer.hasNonASCII(bytes) {
            Lexer.convertToUTF16(&sink.tokens, bytes)
        }
        return sink.tokens
    }

    /// Same as `tokenize` but only tracks the state. Used to walk over lines that are not on screen.
    package func advance(_ bytes: UnsafeBufferPointer<UInt8>, state: inout LexState) {
        var sink = Sink(enabled: false)
        scan(bytes, state: &state, sink: &sink)
    }

    /// The state at the start of every line of `buffer`. Each reset line starts in the given state instead of
    /// carrying on. `resets` must be sorted by line. Used for the deleted lines of a diff: each hunk starts in
    /// the state the new file has at the place where the hunk sits.
    package func startStates(for buffer: TextBuffer, resets: [(line: Int, state: LexState)] = []) -> [LexState] {
        let count = buffer.lineCount
        guard count > 0, flavor != .plain else { return [] }
        var states = [LexState](repeating: .normal, count: count)
        var state = LexState.normal
        var iterator = resets.makeIterator()
        var nextReset = iterator.next()
        var anyCarried = false
        for line in 0..<count {
            while let r = nextReset, r.line <= line {
                if r.line == line { state = r.state }
                nextReset = iterator.next()
            }
            states[line] = state
            if state != .normal { anyCarried = true }
            buffer.withLineBytes(line) { advance($0, state: &state) }
        }
        // Most files never carry state across lines; an empty array then means "always normal".
        return anyCarried ? states : []
    }

    /// The state at the start of `line`, or after the last line when `line == buffer.lineCount`.
    /// `states` is what `startStates` returned for `buffer` (empty means every line starts normal).
    package func state(atLine line: Int, in buffer: TextBuffer, states: [LexState]) -> LexState {
        guard line > 0, flavor != .plain, line <= buffer.lineCount else { return .normal }
        if line < buffer.lineCount { return line < states.count ? states[line] : .normal }
        // After the last line: run it once from its own start state (all normal when `states` is empty).
        var state = line - 1 < states.count ? states[line - 1] : LexState.normal
        buffer.withLineBytes(line - 1) { advance($0, state: &state) }
        return state
    }

    package func tokens(forLine line: Int, in buffer: TextBuffer, states: [LexState]) -> [SyntaxToken] {
        guard flavor != .plain, line >= 0, line < buffer.lineCount else { return [] }
        var state = line < states.count ? states[line] : .normal
        return buffer.withLineBytes(line) { tokenize($0, state: &state) }
    }

    // MARK: - Shared lexers

    private static let cache = OSAllocatedUnfairLock<[String: Lexer]>(initialState: [:])

    /// The shared lexer for a file name, or nil when the language is unknown or has nothing to color.
    package static func forFileName(_ fileName: String) -> Lexer? {
        guard let definition = LanguageRegistry.language(forFileName: fileName), definition.flavor != .plain else { return nil }
        return cache.withLock { cache in
            if let existing = cache[definition.name] { return existing }
            let lexer = Lexer(definition)
            cache[definition.name] = lexer
            return lexer
        }
    }

    // MARK: - Scanning

    private struct Sink {
        var tokens: [SyntaxToken] = []
        var enabled: Bool

        @inline(__always)
        mutating func emit(_ start: Int, _ end: Int, _ kind: TokenKind) {
            guard enabled, end > start else { return }
            // Runs of punctuation (or of operators) become one token: fewer spans to draw.
            if kind == .punctuation || kind == .operator, let last = tokens.last, last.kind == kind, last.start + last.length == start {
                tokens[tokens.count - 1].length += end - start
            } else {
                tokens.append(SyntaxToken(start: start, length: end - start, kind: kind))
            }
        }
    }

    private func scan(_ p: UnsafeBufferPointer<UInt8>, state: inout LexState, sink: inout Sink) {
        switch flavor {
        case .plain:
            state = .normal
        case .code, .json:
            scanCode(p, state: &state, sink: &sink)
        case .css:
            scanStyle(p, state: &state, sink: &sink)
        case .markup:
            scanMarkup(p, state: &state, sink: &sink)
        case .keyValue:
            scanKeyValue(p, state: &state, sink: &sink)
        case .markdown:
            scanMarkdown(p, state: &state, sink: &sink)
        }
    }

    // MARK: Code

    private func scanCode(_ p: UnsafeBufferPointer<UInt8>, state: inout LexState, sink: inout Sink) {
        let n = p.count
        var i = 0

        // Finish whatever the previous line left open.
        switch state.mode {
        case .blockComment where state.index < blockComments.count:
            let end = scanBlockComment(p, from: 0, index: state.index, depth: max(1, state.depth), state: &state)
            sink.emit(0, end, .comment)
            i = end
        case .string where state.index < strings.count:
            let end = scanString(p, from: 0, index: state.index, state: &state)
            sink.emit(0, end, .string)
            i = end
        default:
            state = .normal
        }

        // JavaScript family: whether the last thing was a value, which decides if "/" divides and "<" compares.
        var afterValue = false
        // JSX on this line: inside an opening tag (outside `{...}` and strings) names are attributes. Tags that
        // continue on the next line are not followed.
        var inJSXTag = false
        var jsxClosing = false
        var jsxBraces = 0
        while i < n {
            let c = p[i]
            if c == 0x20 || c == 0x09 {
                i += 1
                continue
            }
            if jsLike {
                if c == UInt8(ascii: "/"), !afterValue, let end = regexLiteralEnd(p, i) {
                    sink.emit(i, end, .string)
                    afterValue = true
                    i = end
                    continue
                }
                if c == UInt8(ascii: "<"), let (nameStart, nameEnd) = jsxTagName(p, i, afterValue: afterValue) {
                    sink.emit(i, nameStart, .punctuation)
                    // Lowercase names are HTML elements, capitalized ones are components.
                    sink.emit(nameStart, nameEnd, p[nameStart] >= 65 && p[nameStart] <= 90 ? .type : .tag)
                    afterValue = true
                    inJSXTag = true
                    jsxClosing = p[i + 1] == UInt8(ascii: "/")
                    jsxBraces = 0
                    i = nameEnd
                    continue
                }
            }

            let flags = startFlags[Int(c)]
            if flags != 0 {
                // Block comments first: Lua's `--[[` must not be taken for the line comment `--`.
                if flags & 2 != 0, let k = blockComments.firstIndex(where: { Lexer.matches($0.open, p, i) }) {
                    let end = scanBlockComment(p, from: i + blockComments[k].open.count, index: k, depth: 1, state: &state)
                    sink.emit(i, end, .comment)
                    i = end
                    continue
                }
                if flags & 1 != 0, let comment = lineComments.first(where: { Lexer.matches($0, p, i) }), Lexer.isCommentStart(comment, p, i) {
                    sink.emit(i, n, .comment)
                    return
                }
                if flags & 4 != 0, let k = strings.firstIndex(where: { Lexer.matches($0.open, p, i) }) {
                    let d = strings[k]
                    if d.open.count == 1, d.open[0] == 0x27, !d.multiline {
                        // A lone apostrophe (Rust lifetime, Haskell prime, plain English) is not a string:
                        // only color it when it really closes on this line.
                        if let end = apostropheStringEnd(p, i, escape: d.escape) {
                            sink.emit(i, end, .string)
                            i = end
                        } else if bangMacros, i + 1 < n, Lexer.isIdentifierStart(p[i + 1]) {
                            var j = i + 2
                            while j < n, Lexer.isIdentifierPart(p[j]) { j += 1 }
                            sink.emit(i, j, .keyword)
                            i = j
                        } else {
                            sink.emit(i, i + 1, .punctuation)
                            i += 1
                        }
                        continue
                    }
                    let end = scanString(p, from: i + strings[k].open.count, index: k, state: &state)
                    var kind = TokenKind.string
                    if flavor == .json, Lexer.nextNonSpace(p, end) == UInt8(ascii: ":") {
                        kind = .variable
                    }
                    sink.emit(i, end, kind)
                    afterValue = true
                    i = end
                    continue
                }
            }

            // A leading dot starts a number (`.5`) unless it follows a value: `0..10` is a range, `t.1` a tuple access.
            if Lexer.isDigit(c) || (c == UInt8(ascii: ".") && i + 1 < n && Lexer.isDigit(p[i + 1]) && !Lexer.endsValue(p, before: i)) {
                let end = scanNumber(p, from: i)
                sink.emit(i, end, .number)
                afterValue = true
                i = end
                continue
            }

            if Lexer.isIdentifierStart(c) || (c == UInt8(ascii: "$") && identifierExtra[Int(c)]) {
                var j = i + 1
                while j < n, Lexer.isIdentifierPart(p[j]) || identifierExtra[Int(p[j])] { j += 1 }
                afterValue = true
                if inJSXTag, !jsxClosing, jsxBraces == 0 {
                    sink.emit(i, j, .attribute)
                    afterValue = false
                } else if let raw = words[Lexer.hash(p, i, j, lowercase: caseInsensitive)], let kind = TokenKind(rawValue: raw) {
                    sink.emit(i, j, kind)
                    // After `return`, `typeof`, `case` ... a value starts.
                    if kind == .keyword { afterValue = false }
                } else if capitalizedIsType, c >= 65, c <= 90 {
                    sink.emit(i, j, .type)
                } else if bangMacros, j + 1 < n, p[j] == UInt8(ascii: "!"), p[j + 1] == UInt8(ascii: "(") || p[j + 1] == UInt8(ascii: "[") || p[j + 1] == UInt8(ascii: "{") {
                    j += 1
                    sink.emit(i, j, .function)
                } else if Lexer.nextNonSpace(p, j) == UInt8(ascii: "(") {
                    sink.emit(i, j, .function)
                } else if contextualKeywords, Lexer.isContextualKeyword(p, i, j) {
                    sink.emit(i, j, .keyword)
                    afterValue = false
                } else if genericCalls, j < n, p[j] == UInt8(ascii: "<"), Lexer.startsGenericCall(p, j) {
                    sink.emit(i, j, .function)
                } else if flavor == .code {
                    sink.emit(i, j, .variable)
                }
                i = j
                continue
            }

            // Attributes / decorators (@objc, @Override) and directives (#include, #if).
            if (c == UInt8(ascii: "@") && atStartsKeyword) || (c == UInt8(ascii: "#") && hashStartsKeyword), i + 1 < n, Lexer.isLetter(p[i + 1]) {
                var j = i + 1
                while j < n, Lexer.isIdentifierPart(p[j]) { j += 1 }
                sink.emit(i, j, .keyword)
                afterValue = false
                i = j
                continue
            }

            if c < 0x80 {
                if flavor == .code, !(inJSXTag && jsxBraces == 0), let length = Lexer.operatorLength(p, i, breaksAtSlashAndAngle: jsLike) {
                    var start = i
                    // JavaScript and TypeScript arrow: colored like `function`.
                    if jsLike, p[i] == UInt8(ascii: "="), length >= 2, p[i + 1] == UInt8(ascii: ">") {
                        sink.emit(i, i + 2, .keyword)
                        start = i + 2
                    }
                    sink.emit(start, i + length, .operator)
                    afterValue = false
                    i += length
                    continue
                }
                sink.emit(i, i + 1, .punctuation)
            }
            afterValue = c == UInt8(ascii: ")") || c == UInt8(ascii: "]")
            if inJSXTag {
                if c == UInt8(ascii: "{") {
                    jsxBraces += 1
                } else if c == UInt8(ascii: "}") {
                    jsxBraces = max(0, jsxBraces - 1)
                } else if c == UInt8(ascii: ">"), jsxBraces == 0 {
                    inJSXTag = false
                    afterValue = true
                }
            }
            i += 1
        }
    }

    /// Index just past a regular expression literal that starts at `i`, or nil when the slash is not one.
    private func regexLiteralEnd(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int? {
        let n = p.count
        guard i + 1 < n else { return nil }
        let next = p[i + 1]
        // "//" and "/*" are comments, "/>" closes a JSX tag, "</" opens a closing tag.
        if next == UInt8(ascii: "/") || next == UInt8(ascii: "*") || next == UInt8(ascii: ">") || next == 0x20 { return nil }
        // "<" before: `</`. "/" before: the second slash of a `//` that is not a comment (`http://x`).
        if i > 0, p[i - 1] == UInt8(ascii: "<") || p[i - 1] == UInt8(ascii: "/") { return nil }
        var j = i + 1
        var inClass = false
        while j < n {
            let c = p[j]
            if c == UInt8(ascii: "\\") {
                j += 2
                continue
            }
            if c == UInt8(ascii: "[") {
                inClass = true
            } else if c == UInt8(ascii: "]") {
                inClass = false
            } else if c == UInt8(ascii: "/"), !inClass {
                j += 1
                while j < n, Lexer.isLetter(p[j]) { j += 1 }
                return j
            }
            j += 1
        }
        return nil
    }

    /// When "<" at `i` opens a JSX tag: the byte range of the tag name. Nil for comparisons and generics.
    private func jsxTagName(_ p: UnsafeBufferPointer<UInt8>, _ i: Int, afterValue: Bool) -> (start: Int, end: Int)? {
        let n = p.count
        var start = i + 1
        let isClosing = start < n && p[start] == UInt8(ascii: "/")
        if isClosing { start += 1 }
        guard start < n, Lexer.isLetter(p[start]) else { return nil }
        var end = start + 1
        while end < n, Lexer.isIdentifierPart(p[end]) || p[end] == UInt8(ascii: ".") || p[end] == UInt8(ascii: "-") { end += 1 }
        // "</name>" is a closing tag wherever it stands; "<name" only where a value may start ("a < b" is a comparison).
        if isClosing { return end < n && p[end] == UInt8(ascii: ">") ? (start, end) : nil }
        return afterValue ? nil : (start, end)
    }

    /// Returns the index just past the comment's end on this line; `p.count` when it stays open.
    private func scanBlockComment(_ p: UnsafeBufferPointer<UInt8>, from: Int, index: Int, depth startDepth: Int, state: inout LexState) -> Int {
        let n = p.count
        let d = blockComments[index]
        var depth = startDepth
        var j = from
        while j < n {
            if Lexer.matches(d.close, p, j) {
                depth -= 1
                j += d.close.count
                if depth == 0 {
                    state = .normal
                    return j
                }
            } else if nestedBlockComments, Lexer.matches(d.open, p, j) {
                depth += 1
                j += d.open.count
            } else {
                j += 1
            }
        }
        state = LexState(.blockComment, index: index, depth: depth)
        return n
    }

    private func scanString(_ p: UnsafeBufferPointer<UInt8>, from: Int, index: Int, state: inout LexState) -> Int {
        let n = p.count
        let d = strings[index]
        var j = from
        while j < n {
            if d.escape != 0, p[j] == d.escape {
                j += 2
            } else if Lexer.matches(d.close, p, j) {
                state = .normal
                return j + d.close.count
            } else {
                j += 1
            }
        }
        state = d.multiline ? LexState(.string, index: index) : .normal
        return n
    }

    /// Index just past a closed single-quoted literal that starts at `i`, or nil when the apostrophe is not a literal.
    private func apostropheStringEnd(_ p: UnsafeBufferPointer<UInt8>, _ i: Int, escape: UInt8) -> Int? {
        let n = p.count
        guard i + 1 < n else { return nil }
        if bangMacros {
            // Rust: 'x' or '\n' is a char; 'a without a closing quote right after is a lifetime.
            if p[i + 1] == UInt8(ascii: "\\") {
                var j = i + 3
                while j < n, p[j] != 0x27 { j += 1 }
                return j < n ? j + 1 : nil
            }
            let lead = p[i + 1]
            let length = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2
            let close = i + 1 + length
            return close < n && p[close] == 0x27 ? close + 1 : nil
        }
        var j = i + 1
        while j < n {
            if escape != 0, p[j] == escape {
                j += 2
            } else if p[j] == 0x27 {
                return j + 1
            } else {
                j += 1
            }
        }
        return nil
    }

    private func scanNumber(_ p: UnsafeBufferPointer<UInt8>, from: Int) -> Int {
        let n = p.count
        let isHex = from + 1 < n && p[from] == UInt8(ascii: "0") && (p[from + 1] | 0x20) == UInt8(ascii: "x")
        var j = from + 1
        while j < n {
            let d = p[j]
            if Lexer.isLetter(d) || Lexer.isDigit(d) || d == UInt8(ascii: "_") {
                j += 1
            } else if d == UInt8(ascii: "."), j + 1 < n, Lexer.isDigit(p[j + 1]) {
                // A dot only belongs to the number when a digit follows, so `0..10` and `1.foo()` stay intact.
                j += 1
            } else if !isHex, d == UInt8(ascii: "+") || d == UInt8(ascii: "-"), (p[j - 1] | 0x20) == UInt8(ascii: "e") {
                j += 1
            } else {
                break
            }
        }
        return j
    }

    // MARK: Style (CSS / SCSS / Less)

    private enum StyleContext {
        /// Before the first token of a statement: decided by looking ahead on the same line.
        case start
        case selector
        /// A declaration before its colon: the property name (left plain).
        case declaration
        case value
        case atRule
    }

    /// Whether the statement starting at `start` is a selector or a declaration.
    ///
    /// Looks ahead on the same line (outside strings, comments, parentheses and `#{...}`) for the first terminator:
    /// `{` means selector, `;` or `}` means declaration. When the line ends first: `prop: value` (a colon followed by
    /// a space) means declaration, a trailing `,` means a selector list that goes on, otherwise a `:` anywhere
    /// means declaration and no colon means selector.
    /// So `a:hover` alone on a line (opening brace on the next line) reads as a declaration.
    private func styleStatement(_ p: UnsafeBufferPointer<UInt8>, at start: Int) -> StyleContext {
        let n = p.count
        if p[start] == UInt8(ascii: "@") { return .atRule }
        var k = start
        var depth = 0
        var sawColon = false
        var sawSpacedColon = false
        var last: UInt8 = 0
        scan: while k < n {
            let c = p[k]
            switch c {
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                k += 1
                while k < n, p[k] != c { k += p[k] == UInt8(ascii: "\\") ? 2 : 1 }
            case UInt8(ascii: "/") where k + 1 < n && p[k + 1] == UInt8(ascii: "*"):
                guard let close = Lexer.find([0x2A, 0x2F], p, from: k + 2) else { break scan }
                k = close + 1
                last = UInt8(ascii: "/")
            case UInt8(ascii: "/") where k + 1 < n && p[k + 1] == UInt8(ascii: "/") && !lineComments.isEmpty && (k == 0 || p[k - 1] != UInt8(ascii: ":")):
                break scan
            case UInt8(ascii: "("):
                depth += 1
            case UInt8(ascii: ")"):
                depth = max(0, depth - 1)
            case UInt8(ascii: "#") where k + 1 < n && p[k + 1] == UInt8(ascii: "{"):
                var braces = 0
                while k < n {
                    if p[k] == UInt8(ascii: "{") { braces += 1 } else if p[k] == UInt8(ascii: "}") {
                        braces -= 1
                        if braces == 0 { break }
                    }
                    k += 1
                }
            case UInt8(ascii: "{") where depth == 0:
                return .selector
            case UInt8(ascii: ";") where depth == 0, UInt8(ascii: "}") where depth == 0:
                return .declaration
            case UInt8(ascii: ":") where depth == 0:
                sawColon = true
                if k + 1 == n || p[k + 1] == 0x20 || p[k + 1] == 0x09 { sawSpacedColon = true }
            default:
                break
            }
            if p[min(k, n - 1)] != 0x20, p[min(k, n - 1)] != 0x09 { last = p[min(k, n - 1)] }
            k += 1
        }
        if sawSpacedColon { return .declaration }
        if last == UInt8(ascii: ",") { return .selector }
        return sawColon ? .declaration : .selector
    }

    private func scanStyle(_ p: UnsafeBufferPointer<UInt8>, state: inout LexState, sink: inout Sink) {
        let n = p.count
        var i = 0
        var ctx = StyleContext.start
        var codeEnd = n
        var parens = 0
        var brackets = 0
        var interpolation = 0

        switch state.mode {
        case .blockComment where state.index < blockComments.count:
            let end = scanBlockComment(p, from: 0, index: state.index, depth: max(1, state.depth), state: &state)
            sink.emit(0, end, .comment)
            i = end
        case .styleValue:
            ctx = .value
            state = .normal
        default:
            state = .normal
        }
        // A value that clearly goes on (the line ends with `,` `:` or `(`) is carried to the next line.
        defer {
            if state.mode == .normal, ctx == .value, codeEnd > 0 {
                var k = codeEnd - 1
                while k >= 0, p[k] == 0x20 || p[k] == 0x09 { k -= 1 }
                if k >= 0, p[k] == UInt8(ascii: ",") || p[k] == UInt8(ascii: ":") || p[k] == UInt8(ascii: "(") {
                    state = LexState(.styleValue)
                }
            }
        }

        while i < n {
            let c = p[i]
            if c == 0x20 || c == 0x09 {
                i += 1
                continue
            }
            let flags = startFlags[Int(c)]
            if flags & 2 != 0, let k = blockComments.firstIndex(where: { Lexer.matches($0.open, p, i) }) {
                let end = scanBlockComment(p, from: i + blockComments[k].open.count, index: k, depth: 1, state: &state)
                sink.emit(i, end, .comment)
                i = end
                continue
            }
            if flags & 1 != 0, let comment = lineComments.first(where: { Lexer.matches($0, p, i) }), Lexer.isCommentStart(comment, p, i) {
                codeEnd = i
                sink.emit(i, n, .comment)
                return
            }
            if ctx == .start, c != UInt8(ascii: "{"), c != UInt8(ascii: "}"), c != UInt8(ascii: ";") {
                ctx = styleStatement(p, at: i)
            }
            if flags & 4 != 0, let k = strings.firstIndex(where: { Lexer.matches($0.open, p, i) }) {
                let end = scanString(p, from: i + strings[k].open.count, index: k, state: &state)
                sink.emit(i, end, .string)
                i = end
                continue
            }

            if Lexer.isDigit(c) || (c == UInt8(ascii: ".") && ctx != .selector && i + 1 < n && Lexer.isDigit(p[i + 1]) && !Lexer.endsValue(p, before: i)) {
                let end = scanNumber(p, from: i)
                sink.emit(i, end, .number)
                i = end
                continue
            }

            // `$variable` and `--custom-property`.
            if (c == UInt8(ascii: "$") && i + 1 < n && Lexer.isIdentifierStart(p[i + 1]))
                || (c == UInt8(ascii: "-") && i + 2 < n && p[i + 1] == UInt8(ascii: "-") && Lexer.isIdentifierPart(p[i + 2])) {
                var j = i + 1
                while j < n, Lexer.isIdentifierPart(p[j]) || p[j] == UInt8(ascii: "-") { j += 1 }
                sink.emit(i, j, .variable)
                i = j
                continue
            }

            if Lexer.isIdentifierStart(c) || (c == UInt8(ascii: "-") && i + 1 < n && Lexer.isIdentifierStart(p[i + 1])) {
                var j = i + 1
                while j < n, Lexer.isIdentifierPart(p[j]) || identifierExtra[Int(p[j])] { j += 1 }
                switch ctx {
                case .selector:
                    if parens == 0 { sink.emit(i, j, brackets > 0 ? .attribute : .tag) }
                case .value:
                    if j < n, p[j] == UInt8(ascii: "(") {
                        sink.emit(i, j, .function)
                        // `url(foo.png)`: the unquoted address is a string.
                        if j - i == 3, p[i] | 0x20 == UInt8(ascii: "u"), p[i + 1] | 0x20 == UInt8(ascii: "r"), p[i + 2] | 0x20 == UInt8(ascii: "l") {
                            let open = j + 1
                            let first = Lexer.skipSpaces(p, open)
                            if first < n, p[first] != UInt8(ascii: "\""), p[first] != UInt8(ascii: "'"), p[first] != UInt8(ascii: ")") {
                                var close = first
                                while close < n, p[close] != UInt8(ascii: ")") { close += 1 }
                                var end = close
                                while end > first, p[end - 1] == 0x20 || p[end - 1] == 0x09 { end -= 1 }
                                sink.emit(open, j + 1, .punctuation)
                                sink.emit(first, end, .string)
                                i = end
                                continue
                            }
                        }
                    } else {
                        sink.emit(i, j, .number)
                    }
                case .atRule:
                    if j < n, p[j] == UInt8(ascii: "(") { sink.emit(i, j, .function) }
                case .declaration, .start:
                    break
                }
                i = j
                continue
            }

            switch c {
            case UInt8(ascii: "@") where atStartsKeyword && i + 1 < n && Lexer.isLetter(p[i + 1]):
                var j = i + 1
                while j < n, Lexer.isIdentifierPart(p[j]) || p[j] == UInt8(ascii: "-") { j += 1 }
                sink.emit(i, j, .keyword)
                // Less `@color: red;` is a declaration, not an at-rule.
                if ctx == .atRule, j < n, p[j] == UInt8(ascii: ":") { ctx = .value }
                i = j
                continue
            case UInt8(ascii: "&") where ctx == .selector:
                var j = i + 1
                while j < n, Lexer.isIdentifierPart(p[j]) || p[j] == UInt8(ascii: "-") { j += 1 }
                sink.emit(i, j, .keyword)
                i = j
                continue
            case UInt8(ascii: ".") where ctx == .selector && i + 1 < n && (Lexer.isIdentifierStart(p[i + 1]) || p[i + 1] == UInt8(ascii: "-")):
                var j = i + 1
                while j < n, Lexer.isIdentifierPart(p[j]) || identifierExtra[Int(p[j])] { j += 1 }
                sink.emit(i, j, .attribute)
                i = j
                continue
            case UInt8(ascii: "#"):
                if i + 1 < n, p[i + 1] == UInt8(ascii: "{") {
                    sink.emit(i, i + 2, .punctuation)
                    interpolation += 1
                    i += 2
                    continue
                }
                if i + 1 < n, Lexer.isIdentifierPart(p[i + 1]) || p[i + 1] == UInt8(ascii: "-") {
                    var j = i + 1
                    while j < n, Lexer.isIdentifierPart(p[j]) || p[j] == UInt8(ascii: "-") { j += 1 }
                    if ctx == .value {
                        // 3, 4, 6 or 8 hex digits: `#fff`, `#6caeef`, `#6caeef80`.
                        let digits = j - i - 1
                        if digits == 3 || digits == 4 || digits == 6 || digits == 8, (i + 1..<j).allSatisfy({ Lexer.isHexDigit(p[$0]) }) {
                            sink.emit(i, j, .number)
                        }
                    } else {
                        sink.emit(i, j, .function)
                    }
                    i = j
                    continue
                }
            case UInt8(ascii: ":"):
                if ctx == .selector {
                    var j = i + 1
                    if j < n, p[j] == UInt8(ascii: ":") { j += 1 }
                    sink.emit(i, j, .punctuation)
                    var end = j
                    while end < n, Lexer.isIdentifierPart(p[end]) || identifierExtra[Int(p[end])] { end += 1 }
                    if end > j { sink.emit(j, end, .operator) }
                    i = end
                    continue
                }
                if ctx == .declaration { ctx = .value }
            case UInt8(ascii: ">"), UInt8(ascii: "+"), UInt8(ascii: "~"):
                // Combinators in selectors.
                if ctx == .selector {
                    sink.emit(i, i + 1, .operator)
                    i += 1
                    continue
                }
            case UInt8(ascii: "!"):
                var j = i + 1
                while j < n, Lexer.isLetter(p[j]) { j += 1 }
                if j > i + 1 {
                    sink.emit(i, j, .keyword)
                    i = j
                    continue
                }
            case UInt8(ascii: "{"):
                ctx = .start
                parens = 0
                brackets = 0
            case UInt8(ascii: "}"):
                if interpolation > 0 { interpolation -= 1 } else { ctx = .start }
            case UInt8(ascii: ";"):
                ctx = .start
                parens = 0
                brackets = 0
            case UInt8(ascii: "("):
                parens += 1
            case UInt8(ascii: ")"):
                parens = max(0, parens - 1)
            case UInt8(ascii: "["):
                brackets += 1
            case UInt8(ascii: "]"):
                brackets = max(0, brackets - 1)
            default:
                break
            }
            if c < 0x80 { sink.emit(i, i + 1, .punctuation) }
            i += 1
        }
    }

    // MARK: Markup (HTML / XML)

    private func scanMarkup(_ p: UnsafeBufferPointer<UInt8>, state: inout LexState, sink: inout Sink) {
        let n = p.count
        var i = 0

        // Inside <script> or <style>: the other language colors the line, up to the closing tag.
        if state.region != 0, state.region <= embedded.count {
            let region = state.region
            let end = Lexer.findClosingTag(region <= 2 ? Lexer.scriptName : Lexer.styleName, p, from: 0) ?? n
            var inner = state.inner
            scanEmbedded(region, p, from: 0, to: end, state: &inner, sink: &sink)
            if end == n {
                state = inner.inside(region: region)
                return
            }
            state = .normal
            i = end
        }

        var mode = state.mode
        if mode != .markupTag, mode != .markupComment { mode = .normal }
        // The region to enter when the tag being read closes (a <script> or <style> opening tag).
        var pending = mode == .markupTag ? state.index : 0
        var expectLanguage = false

        while i < n {
            switch mode {
            case .markupComment:
                if let end = Lexer.find([0x2D, 0x2D, 0x3E], p, from: i) {
                    sink.emit(i, end + 3, .comment)
                    i = end + 3
                    mode = .normal
                } else {
                    sink.emit(i, n, .comment)
                    i = n
                }
            case .markupTag:
                let c = p[i]
                if c == 0x20 || c == 0x09 {
                    i += 1
                } else if c == UInt8(ascii: ">") {
                    sink.emit(i, i + 1, .punctuation)
                    i += 1
                    mode = .normal
                    if pending != 0, pending <= embedded.count {
                        let region = pending
                        pending = 0
                        let end = Lexer.findClosingTag(region <= 2 ? Lexer.scriptName : Lexer.styleName, p, from: i) ?? n
                        var inner = LexState.normal
                        scanEmbedded(region, p, from: i, to: end, state: &inner, sink: &sink)
                        if end == n {
                            state = inner.inside(region: region)
                            return
                        }
                        i = end
                    }
                } else if c == UInt8(ascii: "/"), i + 1 < n, p[i + 1] == UInt8(ascii: ">") {
                    sink.emit(i, i + 2, .punctuation)
                    i += 2
                    mode = .normal
                    pending = 0
                } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                    var j = i + 1
                    while j < n, p[j] != c { j += 1 }
                    let end = min(j + 1, n)
                    if expectLanguage, pending != 0 {
                        pending = Lexer.region(forLanguage: p, i + 1, j, current: pending)
                    }
                    expectLanguage = false
                    sink.emit(i, end, .string)
                    i = end
                } else if Lexer.isMarkupNameChar(c) {
                    var j = i + 1
                    while j < n, Lexer.isMarkupNameChar(p[j]) { j += 1 }
                    sink.emit(i, j, .attribute)
                    expectLanguage = pending != 0 && Lexer.equalsIgnoringCase(Lexer.langName, p, i, j)
                    i = j
                } else {
                    if c < 0x80 { sink.emit(i, i + 1, .punctuation) }
                    i += 1
                }
            default:
                let open = Lexer.find([UInt8(ascii: "<")], p, from: i) ?? n
                if mustache, let start = Lexer.find([0x7B, 0x7B], p, from: i), start < open {
                    // {{ expression }}
                    sink.emit(start, start + 2, .punctuation)
                    let close = Lexer.find([0x7D, 0x7D], p, from: start + 2) ?? n
                    var inner = LexState.normal
                    scanEmbedded(1, p, from: start + 2, to: close, state: &inner, sink: &sink)
                    sink.emit(close, min(close + 2, n), .punctuation)
                    i = min(close + 2, n)
                    continue
                }
                guard open < n else {
                    i = n
                    break
                }
                i = open
                if Lexer.matches([0x3C, 0x21, 0x2D, 0x2D], p, i) {
                    if let end = Lexer.find([0x2D, 0x2D, 0x3E], p, from: i + 4) {
                        sink.emit(i, end + 3, .comment)
                        i = end + 3
                    } else {
                        sink.emit(i, n, .comment)
                        i = n
                        mode = .markupComment
                    }
                } else if i + 1 < n, Lexer.isLetter(p[i + 1]) || p[i + 1] == UInt8(ascii: "/") || p[i + 1] == UInt8(ascii: "!") || p[i + 1] == UInt8(ascii: "?") {
                    var j = i + 1
                    let isClosing = p[j] == UInt8(ascii: "/")
                    if isClosing { j += 1 }
                    sink.emit(i, j, .punctuation)
                    let nameStart = j
                    if j < n, p[j] == UInt8(ascii: "!") || p[j] == UInt8(ascii: "?") { j += 1 }
                    while j < n, Lexer.isMarkupNameChar(p[j]) { j += 1 }
                    sink.emit(nameStart, j, componentTags && j > nameStart && p[nameStart] >= 65 && p[nameStart] <= 90 ? .type : .tag)
                    pending = 0
                    expectLanguage = false
                    if !isClosing, !embedded.isEmpty {
                        if Lexer.equalsIgnoringCase(Lexer.scriptName, p, nameStart, j) { pending = 1 }
                        if Lexer.equalsIgnoringCase(Lexer.styleName, p, nameStart, j) { pending = 3 }
                    }
                    i = j
                    mode = .markupTag
                } else {
                    i += 1
                }
            }
        }

        switch mode {
        case .markupTag: state = LexState(.markupTag, index: pending)
        case .markupComment: state = LexState(.markupComment)
        default: state = .normal
        }
    }

    /// Colors `p[from..<to]` with the embedded lexer of `region` and adds its tokens, shifted back into the line.
    private func scanEmbedded(_ region: Int, _ p: UnsafeBufferPointer<UInt8>, from: Int, to: Int, state: inout LexState, sink: inout Sink) {
        guard region >= 1, region <= embedded.count, to > from else { return }
        var part = Sink(enabled: sink.enabled)
        embedded[region - 1].scan(UnsafeBufferPointer(rebasing: p[from..<to]), state: &state, sink: &part)
        for token in part.tokens {
            sink.tokens.append(SyntaxToken(start: token.start + from, length: token.length, kind: token.kind))
        }
    }

    private static let scriptName = Array("script".utf8)
    private static let styleName = Array("style".utf8)
    private static let langName = Array("lang".utf8)

    /// The embedded region for a `lang="..."` value; `current` when the value is not one we know.
    private static func region(forLanguage p: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, current: Int) -> Int {
        let table: [(String, Int)] = [
            ("ts", 2), ("tsx", 2), ("typescript", 2), ("js", 1), ("jsx", 1), ("javascript", 1),
            ("css", 3), ("postcss", 3), ("scss", 4), ("sass", 4), ("less", 5),
        ]
        for (name, region) in table where equalsIgnoringCase(Array(name.utf8), p, start, end) {
            // A language of the other family (lang="ts" on <style>) is ignored.
            return (region <= 2) == (current <= 2) ? region : current
        }
        return current
    }

    private static func equalsIgnoringCase(_ word: [UInt8], _ p: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Bool {
        guard end - start == word.count, start >= 0, end <= p.count else { return false }
        for k in 0..<word.count where (p[start + k] | 0x20) != word[k] { return false }
        return true
    }

    /// Start of `</name` (any letter case) at or after `from`.
    private static func findClosingTag(_ name: [UInt8], _ p: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        var i = from
        let last = p.count - name.count - 2
        while i <= last {
            if p[i] == UInt8(ascii: "<"), p[i + 1] == UInt8(ascii: "/"), equalsIgnoringCase(name, p, i + 2, i + 2 + name.count) { return i }
            i += 1
        }
        return nil
    }

    // MARK: key = value (YAML / TOML / INI / .env)

    private func scanKeyValue(_ p: UnsafeBufferPointer<UInt8>, state: inout LexState, sink: inout Sink) {
        let n = p.count
        var i = 0
        while i < n, p[i] == 0x20 || p[i] == 0x09 { i += 1 }

        // Lines of a YAML block scalar (`key: |`): everything indented deeper than the key is text.
        if state.mode == .blockScalar {
            if i == n { return }
            if i > state.index {
                sink.emit(i, n, .string)
                return
            }
            state = .normal
        } else {
            state = .normal
        }
        guard i < n else { return }

        if lineComments.contains(where: { Lexer.matches($0, p, i) }) {
            sink.emit(i, n, .comment)
            return
        }

        // YAML document markers.
        if Lexer.matches([0x2D, 0x2D, 0x2D], p, i) || Lexer.matches([0x2E, 0x2E, 0x2E], p, i) {
            sink.emit(i, n, .punctuation)
            return
        }

        // [section] / [[table]]
        if p[i] == UInt8(ascii: "[") {
            var open = i
            while open < n, p[open] == UInt8(ascii: "[") { open += 1 }
            var close = open
            while close < n, p[close] != UInt8(ascii: "]") { close += 1 }
            if close < n {
                var end = close
                while end < n, p[end] == UInt8(ascii: "]") { end += 1 }
                // Only a header when nothing but a comment follows; otherwise it is an inline array value.
                let after = Lexer.nextNonSpace(p, end)
                if after == nil || lineComments.contains(where: { Lexer.matches($0, p, Lexer.skipSpaces(p, end)) }) {
                    sink.emit(i, open, .punctuation)
                    sink.emit(open, close, .keyword)
                    sink.emit(close, end, .punctuation)
                    scanValue(p, from: end, sink: &sink)
                    return
                }
            }
        }

        // YAML list items: "- key: value"
        var ownerColumn = i
        while i < n, p[i] == UInt8(ascii: "-"), i + 1 == n || p[i + 1] == 0x20 {
            sink.emit(i, i + 1, .punctuation)
            i += 1
            while i < n, p[i] == 0x20 { i += 1 }
            ownerColumn = i
        }
        guard i < n else { return }

        // The key runs up to the first "=" or the first ": " / ":" at end of line, outside quotes.
        var j = i
        var separator = -1
        var quote: UInt8 = 0
        while j < n {
            let c = p[j]
            if quote != 0 {
                if c == quote { quote = 0 }
            } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                quote = c
            } else if c == UInt8(ascii: "=") {
                separator = j
                break
            } else if c == UInt8(ascii: ":"), j + 1 == n || p[j + 1] == 0x20 {
                separator = j
                break
            } else if c == 0x20, j + 1 < n, lineComments.contains(where: { Lexer.matches($0, p, j + 1) }) {
                break
            }
            j += 1
        }

        if separator > i {
            var keyEnd = separator
            while keyEnd > i, p[keyEnd - 1] == 0x20 || p[keyEnd - 1] == 0x09 { keyEnd -= 1 }
            sink.emit(i, keyEnd, .variable)
            sink.emit(separator, separator + 1, .punctuation)
            if !startBlockScalar(p, from: separator + 1, owner: ownerColumn, state: &state, sink: &sink) {
                scanValue(p, from: separator + 1, sink: &sink)
            }
        } else if !startBlockScalar(p, from: i, owner: ownerColumn, state: &state, sink: &sink) {
            scanValue(p, from: i, sink: &sink)
        }
    }

    /// YAML: a value that is only `|` or `>` (with `+`, `-` or a digit) starts a block scalar. The marker is
    /// punctuation and the following lines indented deeper than `owner` are strings. Returns whether it did.
    private func startBlockScalar(_ p: UnsafeBufferPointer<UInt8>, from: Int, owner: Int, state: inout LexState, sink: inout Sink) -> Bool {
        guard isYAML else { return false }
        let n = p.count
        let start = Lexer.skipSpaces(p, from)
        guard start < n, p[start] == UInt8(ascii: "|") || p[start] == UInt8(ascii: ">") else { return false }
        var end = start + 1
        while end < n, p[end] == UInt8(ascii: "+") || p[end] == UInt8(ascii: "-") || Lexer.isDigit(p[end]) { end += 1 }
        let rest = Lexer.skipSpaces(p, end)
        guard rest == n || Lexer.matches([0x23], p, rest) else { return false }
        sink.emit(start, end, .punctuation)
        if rest < n { sink.emit(rest, n, .comment) }
        state = LexState(.blockScalar, index: owner)
        return true
    }

    /// The value part of `key: value`, `key = value` or a list item. Quoted text is a string; a bare value is a
    /// string too, except numbers and `true` `false` `yes` `no` `null` `~`, which are numbers.
    /// In flow collections (`[a, b]`, `{a: 1}`) words end at commas and brackets; elsewhere a bare value runs to
    /// the end of the line or to a ` #` comment (TOML and INI-style `;` too).
    private func scanValue(_ p: UnsafeBufferPointer<UInt8>, from: Int, sink: inout Sink) {
        let n = p.count
        var i = from
        var flow = 0
        while i < n {
            let c = p[i]
            if c == 0x20 || c == 0x09 {
                i += 1
                continue
            }
            if (i == from || p[i - 1] == 0x20 || p[i - 1] == 0x09), lineComments.contains(where: { Lexer.matches($0, p, i) }) {
                sink.emit(i, n, .comment)
                return
            }
            if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                var j = i + 1
                while j < n, p[j] != c {
                    j += (c == UInt8(ascii: "\"") && p[j] == UInt8(ascii: "\\")) ? 2 : 1
                }
                let end = min(j + 1, n)
                // A quoted key inside a flow mapping: `{"a": 1}`.
                sink.emit(i, end, flow > 0 && end < n && p[end] == UInt8(ascii: ":") ? .variable : .string)
                i = end
                continue
            }
            if c == UInt8(ascii: "[") || c == UInt8(ascii: "{") {
                flow += 1
                sink.emit(i, i + 1, .punctuation)
                i += 1
                continue
            }
            if c == UInt8(ascii: "]") || c == UInt8(ascii: "}") {
                flow = max(0, flow - 1)
                sink.emit(i, i + 1, .punctuation)
                i += 1
                continue
            }
            if c == UInt8(ascii: ",") && (flow > 0 || splitsOnCommas) {
                sink.emit(i, i + 1, .punctuation)
                i += 1
                continue
            }
            if flow > 0, c == UInt8(ascii: ":") || c == UInt8(ascii: "=") {
                sink.emit(i, i + 1, .punctuation)
                i += 1
                continue
            }
            // YAML anchors, aliases and tags stay plain.
            if isYAML, c == UInt8(ascii: "&") || c == UInt8(ascii: "*") || c == UInt8(ascii: "!") {
                while i < n, p[i] != 0x20, p[i] != 0x09 { i += 1 }
                continue
            }
            // A bare value.
            var j = i
            while j < n {
                let d = p[j]
                if flow > 0 || splitsOnCommas {
                    if d == UInt8(ascii: ",") || d == UInt8(ascii: "]") || d == UInt8(ascii: "}") { break }
                }
                if flow > 0, d == UInt8(ascii: ":") || d == UInt8(ascii: "="), j + 1 == n || p[j + 1] == 0x20 { break }
                if (d == 0x20 || d == 0x09), let next = Optional(Lexer.skipSpaces(p, j)), next < n {
                    if lineComments.contains(where: { Lexer.matches($0, p, next) }) { break }
                    if flow > 0, p[next] == UInt8(ascii: ":") || p[next] == UInt8(ascii: "=") || p[next] == UInt8(ascii: ",") || p[next] == UInt8(ascii: "]") || p[next] == UInt8(ascii: "}") { break }
                }
                j += 1
            }
            var end = j
            while end > i, p[end - 1] == 0x20 || p[end - 1] == 0x09 { end -= 1 }
            if end > i {
                let isKey = flow > 0 && ((j < n && (p[j] == UInt8(ascii: ":") || p[j] == UInt8(ascii: "="))) || Lexer.nextNonSpace(p, end) == UInt8(ascii: "=") || Lexer.nextNonSpace(p, end) == UInt8(ascii: ":"))
                if isKey {
                    sink.emit(i, end, .variable)
                } else if Lexer.isScalarLiteral(p, i, end) || words[Lexer.hash(p, i, end, lowercase: caseInsensitive)] == TokenKind.number.rawValue || Lexer.looksNumeric(p, i, end) {
                    sink.emit(i, end, .number)
                } else {
                    sink.emit(i, end, .string)
                }
            }
            i = max(j, i + 1)
        }
    }

    /// `true`, `false`, `yes`, `no`, `null` and `~` in any letter case.
    private static func isScalarLiteral(_ p: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Bool {
        let length = end - start
        guard length >= 1, length <= 5 else { return false }
        if length == 1 { return p[start] == UInt8(ascii: "~") }
        var word: UInt64 = 0
        for k in start..<end { word = word << 8 | UInt64(p[k] | 0x20) }
        // "no", "yes", "true", "false", "null"
        return word == 0x6E6F || word == 0x796573 || word == 0x74727565 || word == 0x66616C7365 || word == 0x6E756C6C
    }

    // MARK: Markdown

    private func scanMarkdown(_ p: UnsafeBufferPointer<UInt8>, state: inout LexState, sink: inout Sink) {
        let n = p.count
        var i = 0
        while i < n, p[i] == 0x20 || p[i] == 0x09 { i += 1 }
        // Fence kind: 0 = ```, 1 = ~~~. Remembered in the state so only the matching fence closes a block.
        let fenceKind = Lexer.matches([0x60, 0x60, 0x60], p, i) ? 0 : Lexer.matches([0x7E, 0x7E, 0x7E], p, i) ? 1 : -1

        if state.mode == .fence {
            sink.emit(0, n, .string)
            if fenceKind == state.index {
                // A closing fence is bare: "```js" inside a block is content, not the end.
                let fence: UInt8 = fenceKind == 0 ? 0x60 : 0x7E
                var j = i
                while j < n, p[j] == fence { j += 1 }
                if Lexer.skipSpaces(p, j) == n { state = .normal }
            }
            return
        }
        state = .normal
        guard i < n else { return }
        if fenceKind >= 0 {
            sink.emit(0, n, .string)
            state = LexState(.fence, index: fenceKind)
            return
        }

        if p[i] == UInt8(ascii: "#") {
            var j = i
            while j < n, p[j] == UInt8(ascii: "#") { j += 1 }
            if j - i <= 6, j == n || p[j] == 0x20 {
                sink.emit(i, n, .tag)
                return
            }
        }
        if p[i] == UInt8(ascii: ">") {
            sink.emit(i, n, .comment)
            return
        }

        // List markers: "- ", "* ", "+ ", "1. "
        if i + 1 < n, p[i] == UInt8(ascii: "-") || p[i] == UInt8(ascii: "*") || p[i] == UInt8(ascii: "+"), p[i + 1] == 0x20 {
            sink.emit(i, i + 1, .punctuation)
            i += 2
        } else if Lexer.isDigit(p[i]) {
            var j = i
            while j < n, Lexer.isDigit(p[j]) { j += 1 }
            if j + 1 < n, p[j] == UInt8(ascii: ".") || p[j] == UInt8(ascii: ")"), p[j + 1] == 0x20 {
                sink.emit(i, j + 1, .punctuation)
                i = j + 2
            }
        }

        while i < n {
            let c = p[i]
            if c == UInt8(ascii: "\\") {
                i += 2
            } else if c == UInt8(ascii: "`") {
                var j = i + 1
                while j < n, p[j] != UInt8(ascii: "`") { j += 1 }
                let end = min(j + 1, n)
                sink.emit(i, end, .string)
                i = end
            } else if c == UInt8(ascii: "["), let link = Lexer.markdownLink(p, at: i) {
                // [text](url): the text is a function, the address a string.
                if link.textEnd > i + 1 { sink.emit(i + 1, link.textEnd, .function) }
                if link.urlEnd > link.textEnd + 2 { sink.emit(link.textEnd + 2, link.urlEnd, .string) }
                i = link.end
            } else if c == UInt8(ascii: "*") || c == UInt8(ascii: "_"), let end = Lexer.emphasisEnd(p, at: i) {
                var run = 1
                while i + run < n, p[i + run] == c { run += 1 }
                sink.emit(i, end, run == 2 ? .attribute : .keyword)
                i = end
            } else if c == UInt8(ascii: "*") || c == UInt8(ascii: "_") {
                while i < n, p[i] == c { i += 1 }
            } else {
                i += 1
            }
        }
    }

    /// `[text](url)` starting at `i` on this line: where the text ends (the `]`), where the address ends (the `)`,
    /// or the end of the line when it is never closed) and the index just past the link.
    private static func markdownLink(_ p: UnsafeBufferPointer<UInt8>, at i: Int) -> (textEnd: Int, urlEnd: Int, end: Int)? {
        let n = p.count
        var j = i + 1
        while j < n, p[j] != UInt8(ascii: "]") { j += 1 }
        guard j + 1 < n, p[j + 1] == UInt8(ascii: "(") else { return nil }
        var k = j + 2
        while k < n, p[k] != UInt8(ascii: ")") { k += 1 }
        return (j, k, min(k + 1, n))
    }

    /// Emphasis opening at `i` (`*`, `**`, `_` or `__`): the index just past its closing mark, or nil.
    /// It has to close on the same line. The opener sits at a word boundary (so `snake_case_words` and `2*3*4`
    /// are safe) and is followed by a non-space; the closer follows a non-space and, for `_`, ends a word.
    private static func emphasisEnd(_ p: UnsafeBufferPointer<UInt8>, at i: Int) -> Int? {
        let n = p.count
        let c = p[i]
        var run = 1
        while i + run < n, p[i + run] == c { run += 1 }
        guard run <= 2, i + run < n, p[i + run] != 0x20, p[i + run] != 0x09 else { return nil }
        if i > 0, isLetter(p[i - 1]) || isDigit(p[i - 1]) || p[i - 1] >= 0x80 { return nil }
        var j = i + run
        while j < n {
            if p[j] == UInt8(ascii: "`") {
                var k = j + 1
                while k < n, p[k] != UInt8(ascii: "`") { k += 1 }
                if k >= n { return nil }
                j = k + 1
            } else if p[j] == UInt8(ascii: "\\") {
                j += 2
            } else if p[j] == c {
                var length = 1
                while j + length < n, p[j + length] == c { length += 1 }
                let after = j + length
                if length == run, p[j - 1] != 0x20, p[j - 1] != 0x09, j - 1 >= i + run {
                    let endsWord = after >= n || !(isLetter(p[after]) || isDigit(p[after]) || p[after] >= 0x80)
                    if c == UInt8(ascii: "*") || endsWord { return after }
                }
                j = after
            } else {
                j += 1
            }
        }
        return nil
    }

    // MARK: - Byte helpers

    @inline(__always) private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    @inline(__always) private static func isLetter(_ c: UInt8) -> Bool { (c | 0x20) >= 97 && (c | 0x20) <= 122 }
    @inline(__always) private static func isHexDigit(_ c: UInt8) -> Bool { isDigit(c) || ((c | 0x20) >= 97 && (c | 0x20) <= 102) }
    /// Non-ASCII bytes count as identifier characters so words in any script stay whole.
    @inline(__always) private static func isIdentifierStart(_ c: UInt8) -> Bool { isLetter(c) || c == 95 || c >= 0x80 }
    @inline(__always) private static func isIdentifierPart(_ c: UInt8) -> Bool { isLetter(c) || isDigit(c) || c == 95 || c >= 0x80 }
    @inline(__always) private static func isMarkupNameChar(_ c: UInt8) -> Bool {
        isLetter(c) || isDigit(c) || c == 45 || c == 58 || c == 95 || c == 46 || c == 64 || c >= 0x80
    }

    /// The byte before `i` ends an operand (identifier, number, `)`, `]` or `.`), so a following `.digit` is not a number.
    @inline(__always)
    private static func endsValue(_ p: UnsafeBufferPointer<UInt8>, before i: Int) -> Bool {
        guard i > 0 else { return false }
        let previous = p[i - 1]
        return isIdentifierPart(previous) || previous == UInt8(ascii: ")") || previous == UInt8(ascii: "]") || previous == UInt8(ascii: ".")
    }

    @inline(__always)
    private static func isOperatorByte(_ c: UInt8) -> Bool {
        switch c {
        case UInt8(ascii: "="), UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "*"), UInt8(ascii: "/"), UInt8(ascii: "%"),
             UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "!"), UInt8(ascii: "?"), UInt8(ascii: "&"), UInt8(ascii: "|"),
             UInt8(ascii: "^"), UInt8(ascii: "~"):
            true
        default:
            false
        }
    }

    /// Length of the operator that starts at `i`, or nil. A run of operator characters (`===`, `&&`, `->`, `+=`),
    /// plus `?.`, `::`, `:=` and `..` / `...`. A single `:` or `.`, brackets, commas and semicolons are not operators.
    private static func operatorLength(_ p: UnsafeBufferPointer<UInt8>, _ i: Int, breaksAtSlashAndAngle: Bool) -> Int? {
        let n = p.count
        let c = p[i]
        if isOperatorByte(c) {
            var j = i + 1
            while j < n, isOperatorByte(p[j]) {
                // In JavaScript a `/` or `<` inside a run may start a regex or a JSX tag: `!/x/`, `&&<div/>`.
                if breaksAtSlashAndAngle, p[j] == UInt8(ascii: "/") || p[j] == UInt8(ascii: "<") { break }
                j += 1
            }
            // Optional chaining: `?.` unless a digit follows (`a ?.5 : 1`).
            if p[j - 1] == UInt8(ascii: "?"), j < n, p[j] == UInt8(ascii: "."), !(j + 1 < n && isDigit(p[j + 1])) { j += 1 }
            return j - i
        }
        if c == UInt8(ascii: ":"), i + 1 < n {
            if p[i + 1] == UInt8(ascii: ":") {
                var j = i + 2
                while j < n, p[j] == UInt8(ascii: ":") { j += 1 }
                return j - i
            }
            if p[i + 1] == UInt8(ascii: "=") { return 2 }
        }
        if c == UInt8(ascii: "."), i + 1 < n, p[i + 1] == UInt8(ascii: ".") {
            var j = i + 2
            while j < n, p[j] == UInt8(ascii: ".") { j += 1 }
            return j - i
        }
        return nil
    }

    /// `from`, `as`, `of` at `start..<end` used as a keyword: not after a dot, and not called, assigned,
    /// passed, keyed or ended (`Array.from(x)`, `from = 1`, `{ from: 1 }`, `fn(from, to)`, `as;`).
    private static func isContextualKeyword(_ p: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Bool {
        let length = end - start
        guard length == 2 || length == 4 else { return false }
        let a = p[start], b = p[start + 1]
        let word = (length == 2 && ((a == 0x61 && b == 0x73) || (a == 0x6F && b == 0x66)))
            || (length == 4 && a == 0x66 && b == 0x72 && p[start + 2] == 0x6F && p[start + 3] == 0x6D)
        guard word else { return false }
        var k = start - 1
        while k >= 0, p[k] == 0x20 || p[k] == 0x09 { k -= 1 }
        if k >= 0, p[k] == UInt8(ascii: ".") { return false }
        guard let next = nextNonSpace(p, end) else { return false }
        switch next {
        case UInt8(ascii: "("), UInt8(ascii: ":"), UInt8(ascii: "="), UInt8(ascii: ","), UInt8(ascii: ")"), UInt8(ascii: ";"),
             UInt8(ascii: "."), UInt8(ascii: "}"), UInt8(ascii: "]"), UInt8(ascii: "?"):
            return false
        default:
            return true
        }
    }

    /// `p[open]` is the `<` right after a name. True when its matching `>` on this line is followed by `(`,
    /// or when it is `<{` and still open at the end of the line. Looks at most 256 bytes ahead.
    private static func startsGenericCall(_ p: UnsafeBufferPointer<UInt8>, _ open: Int) -> Bool {
        let n = p.count
        let limit = min(n, open + 256)
        var depth = 0
        var k = open
        while k < limit {
            let c = p[k]
            if c == UInt8(ascii: "<") {
                depth += 1
            } else if c == UInt8(ascii: ">") {
                if k > 0, p[k - 1] == UInt8(ascii: "=") { k += 1; continue }
                depth -= 1
                if depth == 0 { return k + 1 < n && p[k + 1] == UInt8(ascii: "(") }
            } else if (c == UInt8(ascii: "&") || c == UInt8(ascii: "|")), k + 1 < n, p[k + 1] == c {
                return false
            }
            k += 1
        }
        return limit == n && open + 1 < n && p[open + 1] == UInt8(ascii: "{")
    }

    /// Guards against things that look like a line comment but are not.
    @inline(__always)
    private static func isCommentStart(_ delimiter: [UInt8], _ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let previous = p[i - 1]
        if delimiter.count == 1, delimiter[0] == UInt8(ascii: "#") {
            // "$#", "${#x}" and "url#fragment" are not comments.
            return previous == 0x20 || previous == 0x09 || previous == UInt8(ascii: ";") || previous == UInt8(ascii: ")")
                || previous == UInt8(ascii: "}") || previous == UInt8(ascii: ",")
        }
        if delimiter.count == 2, delimiter[0] == UInt8(ascii: "/"), delimiter[1] == UInt8(ascii: "/") {
            // "http://" outside a string.
            return previous != UInt8(ascii: ":")
        }
        return true
    }

    @inline(__always)
    private static func matches(_ needle: [UInt8], _ p: UnsafeBufferPointer<UInt8>, _ at: Int) -> Bool {
        let count = needle.count
        guard at >= 0, at + count <= p.count else { return false }
        for k in 0..<count where p[at + k] != needle[k] { return false }
        return true
    }

    private static func find(_ needle: [UInt8], _ p: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        guard let first = needle.first, from < p.count else { return nil }
        var i = from
        let last = p.count - needle.count
        while i <= last {
            if p[i] == first, matches(needle, p, i) { return i }
            i += 1
        }
        return nil
    }

    @inline(__always)
    private static func skipSpaces(_ p: UnsafeBufferPointer<UInt8>, _ from: Int) -> Int {
        var j = from
        while j < p.count, p[j] == 0x20 || p[j] == 0x09 { j += 1 }
        return j
    }

    @inline(__always)
    private static func nextNonSpace(_ p: UnsafeBufferPointer<UInt8>, _ from: Int) -> UInt8? {
        let j = skipSpaces(p, from)
        return j < p.count ? p[j] : nil
    }

    private static func looksNumeric(_ p: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Bool {
        guard end > start else { return false }
        var i = start
        if p[i] == UInt8(ascii: "+") || p[i] == UInt8(ascii: "-") { i += 1 }
        guard i < end, isDigit(p[i]) || (p[i] == UInt8(ascii: ".") && i + 1 < end && isDigit(p[i + 1])) else { return false }
        for k in i..<end {
            let c = p[k]
            let ok = isHexDigit(c) || c == UInt8(ascii: ".") || c == UInt8(ascii: "_") || c == UInt8(ascii: "+") || c == UInt8(ascii: "-")
                || c == UInt8(ascii: ":") || (c | 0x20) == UInt8(ascii: "x") || (c | 0x20) == UInt8(ascii: "o")
                || c == UInt8(ascii: "T") || c == UInt8(ascii: "Z")
            if !ok { return false }
        }
        return true
    }

    /// FNV-1a over the bytes, mixed with the length.
    @inline(__always)
    private static func hash(_ p: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, lowercase: Bool) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for k in start..<end {
            var c = p[k]
            if lowercase, c >= 65, c <= 90 { c += 32 }
            h = (h ^ UInt64(c)) &* 0x0000_0100_0000_01B3
        }
        return h &* 31 &+ UInt64(end - start)
    }

    private static func hasNonASCII(_ p: UnsafeBufferPointer<UInt8>) -> Bool {
        for c in p where c >= 0x80 { return true }
        return false
    }

    /// Byte length and UTF-16 length of the character at `at`. Invalid bytes are counted the way
    /// `String(decoding:as:)` repairs them (one U+FFFD per maximal invalid subpart), because that is the text the UI shows.
    private static func utf8Step(_ p: UnsafeBufferPointer<UInt8>, _ at: Int) -> (bytes: Int, units: Int) {
        let lead = p[at]
        if lead < 0x80 { return (1, 1) }
        var low: UInt8 = 0x80
        var high: UInt8 = 0xBF
        let continuations: Int
        switch lead {
        case 0xC2...0xDF: continuations = 1
        case 0xE0: continuations = 2; low = 0xA0
        case 0xE1...0xEC, 0xEE, 0xEF: continuations = 2
        case 0xED: continuations = 2; high = 0x9F
        case 0xF0: continuations = 3; low = 0x90
        case 0xF1...0xF3: continuations = 3
        case 0xF4: continuations = 3; high = 0x8F
        default: return (1, 1)
        }
        var length = 1
        while length <= continuations {
            guard at + length < p.count, p[at + length] >= low, p[at + length] <= high else { return (length, 1) }
            length += 1
            low = 0x80
            high = 0xBF
        }
        return (length, continuations == 3 ? 2 : 1)
    }

    /// Tokens are produced with byte offsets; the UI needs UTF-16 offsets. Only non-ASCII lines pay for this.
    private static func convertToUTF16(_ tokens: inout [SyntaxToken], _ p: UnsafeBufferPointer<UInt8>) {
        var units = 0
        var byte = 0
        @inline(__always) func advance(to target: Int) {
            while byte < target, byte < p.count {
                let step = Lexer.utf8Step(p, byte)
                byte += step.bytes
                units += step.units
            }
        }
        for index in tokens.indices {
            let startByte = tokens[index].start
            let endByte = startByte + tokens[index].length
            advance(to: startByte)
            let start = units
            advance(to: endByte)
            tokens[index].start = start
            tokens[index].length = units - start
        }
        tokens.removeAll { $0.length <= 0 }
    }
}
