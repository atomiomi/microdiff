import Foundation

/// What a piece of source text is, for coloring.
package enum TokenKind: UInt8, Sendable, Hashable, CaseIterable {
    case plain
    case keyword
    case type
    case function
    /// Any other identifier in code (`props`, `draft`, parameters, object keys).
    case variable
    case string
    case number
    case comment
    case punctuation
    /// A markup or JSX tag name (`div`, `template`).
    case tag
    /// A markup attribute name (`class`, `v-if`).
    case attribute
    /// Operators in code: `=` `+` `&&` `->` `::` `??`. Brackets, commas, semicolons, dots and single colons stay punctuation.
    case `operator`
}

/// A colored span inside one line. Offsets are UTF-16 code units from the start of the line.
package struct SyntaxToken: Sendable, Hashable {
    package var start: Int
    package var length: Int
    package var kind: TokenKind

    package init(start: Int, length: Int, kind: TokenKind) {
        self.start = start
        self.length = length
        self.kind = kind
    }
}

package struct StringDelimiter: Sendable, Hashable {
    /// Opening text, e.g. `"`, `'`, `` ` ``, `"""`.
    package var open: String
    /// Closing text. Usually the same as `open`.
    package var close: String
    /// Character that escapes the next character inside the string (usually `\`). Nil = no escapes.
    package var escape: Character?
    /// The string may run over several lines (Python `"""`, JS template literals, ...).
    package var multiline: Bool

    package init(_ open: String, close: String? = nil, escape: Character? = "\\", multiline: Bool = false) {
        self.open = open
        self.close = close ?? open
        self.escape = escape
        self.multiline = multiline
    }
}

package struct BlockComment: Sendable, Hashable {
    package var open: String
    package var close: String

    package init(_ open: String, _ close: String) {
        self.open = open
        self.close = close
    }
}

/// Plain data that tells the lexer how to color one language. No logic here.
package struct LanguageDefinition: Sendable, Hashable {
    package enum Flavor: UInt8, Sendable, Hashable {
        /// A normal programming language: identifiers, keywords, strings, numbers, comments.
        case code
        /// HTML / XML / SVG: `<tag attr="value">`.
        case markup
        /// YAML / TOML / INI / .env / properties: `key: value` or `key = value`.
        case keyValue
        /// JSON: strings before ":" are keys.
        case json
        /// CSS-like: `property: value;` inside rules.
        case css
        case markdown
        /// No coloring at all.
        case plain
    }

    /// Display name, e.g. "Swift".
    package var name: String
    package var flavor: Flavor
    /// File extensions without the dot, lowercase: ["swift"], ["c", "h"].
    package var extensions: [String]
    /// Exact file names, case-sensitive: ["Makefile", "Dockerfile"].
    package var fileNames: [String]
    /// Words colored as keywords: control flow, declarations, modifiers (`if`, `func`, `let`, `pub`, `self`, ...).
    package var keywords: Set<String>
    /// Built-in type names colored as types (`int`, `bool`, `usize`, `string`, ...).
    package var types: Set<String>
    /// Built-in constants colored like numbers (`true`, `false`, `nil`, `null`, `None`, `undefined`, ...).
    package var constants: Set<String>
    /// Line comment starters, e.g. ["//"], ["#"], ["--"].
    package var lineComments: [String]
    package var blockComments: [BlockComment]
    /// Block comments nest (Swift, Rust, Kotlin, Scala, Haskell ...).
    package var nestedBlockComments: Bool
    package var strings: [StringDelimiter]
    /// Identifiers starting with an uppercase letter are colored as types (true for most languages with a type naming convention).
    package var capitalizedIsType: Bool
    /// Extra characters allowed inside identifiers besides letters, digits and "_" (e.g. "$" for JS, "-" for CSS, "?!" for Ruby).
    package var identifierExtras: String
    /// Keywords, types and constants match regardless of case (SQL).
    package var caseInsensitive: Bool
    /// JavaScript family: `/.../` can be a regular expression and `<Tag>` can be a JSX tag.
    package var slashRegexAndTags: Bool
    /// HTML family: the contents of `<script>` and `<style>` are colored as JavaScript / TypeScript and CSS / SCSS.
    package var embedsScriptAndStyle: Bool

    package init(
        name: String,
        flavor: Flavor = .code,
        extensions: [String] = [],
        fileNames: [String] = [],
        keywords: Set<String> = [],
        types: Set<String> = [],
        constants: Set<String> = [],
        lineComments: [String] = [],
        blockComments: [BlockComment] = [],
        nestedBlockComments: Bool = false,
        strings: [StringDelimiter] = [],
        capitalizedIsType: Bool = true,
        identifierExtras: String = "",
        caseInsensitive: Bool = false,
        slashRegexAndTags: Bool = false,
        embedsScriptAndStyle: Bool = false
    ) {
        self.name = name
        self.flavor = flavor
        self.extensions = extensions
        self.fileNames = fileNames
        self.keywords = keywords
        self.types = types
        self.constants = constants
        self.lineComments = lineComments
        self.blockComments = blockComments
        self.nestedBlockComments = nestedBlockComments
        self.strings = strings
        self.capitalizedIsType = capitalizedIsType
        self.identifierExtras = identifierExtras
        self.caseInsensitive = caseInsensitive
        self.slashRegexAndTags = slashRegexAndTags
        self.embedsScriptAndStyle = embedsScriptAndStyle
    }
}
