import AppKit
import CoreGraphics
import MicroDiffCore
@testable import MicroDiffUI

/// Offscreen drawing for the UI benchmarks: real views, a bitmap instead of a window.
@MainActor
enum UIHarness {
    static let scale: CGFloat = 2

    /// A 2x RGBA bitmap context set up like a flipped view (y grows downwards).
    static func makeContext(width: Int, height: Int) -> CGContext {
        let ctx = CGContext(
            data: nil, width: width * Int(scale), height: height * Int(scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(height) * scale)
        ctx.scaleBy(x: scale, y: -scale)
        return ctx
    }

    static func codeView(_ document: TextDocument) -> CodeView {
        _ = NSApplication.shared
        let view = CodeView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.layoutSubtreeIfNeeded()
        view.setDocument(document, keepScroll: false)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// A sidebar-sized tree view, still without rows.
    static func treeView() -> TreeView {
        _ = NSApplication.shared
        let view = TreeView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
        view.layoutSubtreeIfNeeded()
        return view
    }

    static func resetCodeView(_ view: CodeView, _ document: TextDocument) {
        view.setDocument(document, keepScroll: false)
    }

    /// The app's window controller (never shown) with `file` open in the read view.
    static func controller(_ path: String, open file: String) -> MainWindowController {
        _ = NSApplication.shared
        let controller = MainWindowController(path: path)
        controller.window.setContentSize(NSSize(width: 1180, height: 720))
        controller.workspace.scanNow()
        controller.workspace.openFile(path + "/" + file, mode: .read, pin: true, synchronously: true)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    static func editor(_ controller: MainWindowController) -> EditorView? {
        (controller.window.contentView as? RootView)?.editor
    }

    /// Draws a view into a bitmap the way the window would draw it (layout first).
    static func paint(_ view: NSView, into rep: NSBitmapImageRep? = nil) {
        view.layoutSubtreeIfNeeded()
        guard let rep = rep ?? view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
    }

    /// Scrolls down by one page less two lines, like the Page Down key.
    static func pageDown(_ view: CodeView) {
        view.scroll(by: CGPoint(x: 0, y: view.visibleContentRect.height - 40))
    }
}
