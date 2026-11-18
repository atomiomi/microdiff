import Darwin
import Testing
import MicroDiffCore

@Suite("SVGPath")
struct SVGPathTests {
    // MARK: Helpers

    static func line(_ x: Double, _ y: Double) -> PathCommand { .line(x: x, y: y) }
    static func move(_ x: Double, _ y: Double) -> PathCommand { .move(x: x, y: y) }

    /// Compares commands with a tolerance (exact equality is too strict for parsed decimals).
    func expectClose(_ got: [PathCommand], _ want: [PathCommand], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(got.count == want.count, "count \(got.count) vs \(want.count): \(got)", sourceLocation: sourceLocation)
        for (g, w) in zip(got, want) {
            #expect(Self.numbers(g).count == Self.numbers(w).count, sourceLocation: sourceLocation)
            switch (g, w) {
            case (.close, .close): break
            case (.move, .move), (.line, .line), (.cubic, .cubic):
                for (a, b) in zip(Self.numbers(g), Self.numbers(w)) {
                    #expect(abs(a - b) < 1e-9, "\(g) vs \(w)", sourceLocation: sourceLocation)
                }
            default:
                Issue.record("\(g) vs \(w)", sourceLocation: sourceLocation)
            }
        }
    }

    static func numbers(_ c: PathCommand) -> [Double] {
        switch c {
        case let .move(x, y), let .line(x, y): return [x, y]
        case let .cubic(a, b, c, d, x, y): return [a, b, c, d, x, y]
        case .close: return []
        }
    }

    static func endPoint(_ c: PathCommand) -> (Double, Double)? {
        switch c {
        case let .move(x, y), let .line(x, y), let .cubic(_, _, _, _, x, y): return (x, y)
        case .close: return nil
        }
    }

    /// End point of the last command that has one.
    static func lastPoint(_ cmds: [PathCommand]) -> (Double, Double)? {
        cmds.reversed().lazy.compactMap(endPoint).first
    }

    /// Samples every cubic of a path at `steps + 1` parameter values (the curve starts at the previous end point).
    static func sample(_ cmds: [PathCommand], steps: Int = 8) -> [(Double, Double)] {
        var pts: [(Double, Double)] = []
        var cur = (0.0, 0.0)
        for c in cmds {
            switch c {
            case let .move(x, y), let .line(x, y):
                cur = (x, y)
            case let .cubic(c1x, c1y, c2x, c2y, x, y):
                for i in 0...steps {
                    let t = Double(i) / Double(steps), u = 1 - t
                    let px = u * u * u * cur.0 + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * x
                    let py = u * u * u * cur.1 + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * y
                    pts.append((px, py))
                }
                cur = (x, y)
            case .close: break
            }
        }
        return pts
    }

    // MARK: Basic commands

    @Test func moveLineAbsoluteAndRelative() {
        expectClose(SVGPath.parse("M1 2L3 4"), [Self.move(1, 2), Self.line(3, 4)])
        expectClose(SVGPath.parse("m1 2l3 4"), [Self.move(1, 2), Self.line(4, 6)])
        expectClose(SVGPath.parse("M1 2 m1 1"), [Self.move(1, 2), Self.move(2, 3)])
    }

    @Test func relativeFirstMoveIsAbsolute() {
        expectClose(SVGPath.parse("m5 5"), [Self.move(5, 5)])
    }

    @Test func horizontalAndVertical() {
        expectClose(SVGPath.parse("M1 1H5V7"), [Self.move(1, 1), Self.line(5, 1), Self.line(5, 7)])
        expectClose(SVGPath.parse("M1 1h5v7"), [Self.move(1, 1), Self.line(6, 1), Self.line(6, 8)])
    }

    @Test func implicitLineToAfterMove() {
        expectClose(SVGPath.parse("M0 0 1 1 2 2"), [Self.move(0, 0), Self.line(1, 1), Self.line(2, 2)])
        expectClose(SVGPath.parse("m1 1 1 1 1 1"), [Self.move(1, 1), Self.line(2, 2), Self.line(3, 3)])
    }

