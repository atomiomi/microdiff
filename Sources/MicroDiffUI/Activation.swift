import AppKit

/// Bringing the running app to the front when a later start asks for a window.
///
/// Since macOS 14 activation is cooperative: an app in the background that activates itself may be refused.
/// Measured on macOS 26 (started from a terminal): the running app's own `NSApp.activate()` is honored only
/// sometimes; when it is, the app is active within ~10 ms. `NSRunningApplication.activate` called from the
/// launcher process worked every time (~20 ms), `NSWorkspace.openApplication` too (~60 ms).
/// So the running app tries and waits briefly; if it is not active by then, the launcher activates it.
enum Activation {
    /// In the running app: asks to become active and calls back whether it is, within `timeout` seconds.
    static func activate(timeout: Double = 0.05, _ done: @escaping (Bool) -> Void) {
        if NSApp.isActive { return done(true) }
        let wait = ActivationWait(done)
        wait.observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { wait.finish(true) }
        }
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { wait.finish(NSApp.isActive) }
    }

    /// In the launcher, before it exits: the running app at `pid` was not allowed to activate itself.
    static func activateFromOutside(pid: Int32, bundlePath: String?) {
        func isActive() -> Bool { NSRunningApplication(processIdentifier: pid)?.isActive ?? false }

        _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        if waitUntilActive(isActive, timeout: 0.15) { return }
        guard let bundlePath else { return }
        // LaunchServices: like `open -a`, it activates the running copy of the app instead of starting another.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: bundlePath), configuration: configuration) { _, error in
            if let error { FileHandle.standardError.write(Data("microdiff: could not bring the app forward: \(error.localizedDescription)\n".utf8)) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    private static func waitUntilActive(_ isActive: () -> Bool, timeout: Double) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !isActive() {
            if Date() >= deadline { return false }
            usleep(10_000)
        }
        return true
    }
}

/// One wait for activation: finishes once, with the first answer.
private final class ActivationWait {
    var observer: NSObjectProtocol?
    private var done: ((Bool) -> Void)?

    init(_ done: @escaping (Bool) -> Void) { self.done = done }

    func finish(_ active: Bool) {
        guard let done else { return }
        self.done = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        done(active)
    }
}
