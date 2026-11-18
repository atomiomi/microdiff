import AppKit
import MicroDiffCore

@testable import MicroDiffUI

// AppKit lives here and not in the test files: on this toolchain a file cannot import both AppKit/Foundation and Testing.

/// A mouse-down event. The views under test receive the click position separately, so the location does not matter.
@MainActor
func makeMouseDown(clickCount: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(
        with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
}

/// A mouse-down event at a point given in the coordinates of `view`, which must be inside `window`.
@MainActor
func makeMouseDown(in view: NSView, at point: CGPoint, clickCount: Int = 1, window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(
        with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
}

/// An offscreen window (never shown) holding `view` at the given size, laid out.
@MainActor
func hostInWindow(_ view: NSView, width: CGFloat, height: CGFloat) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    view.frame = container.bounds
    container.addSubview(view)
    window.contentView = container
    container.layoutSubtreeIfNeeded()
    return window
}

@MainActor
func makeTreeView(width: CGFloat = 288, height: CGFloat = 400) -> TreeView {
    let tree = TreeView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    tree.layoutSubtreeIfNeeded()
    return tree
}

@MainActor
func makeCodeView(width: CGFloat = 800, height: CGFloat = 500) -> CodeView {
    let view = CodeView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    view.layoutSubtreeIfNeeded()
    return view
}

@MainActor
func point(_ x: Double, _ y: Double) -> CGPoint {
    CGPoint(x: x, y: y)
}

/// The app's real window (never shown) for a throwaway empty folder.
@MainActor
func makeAppWindow() -> NSWindow {
    _ = NSApplication.shared
    let controller = MainWindowController(path: NSTemporaryDirectory())
    controller.window.contentView?.layoutSubtreeIfNeeded()
    retainedControllers.append(controller)
    return controller.window
}

/// Keeps test windows' controllers alive for the life of the test process.
@MainActor private var retainedControllers: [MainWindowController] = []

/// A mouse-moved event at a point given in the coordinates of `view`, which must be inside `window`.
@MainActor
func makeMouseMoved(in view: NSView, at point: CGPoint, window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(
        with: .mouseMoved, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
}

/// Which cursor a view asks for, in words the test files can compare without importing AppKit.
enum CursorKind: Equatable {
    case hand, text, arrow, other
}

@MainActor
func kind(_ cursor: NSCursor) -> CursorKind {
    if cursor === NSCursor.pointingHand { return .hand }
    if cursor === NSCursor.iBeam { return .text }
    if cursor === NSCursor.arrow { return .arrow }
    return .other
}