    @Test func repeatedGroupsRepeatTheCommand() {
        expectClose(SVGPath.parse("M0 0h1 2 3"), [Self.move(0, 0), Self.line(1, 0), Self.line(3, 0), Self.line(6, 0)])
        expectClose(
            SVGPath.parse("M0 0C1 1 2 2 3 3 4 4 5 5 6 6"),
            [Self.move(0, 0), .cubic(c1x: 1, c1y: 1, c2x: 2, c2y: 2, x: 3, y: 3), .cubic(c1x: 4, c1y: 4, c2x: 5, c2y: 5, x: 6, y: 6)])
    }

    @Test func cubicAbsoluteAndRelative() {
        expectClose(
            SVGPath.parse("M1 1C2 2 3 3 4 4"),
            [Self.move(1, 1), .cubic(c1x: 2, c1y: 2, c2x: 3, c2y: 3, x: 4, y: 4)])
        expectClose(
            SVGPath.parse("M1 1c1 2 3 4 5 6"),
            [Self.move(1, 1), .cubic(c1x: 2, c1y: 3, c2x: 4, c2y: 5, x: 6, y: 7)])
    }

    @Test func smoothCubicReflectsPreviousControlPoint() {
        // After C with c2 = (3,3) ending at (4,4), S's first control point is (5,5).
        expectClose(
            SVGPath.parse("M1 1C2 2 3 3 4 4S6 6 7 7"),
            [Self.move(1, 1), .cubic(c1x: 2, c1y: 2, c2x: 3, c2y: 3, x: 4, y: 4),
             .cubic(c1x: 5, c1y: 5, c2x: 6, c2y: 6, x: 7, y: 7)])
        // Relative S.
        expectClose(
            SVGPath.parse("M1 1C2 2 3 3 4 4s2 2 3 3"),
            [Self.move(1, 1), .cubic(c1x: 2, c1y: 2, c2x: 3, c2y: 3, x: 4, y: 4),
             .cubic(c1x: 5, c1y: 5, c2x: 6, c2y: 6, x: 7, y: 7)])
    }

    @Test func smoothCubicWithoutPreviousCurveUsesCurrentPoint() {
        expectClose(
            SVGPath.parse("M1 1S3 3 4 4"),
            [Self.move(1, 1), .cubic(c1x: 1, c1y: 1, c2x: 3, c2y: 3, x: 4, y: 4)])
        // A previous Q is not the same family.
        let cmds = SVGPath.parse("M0 0Q3 0 6 0S9 9 10 10")
        guard case let .cubic(c1x, c1y, _, _, _, _) = cmds[2] else { Issue.record("expected cubic"); return }
        #expect(c1x == 6 && c1y == 0)
    }

    @Test func quadraticBecomesCubic() {
        // control points are 2/3 of the way from each end to the control point.
        expectClose(
            SVGPath.parse("M0 0Q3 6 6 0"),
            [Self.move(0, 0), .cubic(c1x: 2, c1y: 4, c2x: 4, c2y: 4, x: 6, y: 0)])
        expectClose(
            SVGPath.parse("M0 0q3 6 6 0"),
            [Self.move(0, 0), .cubic(c1x: 2, c1y: 4, c2x: 4, c2y: 4, x: 6, y: 0)])
    }

    @Test func smoothQuadraticReflectsPreviousControlPoint() {
        // Q control (3,6) reflected through (6,0) gives (9,-6): the second curve is the mirror image.
        expectClose(
            SVGPath.parse("M0 0Q3 6 6 0T12 0"),
            [Self.move(0, 0), .cubic(c1x: 2, c1y: 4, c2x: 4, c2y: 4, x: 6, y: 0),
             .cubic(c1x: 8, c1y: -4, c2x: 10, c2y: -4, x: 12, y: 0)])
        // Relative t, and T after T keeps reflecting.
        let cmds = SVGPath.parse("M0 0Q3 6 6 0t6 0t6 0")
        #expect(cmds.count == 4)
        guard case let .cubic(c1x, c1y, _, _, x, _) = cmds[3] else { Issue.record("expected cubic"); return }
        // Previous control (9,-6) reflected through (12,0) is (15,6).
        #expect(abs(c1x - (12 + 2.0 / 3 * (15 - 12))) < 1e-9)
        #expect(abs(c1y - 2.0 / 3 * 6) < 1e-9)
        #expect(x == 18)
    }

