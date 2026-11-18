import Foundation

/// A drawing step with absolute coordinates.
package enum PathCommand: Sendable, Hashable {
    case move(x: Double, y: Double)
    case line(x: Double, y: Double)
    case cubic(c1x: Double, c1y: Double, c2x: Double, c2y: Double, x: Double, y: Double)
    case close
}

/// Parses the `d` attribute of an SVG `<path>` (used for the icon set).
package enum SVGPath {
    /// Converts SVG path data into absolute move/line/cubic/close commands.
    ///
    /// - Supports every command, upper (absolute) and lower (relative) case: M L H V C S Q T A Z.
    /// - Repeated coordinate groups without a new letter repeat the command; after M/m the implicit command is L/l.
    /// - Numbers: optional sign, decimals without a leading zero (".5"), back-to-back numbers ("1.5.5" is 1.5 then .5,
    ///   "2-2" is 2 then -2), exponents ("1e-3"), separated by spaces and/or commas or nothing.
    /// - Arc flags are single digits and may be glued to the next number ("a2 2 0 011-1" = flags 0 and 1, then 1, -1).
    /// - Q/T are converted to cubics. S/T reflect the previous control point (or use the current point when the previous
    ///   command was not a curve of the same family).
    /// - A is converted to one cubic per quarter turn or less (SVG endpoint-to-center rules: zero radius -> line,
    ///   radii scaled up when too small, same start and end point -> nothing).
    /// - Z closes and moves the current point back to the start of the subpath.
    /// - Malformed input never crashes: parsing stops and returns what was parsed so far.
    package static func parse(_ d: String) -> [PathCommand] {
        var copy = d
        return copy.withUTF8 { bytes in
            var parser = Parser(bytes: bytes)
            parser.run()
            return parser.out
        }
    }
}

private struct Point {
    var x: Double
    var y: Double
}

