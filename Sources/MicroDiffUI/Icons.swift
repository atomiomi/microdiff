import AppKit
import MicroDiffCore

/// The single-color glyph icons used in the app (file and folder icons are `FileIcon`).
///
/// Shapes are from the Lucide icon set (https://lucide.dev, ISC License, Copyright (c) Lucide Contributors),
/// drawn on a 24x24 grid with round strokes.
enum Icon: Int, CaseIterable {
    case branch, close, chevronDown, unfold

    private enum Shape {
        case path(String)
        case circle(cx: CGFloat, cy: CGFloat, r: CGFloat)
    }

    private var shapes: [Shape] {
        switch self {
        case .branch:
            [.path("M15 6a9 9 0 0 0-9 9V3"), .circle(cx: 18, cy: 6, r: 3), .circle(cx: 6, cy: 18, r: 3)]
        case .close:
            [.path("M18 6 6 18"), .path("m6 6 12 12")]
        case .chevronDown:
            [.path("m6 9 6 6 6-6")]
        case .unfold:
            [.path("M12 22v-6"), .path("M12 8V2"), .path("M4 12H2"), .path("M10 12H8"), .path("M16 12h-2"),
             .path("M22 12h-2"), .path("m15 19-3 3-3-3"), .path("m15 5-3-3-3 3")]
        }
    }

    /// One outline per icon on the 24x24 grid, built on first use.
    private static var paths: [CGPath?] = Array(repeating: nil, count: Icon.allCases.count)

    private var path: CGPath {
        if let cached = Self.paths[rawValue] { return cached }
        let path = CGMutablePath()
        for shape in shapes {
            switch shape {
            case let .path(data):
                for command in SVGPath.parse(data) {
                    switch command {
                    case let .move(x, y): path.move(to: CGPoint(x: x, y: y))
                    case let .line(x, y): path.addLine(to: CGPoint(x: x, y: y))
                    case let .cubic(c1x, c1y, c2x, c2y, x, y):
                        path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
                    case .close: path.closeSubpath()
                    }
                }
            case let .circle(cx, cy, r):
                path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
        }
        Self.paths[rawValue] = path
        return path
    }

    /// Strokes the icon into a `size` x `size` square whose top-left corner is at (x, y). The context is flipped.
    func draw(in ctx: CGContext, x: CGFloat, y: CGFloat, size: CGFloat = Theme.iconSize, color: CGColor, weight: CGFloat = 1.9) {
        ctx.saveGState()
        ctx.translateBy(x: x, y: y)
        ctx.scaleBy(x: size / 24, y: size / 24)
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(weight)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
