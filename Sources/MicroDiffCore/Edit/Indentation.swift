/// How a file indents its lines: what the Tab key inserts in the editor.
package enum Indentation: Sendable, Equatable {
    case tabs
    /// Spaces, this many per level.
    case spaces(Int)

    /// Lines looked at: enough to tell, cheap even for a 4 MB file.
    package static let sampleLines = 300

    /// A line starting with a tab means tabs. Otherwise the smallest number of leading spaces on an indented line
    /// (kept within 1...8). With nothing indented: 4 spaces. Lines of only blanks do not count.
    package static func detect(_ text: String) -> Indentation {
        var smallest = Int.max
        var lines = 0
        var spaces = 0
        var atLineStart = true
        for byte in text.utf8 {
            if byte == 0x0A {
                lines += 1
                if lines >= sampleLines { break }
                spaces = 0
                atLineStart = true
                continue
            }
            guard atLineStart else { continue }
            switch byte {
            case 0x09:
                if spaces == 0 { return .tabs }
                atLineStart = false
            case 0x20:
                spaces += 1
            case 0x0D:
                break
            default:
                if spaces > 0 { smallest = min(smallest, spaces) }
                atLineStart = false
            }
        }
        return smallest == Int.max ? .spaces(4) : .spaces(min(smallest, 8))
    }
}
