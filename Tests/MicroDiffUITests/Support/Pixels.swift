import AppKit
@testable import MicroDiffUI

/// A color as 8-bit components.
struct RGB: Equatable, CustomStringConvertible {
    var r: Int
    var g: Int
    var b: Int

    init(_ r: Int, _ g: Int, _ b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hex: UInt32) {
        self.init(Int((hex >> 16) & 0xFF), Int((hex >> 8) & 0xFF), Int(hex & 0xFF))
    }

    /// Opaque color of a CGColor, converted to sRGB.
    init(_ color: CGColor) {
        let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? color
        let c = srgb.components ?? [0, 0, 0, 1]
        func byte(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
        self.init(byte(c[0]), byte(c[1]), byte(c[2]))
    }

    /// `top` (with its alpha) painted over the opaque `base`.
    static func composite(_ top: CGColor, over base: CGColor) -> RGB {
        composite(top, over: RGB(base))
    }

    static func composite(_ top: CGColor, over base: RGB) -> RGB {
        let t = RGB(top)
        let alpha = top.alpha
        func mix(_ x: Int, _ y: Int) -> Int { Int((Double(y) * (1 - alpha) + Double(x) * alpha).rounded()) }
        return RGB(mix(t.r, base.r), mix(t.g, base.g), mix(t.b, base.b))
    }

    func isClose(to other: RGB, tolerance: Int = 3) -> Bool {
        abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
    }

    var description: String { "rgb(\(r), \(g), \(b))" }
}

/// A rectangle of pixels. Origin top-left.
struct PixelRegion {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    static func columns(_ x: Int, _ width: Int, height: Int) -> PixelRegion {
        PixelRegion(x: x, y: 0, width: width, height: height)
    }
}

/// Read-only RGBA pixels, row 0 on top.
struct Bitmap {
    let width: Int
    let height: Int
    private let bytes: [UInt8]
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private init(context: CGContext) {
        width = context.width
        height = context.height
        let rowBytes = context.bytesPerRow
        let raw = context.data!.assumingMemoryBound(to: UInt8.self)
        let tight = width * 4
        bytes = [UInt8](unsafeUninitializedCapacity: tight * height) { buffer, count in
            for y in 0..<context.height {
                (buffer.baseAddress! + y * tight).update(from: raw + y * rowBytes, count: tight)
            }
            count = tight * context.height
        }
    }

    private static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// Draws with a flipped (y grows down) context, like the app's views expect. Pixels start transparent
    /// unless a background is given.
    @MainActor
    static func render(width: Int, height: Int, background: CGColor? = nil, _ draw: (CGContext) -> Void) -> Bitmap {
        let ctx = makeContext(width: width, height: height)
        if let background {
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        draw(ctx)
        return Bitmap(context: ctx)
    }

    /// Decodes PNG data. Returns nil when it is not an image.
    static func decode(png data: Data) -> Bitmap? {
        guard let rep = NSBitmapImageRep(data: data), let image = rep.cgImage else { return nil }
        let ctx = makeContext(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Bitmap(context: ctx)
    }

    func pixel(_ x: Int, _ y: Int) -> (rgb: RGB, alpha: Int) {
        let i = (y * width + x) * 4
        return (RGB(Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])), Int(bytes[i + 3]))
    }

    func rgb(_ x: Int, _ y: Int) -> RGB { pixel(x, y).rgb }

    private func clamp(_ region: PixelRegion?) -> (x: Range<Int>, y: Range<Int>) {
        guard let region else { return (0..<width, 0..<height) }
        let x0 = min(width, max(0, region.x)), y0 = min(height, max(0, region.y))
        return (x0..<max(x0, min(width, region.x + region.width)), y0..<max(y0, min(height, region.y + region.height)))
    }

    /// Number of pixels in the region that satisfy the test.
    func count(in region: PixelRegion? = nil, where test: (RGB, Int) -> Bool) -> Int {
        let (xs, ys) = clamp(region)
        return bytes.withUnsafeBufferPointer { p in
            var total = 0
            for y in ys {
                var i = (y * width + xs.lowerBound) * 4
                for _ in xs {
                    if test(RGB(Int(p[i]), Int(p[i + 1]), Int(p[i + 2])), Int(p[i + 3])) { total += 1 }
                    i += 4
                }
            }
            return total
        }
    }

    func count(near color: RGB, in region: PixelRegion? = nil, tolerance: Int = 3) -> Int {
        let (xs, ys) = clamp(region)
        return bytes.withUnsafeBufferPointer { p in
            var total = 0
            for y in ys {
                var i = (y * width + xs.lowerBound) * 4
                for _ in xs {
                    if abs(Int(p[i]) - color.r) <= tolerance, abs(Int(p[i + 1]) - color.g) <= tolerance,
                       abs(Int(p[i + 2]) - color.b) <= tolerance { total += 1 }
                    i += 4
                }
            }
            return total
        }
    }

    /// Pixels that are not (nearly) the given color, e.g. text on a plain background.
    func count(notNear color: RGB, in region: PixelRegion? = nil, tolerance: Int = 3) -> Int {
        let (xs, ys) = clamp(region)
        return xs.count * ys.count - count(near: color, in: region, tolerance: tolerance)
    }

    /// Pixels with any ink at all (alpha above zero).
    func countVisible(in region: PixelRegion? = nil) -> Int {
        count(in: region) { _, alpha in alpha > 0 }
    }

    /// True when every pixel of the region is (nearly) the given color.
    func isUniform(_ color: RGB, in region: PixelRegion, tolerance: Int = 3) -> Bool {
        count(notNear: color, in: region, tolerance: tolerance) == 0
    }
}

// MARK: - Rendering the app's views

enum Render {
    /// A canvas view (tree, code) drawn into its own bitmap over the window background.
    @MainActor
    static func canvas(_ view: CanvasScrollView) -> Bitmap {
        view.layoutSubtreeIfNeeded()
        return Bitmap.render(width: Int(view.bounds.width), height: Int(view.bounds.height), background: Theme.background) {
            view.render(in: $0)
        }
    }

    /// The tab bar's `draw(_:)` into a bitmap.
    @MainActor
    static func tabBar(_ bar: FileTabBarView) -> Bitmap {
        Bitmap.render(width: Int(bar.bounds.width), height: Int(bar.bounds.height), background: Theme.background) { ctx in
            let saved = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            bar.draw(bar.bounds)
            NSGraphicsContext.current = saved
        }
    }

    /// An icon on a transparent `canvas` x `canvas` bitmap, its box (`size` square) starting at (`inset`, `inset`).
    @MainActor
    static func icon(_ icon: Icon, size: CGFloat, canvas: Int = 48, inset: Int = 16) -> Bitmap {
        Bitmap.render(width: canvas, height: canvas) {
            icon.draw(in: $0, x: CGFloat(inset), y: CGFloat(inset), size: size, color: Theme.rgb(0xffffff))
        }
    }

    /// Makes sure the shared application exists (windows need it).
    @MainActor
    static func prepareApplication() {
        _ = NSApplication.shared
    }
}