    @Test func smoothQuadraticWithoutPreviousCurveUsesCurrentPoint() {
        // Control point = current point, so the cubic degenerates to a straight run.
        expectClose(
            SVGPath.parse("M0 0T6 0"),
            [Self.move(0, 0), .cubic(c1x: 0, c1y: 0, c2x: 2, c2y: 0, x: 6, y: 0)])
    }

    @Test func closeReturnsToSubpathStart() {
        // The relative line after z is relative to the subpath start (2,3), not the last point.
        expectClose(
            SVGPath.parse("M2 3L10 3L10 9zl1 1"),
            [Self.move(2, 3), Self.line(10, 3), Self.line(10, 9), .close, Self.line(3, 4)])
        expectClose(SVGPath.parse("M0 0 L1 0 Z M5 5 l1 0 z"), [
            Self.move(0, 0), Self.line(1, 0), .close, Self.move(5, 5), Self.line(6, 5), .close,
        ])
    }

    @Test func closeTwiceKeepsStart() {
        expectClose(SVGPath.parse("M1 1h4zZh2"), [Self.move(1, 1), Self.line(5, 1), .close, .close, Self.line(3, 1)])
    }

    // MARK: Number forms

    @Test(arguments: [
        ("M.5.5", 0.5, 0.5),
        ("M-.5-.5", -0.5, -0.5),
        ("M1.5.5", 1.5, 0.5),
        ("M2-2", 2.0, -2.0),
        ("M1e-3 2e2", 0.001, 200.0),
        ("M1E2,3e+1", 100.0, 30.0),
        ("M+3 +4", 3.0, 4.0),
        ("M 1,2", 1.0, 2.0),
        ("M\t1\n2", 1.0, 2.0),
        ("M3. 4", 3.0, 4.0),
        ("M0.1 0.2", 0.1, 0.2),
    ])
    func numberForms(input: String, x: Double, y: Double) {
        let cmds = SVGPath.parse(input)
        #expect(cmds.count == 1)
        guard case let .move(mx, my)? = cmds.first else { Issue.record("no move for \(input)"); return }
        #expect(abs(mx - x) < 1e-12 && abs(my - y) < 1e-12, "\(input) -> \(mx) \(my)")
    }

    @Test func backToBackNumbersAcrossCommands() {
        expectClose(SVGPath.parse("M1 1l1.5.5-2-2"), [Self.move(1, 1), Self.line(2.5, 1.5), Self.line(0.5, -0.5)])
    }

    // MARK: Arcs

    @Test func gluedArcFlags() {
        // "011-1": large=0, sweep=1, then x=1, y=-1.
        let a = SVGPath.parse("M0 0a2 2 0 011-1")
        let b = SVGPath.parse("M0 0a2 2 0 0 1 1-1")
        #expect(a == b)
        #expect(Self.lastPoint(a)! == (1, -1))
        // "1 0 4 0" with spaces vs "a2 2 0 1 0 4 0".
        let c = SVGPath.parse("M0 0a2 2 0 1 0 4 0")
        #expect(Self.lastPoint(c)! == (4, 0))
        #expect(SVGPath.parse("M0 0a2 2 0 10 4 0") == c)
    }

    @Test func fullCircleAsTwoHalfArcsStaysOnTheCircle() throws {
        let cmds = SVGPath.parse("M2 12a10 10 0 1 0 20 0a10 10 0 1 0-20 0")
        for p in Self.sample(cmds, steps: 10) {
            let d = hypot(p.0 - 12, p.1 - 12)
            #expect(abs(d - 10) < 0.01, "distance \(d) at \(p)")
        }
        let end = try #require(Self.lastPoint(cmds))
        #expect(end == (2, 12))
        // Each half turn is split into two quarter-turn cubics.
        #expect(cmds.count == 1 + 4)
    }

