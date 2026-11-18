import AppKit
import MicroDiffCore

/// What the command line asked for.
struct LaunchOptions {
    var path: String?
    /// Render the window to this PNG file and quit (developer aid for visual checks).
    var snapshotPath: String?
    var snapshotSize = CGSize(width: 1180, height: 720)
    var sidebarTab: SidebarTab = .changes
    /// Files to open as tabs (relative to the folder); the last one is shown.
    var openFiles: [String] = []
    var mode: ViewMode?
    /// Vertical scroll offset of the code view in a snapshot.
    var snapshotScroll: CGFloat = 0
    /// Print launch timings and memory as JSON once the first scan is on screen, then quit.
    var benchmark = false
    /// Drive the window offscreen through this many rounds of activity, then quit (`scripts/leaks.sh`).
    var soakIterations: Int?

    init(arguments: [String]) {
        let arguments = Array(arguments.dropFirst())
        var index = 0
        /// The word after the current flag, unless there is none or it is another flag.
        func value() -> String? {
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { return nil }
            index += 1
            return arguments[index]
        }
        /// Like `value`, but only takes the word when it is one of `choices`, so `--tab /repo` keeps the path.
        func choice(_ choices: [String]) -> String? {
            guard index + 1 < arguments.count, choices.contains(arguments[index + 1]) else { return nil }
            return value()
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--snapshot": snapshotPath = value()
            case "--tab": if let tab = choice(["changes", "files"]) { sidebarTab = tab == "files" ? .files : .changes }
            case "--open": if let file = value() { openFiles.append(file) }
            case "--mode": if let name = choice(["diff", "file"]) { mode = name == "file" ? .file : .diff }
            case "--bench": benchmark = true
            case "--soak":
                // The count is optional, so a path right after the flag stays the path.
                if index + 1 < arguments.count, let count = Int(arguments[index + 1]) {
                    soakIterations = max(1, count)
                    index += 1
                } else {
                    soakIterations = 50
                }
            case "--scroll": snapshotScroll = CGFloat(Double(value() ?? "") ?? 0)
            case "--size":
                let parts = (value() ?? "").split(separator: "x", omittingEmptySubsequences: false).compactMap { Double($0) }
                if parts.count == 2, parts[0] > 0, parts[1] > 0 { snapshotSize = CGSize(width: parts[0], height: parts[1]) }
            default:
                // Finder passes a "-psn_..." argument; ignore unknown flags.
                if !argument.hasPrefix("-"), path == nil { path = argument }
            }
            index += 1
        }
    }

    /// The folder to open: the argument, else the current directory when started from a terminal.
    /// Nil when started from the Finder, which runs apps in "/".
    var startPath: String? {
        let current = FileManager.default.currentDirectoryPath
        if let path {
            return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: current)).standardizedFileURL.path
        }
        return current == "/" ? nil : current
    }

    /// Renders or measures and quits: runs on its own, never hands its work to a running instance nor takes requests.
    var isStandaloneMode: Bool { snapshotPath != nil || soakIterations != nil || benchmark }

    /// What this start asks a running instance for: the folder (empty from the Finder: only come to the front)
    /// and the files to open.
    var instanceRequest: InstanceRequest {
        InstanceRequest(folder: startPath ?? "", openFiles: openFiles, mode: mode.map { $0 == .file ? "file" : "diff" })
    }
}

/// Launch milestones in milliseconds since the process started, reported in benchmark mode.
enum LaunchTimeline {
    static var marks: [(name: String, ms: Double)] = []