/// Single-pass scanner over the UTF-8 bytes. Keeps the current point, the subpath start and the
/// last control points (for S/T reflection).
private struct Parser {
    let bytes: UnsafeBufferPointer<UInt8>
    var pos = 0
    var out: [PathCommand] = []
    var cur = Point(x: 0, y: 0)
    var start = Point(x: 0, y: 0)
    /// Second control point of the previous C/S, and control point of the previous Q/T.
    var lastCubic: Point?
    var lastQuad: Point?
    /// Reused argument buffer (at most 7 numbers per command).
    var args = [Double](repeating: 0, count: 7)

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
        out.reserveCapacity(32)
    }

    mutating func run() {
        var command: UInt8 = 0
        var first = true
        while true {
            skipSeparators()
            guard pos < bytes.count else { return }
            let b = bytes[pos]
            if isLetter(b) {
                guard argCount(b) != nil else { return }
                command = b
                pos += 1
                // The first command must be a move; anything else is malformed.
                if first && command != UInt8(ascii: "M") && command != UInt8(ascii: "m") { return }
            } else if command == 0 || upper(command) == UInt8(ascii: "Z") || !isNumberStart(b) {
                return
            }
            first = false
            guard let count = argCount(command) else { return }
            if count == 0 {
                close()
                continue
            }
            guard readArgs(count, isArc: upper(command) == UInt8(ascii: "A")) else { return }
            apply(command)
            // Extra coordinate groups after M/m are implicit line-tos.
            if command == UInt8(ascii: "M") { command = UInt8(ascii: "L") }
            if command == UInt8(ascii: "m") { command = UInt8(ascii: "l") }
        }
    }

    // MARK: Commands

    private mutating func apply(_ command: UInt8) {
        let rel = command >= UInt8(ascii: "a")
        let ox = rel ? cur.x : 0
        let oy = rel ? cur.y : 0
        var cubicNext: Point?
        var quadNext: Point?
        switch upper(command) {
        case UInt8(ascii: "M"):
            cur = Point(x: args[0] + ox, y: args[1] + oy)
            start = cur
            out.append(.move(x: cur.x, y: cur.y))
        case UInt8(ascii: "L"):
            lineTo(Point(x: args[0] + ox, y: args[1] + oy))
        case UInt8(ascii: "H"):
            lineTo(Point(x: args[0] + ox, y: cur.y))
        case UInt8(ascii: "V"):
            lineTo(Point(x: cur.x, y: args[0] + oy))
        case UInt8(ascii: "C"):
            let c2 = Point(x: args[2] + ox, y: args[3] + oy)
            cubicTo(Point(x: args[0] + ox, y: args[1] + oy), c2, Point(x: args[4] + ox, y: args[5] + oy))
            cubicNext = c2
        case UInt8(ascii: "S"):
            let c1 = reflected(lastCubic)
            let c2 = Point(x: args[0] + ox, y: args[1] + oy)
            cubicTo(c1, c2, Point(x: args[2] + ox, y: args[3] + oy))
            cubicNext = c2
        case UInt8(ascii: "Q"):
            let q = Point(x: args[0] + ox, y: args[1] + oy)
            quadTo(q, Point(x: args[2] + ox, y: args[3] + oy))
            quadNext = q
        case UInt8(ascii: "T"):
            let q = reflected(lastQuad)
            quadTo(q, Point(x: args[0] + ox, y: args[1] + oy))
            quadNext = q
        default: // "A"
            arcTo(
                rx: abs(args[0]), ry: abs(args[1]), rotation: args[2],
                large: args[3] != 0, sweep: args[4] != 0,
                to: Point(x: args[5] + ox, y: args[6] + oy))
        }
        lastCubic = cubicNext
        lastQuad = quadNext
    }

    private mutating func close() {
        out.append(.close)
        cur = start
        lastCubic = nil
        lastQuad = nil
    }

    private mutating func lineTo(_ p: Point) {
        out.append(.line(x: p.x, y: p.y))
        cur = p
    }

    private mutating func cubicTo(_ c1: Point, _ c2: Point, _ p: Point) {
        out.append(.cubic(c1x: c1.x, c1y: c1.y, c2x: c2.x, c2y: c2.y, x: p.x, y: p.y))
        cur = p
    }

    /// A quadratic with control `q` as the equivalent cubic (control points two thirds toward `q`).
    private mutating func quadTo(_ q: Point, _ p: Point) {
        let k = 2.0 / 3.0
        let c1 = Point(x: cur.x + k * (q.x - cur.x), y: cur.y + k * (q.y - cur.y))
        let c2 = Point(x: p.x + k * (q.x - p.x), y: p.y + k * (q.y - p.y))
        cubicTo(c1, c2, p)
    }

    /// The previous control point mirrored through the current point, or the current point itself.
    private func reflected(_ previous: Point?) -> Point {
        guard let previous else { return cur }
        return Point(x: 2 * cur.x - previous.x, y: 2 * cur.y - previous.y)
    }

    // MARK: Arcs (W3C SVG implementation notes F.6.5 / F.6.6)

    private mutating func arcTo(rx rxIn: Double, ry ryIn: Double, rotation: Double, large: Bool, sweep: Bool, to p: Point) {
        let p0 = cur
        if p0.x == p.x && p0.y == p.y { return }
        if rxIn == 0 || ryIn == 0 {
            lineTo(p)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (p0.x - p.x) / 2
        let dy = (p0.y - p.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        var rx = rxIn
        var ry = ryIn
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            let s = lambda.squareRoot()
            rx *= s
            ry *= s
        }

        let rx2 = rx * rx
        let ry2 = ry * ry
        let denom = rx2 * y1 * y1 + ry2 * x1 * x1
        var coef = ((rx2 * ry2 - denom) / denom).squareRoot()
        if coef.isNaN { coef = 0 }  // rounding when the radii were just scaled up
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry
        let cyp = -coef * ry * x1 / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p.y) / 2

        let theta1 = atan2((y1 - cyp) / ry, (x1 - cxp) / rx)
        let theta2 = atan2((-y1 - cyp) / ry, (-x1 - cxp) / rx)
        var delta = theta2 - theta1
        // Absurd inputs (1e300 radii) overflow to inf/NaN; a straight line is the safe fallback.
        guard delta.isFinite, cx.isFinite, cy.isFinite else {
            lineTo(p)
            return
        }
        if sweep && delta < 0 { delta += 2 * .pi }
        if !sweep && delta > 0 { delta -= 2 * .pi }

        let segments = max(1, Int((abs(delta) / (.pi / 2) - 1e-9).rounded(.up)))
        let step = delta / Double(segments)
        let k = 4.0 / 3.0 * tan(step / 4)

        // Point and tangent on the rotated ellipse at angle `a`.
        func sample(_ a: Double) -> (p: Point, t: Point) {
            let ca = cos(a), sa = sin(a)
            let px = rx * ca, py = ry * sa
            let tx = -rx * sa, ty = ry * ca
            return (
                Point(x: cosPhi * px - sinPhi * py + cx, y: sinPhi * px + cosPhi * py + cy),
                Point(x: cosPhi * tx - sinPhi * ty, y: sinPhi * tx + cosPhi * ty)
            )
        }

        var a = theta1
        var from = sample(a)
        for i in 0..<segments {
            a += step
            let to = sample(a)
            // Land exactly on the requested end point so rounding never accumulates.
            let end = i == segments - 1 ? p : to.p
            cubicTo(
                Point(x: from.p.x + k * from.t.x, y: from.p.y + k * from.t.y),
                Point(x: to.p.x - k * to.t.x, y: to.p.y - k * to.t.y),
                end)
            from = to
        }
    }

    // MARK: Scanning

    private func argCount(_ b: UInt8) -> Int? {
        switch upper(b) {
        case UInt8(ascii: "M"), UInt8(ascii: "L"), UInt8(ascii: "T"): return 2
        case UInt8(ascii: "H"), UInt8(ascii: "V"): return 1
        case UInt8(ascii: "C"): return 6
        case UInt8(ascii: "S"), UInt8(ascii: "Q"): return 4
        case UInt8(ascii: "A"): return 7
        case UInt8(ascii: "Z"): return 0
        default: return nil
        }
    }

    private func upper(_ b: UInt8) -> UInt8 { b & 0xDF }

    private func isLetter(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z")) || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
    }

    private func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }

    private func isNumberStart(_ b: UInt8) -> Bool {
        isDigit(b) || b == UInt8(ascii: ".") || b == UInt8(ascii: "-") || b == UInt8(ascii: "+")
    }

    private mutating func skipSeparators() {
        while pos < bytes.count {
            switch bytes[pos] {
            case 0x20, 0x09, 0x0A, 0x0D, 0x0C, UInt8(ascii: ","): pos += 1
            default: return
            }
        }
    }

    private mutating func readArgs(_ count: Int, isArc: Bool) -> Bool {
        for i in 0..<count {
            skipSeparators()
            // Arc flags (4th and 5th numbers) are one digit each, with no separator needed after.
            if isArc && (i == 3 || i == 4) {
                guard pos < bytes.count, bytes[pos] == UInt8(ascii: "0") || bytes[pos] == UInt8(ascii: "1") else { return false }
                args[i] = Double(bytes[pos] - UInt8(ascii: "0"))
                pos += 1
            } else {
                guard let v = readNumber() else { return false }
                args[i] = v
            }
        }
        return true
    }

    /// Reads `[+-]digits[.digits][e[+-]digits]` (either digit run may be empty, not both).
    private mutating func readNumber() -> Double? {
        var i = pos
        var negative = false
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") {
            negative = bytes[i] == UInt8(ascii: "-")
            i += 1
        }
        var mantissa = 0.0
        var digits = 0
        var scale = 0  // power of ten to divide the mantissa by
        while i < bytes.count, isDigit(bytes[i]) {
            mantissa = mantissa * 10 + Double(bytes[i] - UInt8(ascii: "0"))
            digits += 1
            i += 1
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            while i < bytes.count, isDigit(bytes[i]) {
                mantissa = mantissa * 10 + Double(bytes[i] - UInt8(ascii: "0"))
                digits += 1
                scale += 1
                i += 1
            }
        }
        guard digits > 0 else { return nil }
        // An exponent only counts when digits follow ("1e" leaves the "e" to be rejected as a command).
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            var j = i + 1
            var expNegative = false
            if j < bytes.count, bytes[j] == UInt8(ascii: "-") || bytes[j] == UInt8(ascii: "+") {
                expNegative = bytes[j] == UInt8(ascii: "-")
                j += 1
            }
            if j < bytes.count, isDigit(bytes[j]) {
                var e = 0
                while j < bytes.count, isDigit(bytes[j]) {
                    e = min(e * 10 + Int(bytes[j] - UInt8(ascii: "0")), 10_000)
                    j += 1
                }
                scale -= expNegative ? -e : e
                i = j
            }
        }
        pos = i
        let value = scale >= 0 ? mantissa / pow(10, Double(scale)) : mantissa * pow(10, Double(-scale))
        // Overflowed (or inf/inf) numbers count as malformed.
        guard value.isFinite else { return nil }
        return negative ? -value : value
    }
}