    @Test func quarterArcEndpointAndTangents() throws {
        // From (10,0) to (0,10) around the origin; angles grow toward +y, so sweep=1.
        let cmds = SVGPath.parse("M10 0A10 10 0 0 1 0 10")
        #expect(cmds.count == 2)
        guard case let .cubic(c1x, c1y, c2x, c2y, x, y) = cmds[1] else { Issue.record("expected cubic"); return }
        #expect(abs(x) < 1e-12 && y == 10)
        // Kappa for a quarter circle: 4/3*tan(pi/8) * r = 5.5228...
        let k = 4.0 / 3.0 * tan(Double.pi / 8) * 10
        // Start tangent is vertical (along +y, leaving (10,0) toward (0,10)).
        #expect(abs(c1x - 10) < 1e-9 && abs(c1y - k) < 1e-9)
        // End tangent is horizontal at (0,10).
        #expect(abs(c2x - k) < 1e-9 && abs(c2y - 10) < 1e-9)
        for p in Self.sample(cmds) {
            #expect(abs(hypot(p.0, p.1) - 10) < 0.01)
        }
    }

    @Test func largeArcIsSplitIntoSegmentsOfAtMostNinetyDegrees() {
        // Three quarters of a circle needs 3 cubics; a sliver needs 1.
        #expect(SVGPath.parse("M10 0A10 10 0 1 1 0 -10").count == 1 + 3)
        #expect(SVGPath.parse("M10 0A10 10 0 0 1 9.9 1").count == 1 + 1)
        // Exactly 180 degrees: two segments.
        #expect(SVGPath.parse("M0 0A5 5 0 0 1 10 0").count == 1 + 2)
    }

    @Test func zeroRadiusIsALine() {
        expectClose(SVGPath.parse("M0 0A0 5 0 0 1 10 10"), [Self.move(0, 0), Self.line(10, 10)])
        expectClose(SVGPath.parse("M0 0a5 0 0 0 1 10 10"), [Self.move(0, 0), Self.line(10, 10)])
    }

    @Test func identicalEndpointsEmitNothing() {
        expectClose(SVGPath.parse("M3 3A5 5 0 0 1 3 3"), [Self.move(3, 3)])
        expectClose(SVGPath.parse("M3 3a5 5 0 1 1 0 0"), [Self.move(3, 3)])
    }

    @Test func tooSmallRadiiAreScaledUp() throws {
        let cmds = SVGPath.parse("M0 0A1 1 0 0 1 10 0")
        let end = try #require(Self.lastPoint(cmds))
        #expect(end == (10, 0))
        // Scaled to the smallest fitting radius, it becomes a half circle of radius 5.
        let ys = Self.sample(cmds, steps: 20).map { abs($0.1) }
        #expect(abs(ys.max()! - 5) < 0.01)
        for p in Self.sample(cmds, steps: 20) {
            #expect(abs(hypot(p.0 - 5, p.1) - 5) < 0.01)
        }
    }