    static func mark(_ name: String) {
        marks.append((name, ProcessMetrics.millisecondsSinceProcessStart()))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private let prescan: BackgroundScan?
    /// The socket later starts send their folders to. Nil in the offscreen modes, or when it could not be had.
    private let server: InstanceServer?
    let windows: WindowManager
    /// The first window, for the benchmark report.
    private weak var controller: MainWindowController?
    /// `kill` (or logging out) quits like Cmd+Q, so the socket file is removed.
    private var terminateSignal: DispatchSourceSignal?

    init(options: LaunchOptions, prescan: BackgroundScan?, server: InstanceServer? = nil, windows: WindowManager = WindowManager()) {
        self.options = options
        self.prescan = prescan
        self.server = server
        self.windows = windows
        super.init()
        guard let server else { return }
        // Requests can arrive at once; until launching is done the window manager keeps them.
        server.start { [weak self] request, responder in
            DispatchQueue.main.async { self?.received(request, responder) }
        }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminateSignal = source
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTimeline.mark("launched")
        NSApp.mainMenu = makeMenu()

        guard let path = options.startPath ?? askForFolder() else {
            NSApp.terminate(nil)
            return
        }

        if let snapshotPath = options.snapshotPath {
            let controller = MainWindowController(path: path)
            let data = controller.renderSnapshot(
                size: options.snapshotSize, sidebarTab: options.sidebarTab, open: options.openFiles, mode: options.mode,
                scroll: options.snapshotScroll)
            let ok = data.map { (try? $0.write(to: URL(fileURLWithPath: snapshotPath))) != nil } ?? false
            exit(ok ? 0 : 1)
        }
        if let iterations = options.soakIterations {
            Soak.run(MainWindowController(path: path), iterations: iterations)
            return
        }

        let controller = windows.makeWindow(path: path)
        self.controller = controller
        controller.onFirstSnapshot = { [weak self] in
            LaunchTimeline.mark("first_snapshot")
            // Arrives before the window is shown when the early scan was quick: continue on the next turn of the run loop.
            DispatchQueue.main.async { self?.firstSnapshotArrived() }
        }
        LaunchTimeline.mark("window_created")
        // `--open <file>` on the command line: start with these tabs (benchmark mode opens its own).
        if !options.benchmark { controller.open(files: options.openFiles, mode: options.mode) }
        controller.workspace.start(prescan: prescan)
        windows.present(controller)
        LaunchTimeline.mark("window_shown")
        NSApp.activate(ignoringOtherApps: true)
        windows.markReady()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        windows.saveFrame()
        server?.close()
    }

    /// Started from the Finder there is no folder yet (apps start in "/"): ask for one.
    private func askForFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func firstSnapshotArrived() {
        if options.benchmark { reportBenchmark() }
    }

    // MARK: - Requests from later starts

    func received(_ request: InstanceRequest, _ responder: InstanceResponder) {
        windows.handle(request) { result in
            switch result {
            case let .refused(message):
                responder.reply(Self.reply(.refused, activated: NSApp.isActive, message: message))
            case let .opened(controller), let .focused(controller):
                let status: InstanceReply.Status = if case .opened = result { .opened } else { .focused }
                controller.window.displayIfNeeded()
                Activation.activate { activated in
                    responder.reply(Self.reply(status, activated: activated))
                }
            }
        }
    }

    private static func reply(_ status: InstanceReply.Status, activated: Bool, message: String? = nil) -> InstanceReply {
        let bundle = Bundle.main.bundleURL
        return InstanceReply(
            status: status, activated: activated, bundlePath: bundle.pathExtension == "app" ? bundle.path : nil, message: message)
    }

    private func reportBenchmark() {
        let firstSnapshot = LaunchTimeline.marks.last { $0.name == "first_snapshot" }?.ms ?? 0
        guard let controller else { return }
        // Open the first changed file too, so the numbers include a real document.
        let workspace = controller.workspace
        if let repo = workspace.snapshot?.repos.first(where: { !$0.changes.isEmpty }), let change = repo.changes.first {
            workspace.openFile(repo.rootPath + "/" + change.path, mode: .diff, pin: true, synchronously: true)
        }
        controller.window.displayIfNeeded()
        // One more turn of the run loop so the frame is really on screen before measuring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let ready = ProcessMetrics.millisecondsSinceProcessStart() - 300
            let megabytes = Double(ProcessMetrics.footprintBytes()) / 1_048_576
            let timeline = LaunchTimeline.marks.map { String(format: "\"%@\": %.1f", $0.name, $0.ms) }.joined(separator: ", ")
            print(String(
                format: "{\"first_snapshot_ms\": %.1f, \"file_open_ms\": %.1f, \"footprint_mb\": %.1f, \"changes\": %d, \"timeline\": {%@}}",
                firstSnapshot, ready, megabytes, workspace.snapshot?.totalChangeCount ?? 0, timeline))
            exit(0)
        }
    }

