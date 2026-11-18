import AppKit
import CoreText
import MicroDiffCore

/// Text colors. Small integer ids so cached text lines can be keyed cheaply.
enum Ink: Int, CaseIterable {
    /// Main text and plain code.
    case fg
    /// File and folder names in the trees.
    case mid
    /// Quiet text: inactive tab titles, branch label, small labels.
    case dim
    /// Single-color glyph icons (branch, close, chevron, unfold).
    case icon
    /// Line numbers and the separators of compacted folder names.
    case lineNumber
    /// Names of ignored files.
    case ignored
    case green, red, yellow, blue
    /// Syntax colors: plain code text first, then one per token kind. The values come from `SyntaxPalette.active`.
    case code, keyword, type, function, string, number, comment, punctuation, variable, `operator`, tag, attribute

    var cg: CGColor { Theme.inkColors[rawValue] }

    private var hex: UInt32 {
        switch self {
        case .fg: 0xb8bec9
        case .mid: 0x9fa7b4
        case .dim: 0x7b818b
        case .icon: 0x848b98
        case .lineNumber: 0x484f5e
        case .ignored: 0x5d6470
        case .green: 0x94c580
        case .red: 0xe17177
        case .yellow: 0xe1bc77
        case .blue: 0x6caeef
        case .code: SyntaxPalette.active.plain
        case .keyword: SyntaxPalette.active.keyword
        case .type: SyntaxPalette.active.type
        case .function: SyntaxPalette.active.function
        case .string: SyntaxPalette.active.string
        case .number: SyntaxPalette.active.number
        case .comment: SyntaxPalette.active.comment
        case .punctuation: SyntaxPalette.active.punctuation
        case .variable: SyntaxPalette.active.variable
        case .operator: SyntaxPalette.active.operator
        case .tag: SyntaxPalette.active.tag
        case .attribute: SyntaxPalette.active.attribute
        }
    }

    fileprivate static func buildColors() -> [CGColor] {
        allCases.map { Theme.rgb($0.hex) }
    }

    static func syntax(_ kind: TokenKind) -> Ink {
        switch kind {
        case .plain: .code
        case .keyword: .keyword
        case .type: .type
        case .function: .function
        case .variable: .variable
        case .string: .string
        case .number: .number
        case .comment: .comment
        case .punctuation: .punctuation
        case .operator: .operator
        case .tag: .tag
        case .attribute: .attribute
        }
    }

    static func change(_ kind: ChangeKind) -> Ink {
        switch kind {
        case .modified: .yellow
        case .added: .green
        case .deleted, .conflicted: .red
        case .renamed: .blue
        }
    }
}

/// The syntax colors: one per token kind plus the plain code text. Taking another theme means adding one preset.
struct SyntaxPalette {
    var plain, keyword, type, function, variable, string, number, comment, punctuation, `operator`, tag, attribute: UInt32

    /// The palette in use.
    static let active = oneDarkProFlat

    /// One Dark Pro Flat 3.20.6 (VS Code extension `zhuangtongfa.material-theme`, themes/OneDark-Pro-flat.json).
    /// License: MIT, "Copyright (c) 2013-2022 Binaryify" (LICENSE.txt in the extension folder).
    /// Scopes the colors come from:
    /// - plain: `editor.foreground`; punctuation has no rule of its own, so it is the foreground too
    /// - operator: `keyword.operator.arithmetic/comparison/logical/bitwise/assignment` (56b6c2)
    /// - keyword: `keyword.control`, `storage`
    /// - type: `entity.name.type`, `support.class`, `variable.language` (`this`, `super`)
    /// - function: `entity.name.function`
    /// - string: `string`
    /// - number: `constant.numeric`, `constant.language`
    /// - comment: `comment` (not italic in the flat variant)
    /// - variable: `variable`, `meta.object-literal.key`, JSON and YAML keys
    /// - tag: `entity.name.tag`
    /// - attribute: `entity.other.attribute-name`
    static let oneDarkProFlat = SyntaxPalette(
        plain: 0xabb2bf, keyword: 0xc678dd, type: 0xe5c07b, function: 0x61afef, variable: 0xe06c75,
        string: 0x98c379, number: 0xd19a66, comment: 0x7f848e, punctuation: 0xabb2bf,
        operator: 0x56b6c2, tag: 0xe06c75, attribute: 0xd19a66)
}

