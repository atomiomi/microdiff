import AppKit

/// Synthetic input events for driving views without a window.
enum Event {
    static func mouse(
        _ type: NSEvent.EventType = .leftMouseDown, at point: CGPoint = .zero, clicks: Int = 1,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    static func key(_ keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)!
    }

    /// A middle-button press. Built from a CGEvent, because NSEvent cannot set the button number.
    static func middleClick(at point: CGPoint) -> NSEvent? {
        guard let cg = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: point, mouseButton: .center) else {
            return nil
        }
        return NSEvent(cgEvent: cg)
    }
}

extension Event {
    /// A trackpad-style scroll (in points, so the views treat the deltas as precise). Positive `dy` scrolls the content down.
    static func scroll(dx: Int32 = 0, dy: Int32 = 0) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
            return nil
        }
        return NSEvent(cgEvent: cg)
    }

    /// A drag event at a point in window coordinates.
    static func drag(inWindowAt point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDragged, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