    @Test(arguments: [
        // (large, sweep, expected sign of the bulge, expected bulge size). Chord (0,0)-(10,0), r=10, y points down.
        ("M0 0A10 10 0 0 1 10 0", -1.0, 1.340),
        ("M0 0A10 10 0 1 1 10 0", -1.0, 18.660),
        ("M0 0A10 10 0 0 0 10 0", 1.0, 1.340),
        ("M0 0A10 10 0 1 0 10 0", 1.0, 18.660),
    ])
    func flagCombinationsPickTheFourArcs(input: String, sign: Double, size: Double) throws {
        let cmds = SVGPath.parse(input)
        let end = try #require(Self.lastPoint(cmds))
        #expect(end == (10, 0))
        let pts = Self.sample(cmds, steps: 40)
        let far = try #require(pts.max { abs($0.1) < abs($1.1) })
        #expect(far.1 * sign > 0)
        #expect(abs(abs(far.1) - size) < 0.02, "bulge \(far.1)")
        // Every point lies on a radius-10 circle (its center is (5, -/+8.66)).
        let cy = -sign * 75.0.squareRoot() * (size < 5 ? 1 : -1)
        for p in pts { #expect(abs(hypot(p.0 - 5, p.1 - cy) - 10) < 0.02) }
    }

    @Test func rotatedEllipseArc() throws {
        // A 90-degree rotated ellipse (rx=10, ry=5) is the same as an unrotated one with radii swapped.
        let rotated = SVGPath.parse("M0 0A10 5 90 0 1 5 10")
        let swapped = SVGPath.parse("M0 0A5 10 0 0 1 5 10")
        let a = Self.sample(rotated, steps: 6), b = Self.sample(swapped, steps: 6)
        #expect(a.count == b.count)
        for (p, q) in zip(a, b) { #expect(abs(p.0 - q.0) < 1e-6 && abs(p.1 - q.1) < 1e-6) }
        // And a 45-degree one still ends exactly where asked.
        let end = try #require(Self.lastPoint(SVGPath.parse("M0 0a10 4 45 1 0 7 3")))
        #expect(end == (7, 3))
    }

    // MARK: Real icons

    static let icons: [(name: String, d: String, end: (Double, Double))] = [
        ("folder", "M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z", (4, 20)),
        ("folder-open", "m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2", (20, 10)),
        ("chevron", "m16 18 6-6-6-6", (16, 6)),
        ("corner", "M18 9a9 9 0 0 1-9 9", (9, 18)),
        ("book", "M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4 4 4 0 0 1 4-4h5a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-6a3 3 0 0 0-3 3 3 3 0 0 0-3-3z", (9, 18)),
        ("arrow", "m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21", (6, 21)),
    ]

    @Test(arguments: icons.indices)
    func realIconsParseInsideTheViewBox(index: Int) throws {
        let icon = Self.icons[index]
        let cmds = SVGPath.parse(icon.d)
        #expect(!cmds.isEmpty, "\(icon.name)")
        guard case .move = cmds[0] else { Issue.record("\(icon.name) must start with a move"); return }
        for c in cmds {
            for n in Self.numbers(c) { #expect(n >= -0.5 && n <= 24.5, "\(icon.name): \(c)") }
        }
        let end = try #require(Self.lastPoint(cmds))
        #expect(abs(end.0 - icon.end.0) < 1e-9 && abs(end.1 - icon.end.1) < 1e-9, "\(icon.name) ends at \(end)")
    }

    @Test func closedIconsEndWithClose() {
        #expect(SVGPath.parse(Self.icons[0].d).last == .close)
        #expect(SVGPath.parse(Self.icons[4].d).last == .close)
        #expect(SVGPath.parse(Self.icons[1].d).last != .close)
    }

    @Test func chevronExactCommands() {
        expectClose(SVGPath.parse(Self.icons[2].d), [Self.move(16, 18), Self.line(22, 12), Self.line(16, 6)])
    }

    @Test func iconArcsLandOnTheirEndPoints() {
        // Each arc in the folder icon begins at the previous end point; check the whole chain by re-tracing.
        let cmds = SVGPath.parse(Self.icons[0].d)
        let ends = cmds.compactMap(Self.endPoint)
        #expect(ends.first! == (20, 20))
        #expect(ends.contains { $0 == (22, 18) })
        #expect(ends.contains { abs($0.0 - 10.41) < 1e-9 && abs($0.1 - 5.1) < 1e-9 })
    }

    // MARK: Malformed input

    @Test(arguments: [
        ("", 0), ("M", 0), ("M 1", 0), ("X 1 2", 0), ("   ", 0), (",", 0), ("1 2", 0), ("L 1 2", 0),
        ("M1 1 L", 1), ("M1 1 L 5", 1), ("M1 1 L 2 2 L 3", 2), ("M1 1 X 2 2", 1), ("M1 1 1", 1),
        ("M1 1 L 2 2 !", 2), ("M1 1 z 5 5", 2), ("M1 1 a1 1 0 2 0 5 5", 1), ("M1 1 e5", 1),
        ("M1 1 C 1 2 3", 1), ("M1e 1", 0), ("M--1 2", 0), ("M1 1 L 2 2 \u{1F600}", 2), ("M. 1", 0),
    ])
    func malformedInputKeepsTheValidPrefix(input: String, count: Int) {
        #expect(SVGPath.parse(input).count == count, "\(input.debugDescription)")
    }

    @Test func absurdNumbersDoNotCrash() {
        _ = SVGPath.parse("M1e999999999999 1")
        _ = SVGPath.parse("M1e-999999999999 1")
        _ = SVGPath.parse("M99999999999999999999999999999999999 1")
        _ = SVGPath.parse("M0 0A1e300 1e300 0 1 1 1e300 1e300")
        _ = SVGPath.parse("M0 0A1e-300 1e-300 0 1 1 1 1")
    }
}

// MARK: Forms used by the file icon set

extension SVGPathTests {
    @Test func compactArcFlagsAfterSmallRadii() {
        // "a.5.5 0 100-1": radii .5 and .5, rotation 0, flags 1 and 0, then dx 0 and dy -1.
        let cmds = SVGPath.parse("M3 3a.5.5 0 100-1")
        #expect(Self.lastPoint(cmds)! == (3, 2))
        #expect(cmds == SVGPath.parse("M3 3a0.5 0.5 0 1 0 0 -1"))
        // Large arc over a diameter-sized chord: two quarter turns.
        #expect(cmds.count == 3)
    }

    @Test func compactArcFlagsWithNegativeEndPoint() {
        let cmds = SVGPath.parse("M5 5a2 2 0 01-2 2")
        #expect(Self.lastPoint(cmds)! == (3, 7))
        #expect(cmds == SVGPath.parse("M5 5a2 2 0 0 1 -2 2"))
    }

    @Test func repeatedArcAfterGluedFlags() {
        // Second group repeats the arc command: "a1.5 1.5 0 10-2.6 1.5 1.5 1.5 0 002.6-1.5".
        let cmds = SVGPath.parse("M4.54 10a1.5 1.5 0 10-2.6 1.5 1.5 1.5 0 002.6-1.5")
        let end = Self.lastPoint(cmds)!
        #expect(abs(end.0 - 4.54) < 1e-9 && abs(end.1 - 10) < 1e-9)
    }

    @Test func numbersWithoutLeadingZeroesAndGluedSigns() {
        expectClose(SVGPath.parse("M.5.5l1.5-2"), [Self.move(0.5, 0.5), Self.line(2, -1.5)])
        expectClose(SVGPath.parse("M1,2,3,4"), [Self.move(1, 2), Self.line(3, 4)])
        expectClose(SVGPath.parse("m-.01 0"), [Self.move(-0.01, 0)])
    }

    @Test func smoothCubicRelativeAfterCurve() {
        // c then s: the second curve's first control point mirrors the first curve's second one.
        let cmds = SVGPath.parse("M0 0c1 0 2 1 2 2s1 2 2 2")
        guard case let .cubic(_, _, c2x, c2y, ex, ey) = cmds[1], case let .cubic(c1x, c1y, _, _, x, y) = cmds[2] else {
            Issue.record("expected cubics")
            return
        }
        #expect(abs(c1x - (2 * ex - c2x)) < 1e-9 && abs(c1y - (2 * ey - c2y)) < 1e-9)
        #expect(x == 4 && y == 4)
    }

    @Test func movesInsideOnePathKeepTheCurrentPointRules() {
        // "m.01 0" style relative move after a close continues from the subpath start.
        expectClose(SVGPath.parse("M2 2h1v1zm1 1"), [
            Self.move(2, 2), Self.line(3, 2), Self.line(3, 3), .close, Self.move(3, 3),
        ])
    }

    @Test func multiplePolygonsAndCirclesFromOnePath() {
        // Three circles drawn with arcs and Z, as in the repo icon.
        let cmds = SVGPath.parse("M11.5 14.5a1 1 0 11-2 0 1 1 0 012 0ZM11.5 9.5a1 1 0 11-2 0 1 1 0 012 0Z")
        #expect(cmds.filter { $0 == .close }.count == 2)
        #expect(cmds.filter { if case .move = $0 { true } else { false } }.count == 2)
    }
}