/// The few font styles the app uses.
enum Face: Int, CaseIterable {
    /// 14 pt regular: the code itself.
    case code
    /// 12 pt regular: tree rows, tabs, line numbers.
    case regular
    /// 12 pt medium: active tabs.
    case medium
    /// 12 pt italic: preview tabs.
    case italic
    /// 11 pt regular: status letters, branch names, fold labels.
    case small

    var font: CTFont { Theme.fonts[rawValue] }

    fileprivate static func buildFonts() -> [CTFont] {
        allCases.map { face in
            switch face {
            case .code: Theme.font("JetBrainsMono-Regular", 14, .regular)
            case .regular: Theme.font("JetBrainsMono-Regular", 12, .regular)
            case .medium: Theme.font("JetBrainsMono-Medium", 12, .medium)
            case .italic: Theme.font("JetBrainsMono-Italic", 12, .regular)
            case .small: Theme.font("JetBrainsMono-Regular", 11, .regular)
            }
        }
    }
}

/// Colors, fonts and sizes from the design. One dark theme.
enum Theme {
    static let background = rgb(0x22262c)
    /// Hairlines and dividers.
    static let line = rgb(0x2d3138)
    /// Inactive tabs and the empty part of the tab bar.
    static let inactive = rgb(0x1c1f24)
    static let guide = rgb(0x363b43)
    static let rowSelected = rgb(0xffffff, 0.07)
    static let rowHover = rgb(0xffffff, 0.03)
    static let band = rgb(0xffffff, 0.035)
    /// Background of a tab's close box under the pointer.
    static let closeHover = rgb(0xffffff, 0.10)
    static let textSelection = rgb(0x86acf0, 0.26)
    static let scrollThumb = rgb(0xffffff, 0.22)
    static let addedRow = rgb(0x94c580, 0.12)
    static let deletedRow = rgb(0xe17177, 0.12)
    static let addedWord = rgb(0x94c580, 0.30)
    static let deletedWord = rgb(0xe17177, 0.30)

    static let inkColors: [CGColor] = Ink.buildColors()
    static let fonts: [CTFont] = Face.buildFonts()

    // Sizes.
    static let treeRowHeight: CGFloat = 24
    static let repoBandHeight: CGFloat = 28
    static let repoGap: CGFloat = 10
    /// Code rows: 14 pt text on a 22 pt line (about 1.6x), roomy enough to read long stretches.
    static let lineHeight: CGFloat = 22
    static let foldHeight: CGFloat = 28
    static var rowMetrics: RowMetrics { RowMetrics(lineHeight: Double(lineHeight), foldHeight: Double(foldHeight)) }
    static let tabBarHeight: CGFloat = 37
    static let defaultSidebarWidth: CGFloat = 288
    static let iconSize: CGFloat = 16
    static let treePadding: CGFloat = 14
    /// Icon + gap: one indent level in the tree.
    static let treeIndent: CGFloat = 21
    static let fixedTabWidth: CGFloat = 150

    // Code gutter: [2 bar][46 number][18 gap] code...
    static let gutterBarWidth: CGFloat = 2
    static let gutterNumberWidth: CGFloat = 46
    static let gutterGap: CGFloat = 18
    static var codeX: CGFloat { gutterBarWidth + gutterNumberWidth + gutterGap }

    /// Width of one character of the 12 pt interface font.
    static let charWidth: CGFloat = characterWidth(.regular, fallback: 7.2)
    /// Width of one character of the 14 pt code font.
    static let codeCharWidth: CGFloat = characterWidth(.code, fallback: 8.4)

    private static func characterWidth(_ face: Face, fallback: CGFloat) -> CGFloat {
        var glyph = CGGlyph(0)
        var char: UniChar = 0x30
        CTFontGetGlyphsForCharacters(face.font, &char, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(face.font, .horizontal, &glyph, &advance, 1)
        return advance.width > 0 ? advance.width : fallback
    }

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// JetBrains Mono when it is installed, the system monospaced font otherwise.
    static func font(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
        NSFont(name: name, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}