    // MARK: - Menu

    func makeMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About MicroDiff", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide MicroDiff", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit MicroDiff", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: "MicroDiff"))

        let file = NSMenu(title: "File")
        file.addItem(item("Open Folder…", #selector(openFolder(_:)), "o"))
        file.addItem(item("Close Tab", #selector(closeTab(_:)), "w"))
        let closeWindow = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(closeWindow)
        main.addItem(submenu(file, title: "File"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        let view = NSMenu(title: "View")
        view.addItem(item("Changes", #selector(showChanges(_:)), "1"))
        view.addItem(item("Files", #selector(showFiles(_:)), "2"))
        view.addItem(.separator())
        view.addItem(item("Switch Diff / File", #selector(toggleDiffFile(_:)), "d"))
        view.addItem(item("Refresh", #selector(refresh(_:)), "r"))
        view.addItem(.separator())
        let next = item("Next Tab", #selector(nextTab(_:)), "}")
        let previous = item("Previous Tab", #selector(previousTab(_:)), "{")
        view.addItem(next)
        view.addItem(previous)
        main.addItem(submenu(view, title: "View"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(item("Cycle Through Windows", #selector(cycleWindows(_:)), "`"))
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        // AppKit lists the open windows below these items.
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window

        return main
    }

    /// A menu item handled by this delegate, which passes it on to the window controller.
    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // Every command goes to the window in front.
    @objc func openFolder(_ sender: Any?) { windows.keyController?.openFolder(sender) }
    @objc func closeTab(_ sender: Any?) { windows.keyController?.closeTab(sender) }
    @objc func showChanges(_ sender: Any?) { windows.keyController?.showChanges(sender) }
    @objc func showFiles(_ sender: Any?) { windows.keyController?.showFiles(sender) }
    @objc func toggleDiffFile(_ sender: Any?) { windows.keyController?.toggleDiffFile(sender) }
    @objc func refresh(_ sender: Any?) { windows.keyController?.refresh(sender) }
    @objc func nextTab(_ sender: Any?) { windows.keyController?.nextTab(sender) }
    @objc func previousTab(_ sender: Any?) { windows.keyController?.previousTab(sender) }
    @objc func cycleWindows(_ sender: Any?) { windows.cycleWindows() }
}

package enum MicroDiffApp {
    package static func main() {
        LaunchTimeline.mark("main")
        let options = LaunchOptions(arguments: CommandLine.arguments)
        // One app for all windows: hand the folder to a running instance and quit, or become that instance.
        // Before AppKit starts, so a hand-over costs only a connect and a few bytes.
        let server = options.isStandaloneMode ? nil : claimInstance(options)
        // Git starts working now, in parallel with AppKit starting up.
        let offscreen = options.snapshotPath != nil || options.soakIterations != nil
        let prescan = offscreen ? nil : options.startPath.map { BackgroundScan(path: $0) }
        let app = NSApplication.shared
        LaunchTimeline.mark("app_object")
        let delegate = AppDelegate(options: options, prescan: prescan, server: server)
        app.delegate = delegate
        app.setActivationPolicy(offscreen ? .prohibited : .regular)
        // The delegate is only weakly held by the app.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    /// Exits when a running instance took the request. Otherwise returns the socket this process now owns
    /// (nil when there is none to be had: then this process simply runs on its own, like before).
    private static func claimInstance(_ options: LaunchOptions) -> InstanceServer? {
        let path = InstanceChannel.socketPath(environment: ProcessInfo.processInfo.environment)
        switch InstanceChannel.claim(path: path) {
        case let .owner(server):
            return server
        case .unavailable:
            return nil
        case let .client(connection):
            switch connection.send(options.instanceRequest) {
            case let .replied(reply):
                if reply.status == .refused {
                    FileHandle.standardError.write(Data("microdiff: \(reply.message ?? "refused")\n".utf8))
                    exit(1)
                }
                if !reply.activated { Activation.activateFromOutside(pid: reply.pid, bundlePath: reply.bundlePath) }
                exit(0)
            case .delivered:
                exit(0)
            case .noAnswer:
                // The instance is stuck: better a second process than no window.
                return nil
            }
        }
    }
}
