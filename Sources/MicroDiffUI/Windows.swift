import AppKit
import MicroDiffCore

/// All windows of the one running app: one per folder. Opens, finds, places and forgets them.
final class WindowManager {
    /// Where the last window frame is kept (the same key the single-window app used for its autosaved frame).
    static let frameName = "MicroDiffMainWindow"
    /// How far each new window sits down and to the right of the one before.
    static let cascadeOffset: CGFloat = 26

    enum OpenResult {
        case opened(MainWindowController)
        case focused(MainWindowController)
        case refused(String)
    }

    /// Open windows, oldest first. A controller leaves this list when its window closes, which frees it.
    private(set) var controllers: [MainWindowController] = []
    /// False in tests: windows are made and placed but never put on screen, and no frame is read or saved.
    let showsWindows: Bool
    private weak var lastKey: MainWindowController?
    private let scanner = RepoScanner()
    /// Requests that came in before the app finished launching.
    private var pending: [(request: InstanceRequest, completion: (OpenResult) -> Void)] = []
    private(set) var isReady = false

    init(showsWindows: Bool = true) {
        self.showsWindows = showsWindows
    }

    /// The window menu commands act on: the key window's, else the one that was key last, else the newest.
    var keyController: MainWindowController? {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, let controller = controllers.first(where: { $0.window === window }) {
            return controller
        }
        if let lastKey, controllers.contains(where: { $0 === lastKey }) { return lastKey }
        return controllers.last
    }

    // MARK: - Making windows

    /// A new window for `path`, registered and placed, not started and not shown.
    @discardableResult
    func makeWindow(path: String) -> MainWindowController {
        let controller = MainWindowController(path: path)
        place(controller)
        controllers.append(controller)
        controller.onClose = { [weak self] controller in self?.closed(controller) }
        controller.onBecomeKey = { [weak self] controller in self?.lastKey = controller }
        return controller
    }

    /// Shows the window and remembers it as the one in front.
    func present(_ controller: MainWindowController) {
        lastKey = controller
        if showsWindows { controller.show() }
    }

    /// The first window takes the saved frame; every later one sits cascaded below the window in front.
    private func place(_ controller: MainWindowController) {
        let window = controller.window
        guard let reference = keyController?.window else {
            if showsWindows, !window.setFrameUsingName(Self.frameName) { window.center() }
            return
        }
        let visible = (reference.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let occupied = controllers.map { CGPoint(x: $0.window.frame.minX, y: $0.window.frame.maxY) }
        window.setFrame(Self.cascadedFrame(after: reference.frame, visible: visible, occupied: occupied), display: false)
    }

    /// The frame for a new window after `reference`: same size, one step down and right; back at the top left of
    /// the screen when that leaves the screen; never with its top left corner exactly on another window's.
    static func cascadedFrame(after reference: CGRect, visible: CGRect, occupied: [CGPoint]) -> CGRect {
        var frame = reference
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        func step(_ frame: CGRect) -> CGRect { frame.offsetBy(dx: cascadeOffset, dy: -cascadeOffset) }
        func isTaken(_ frame: CGRect) -> Bool {
            occupied.contains { abs($0.x - frame.minX) < 2 && abs($0.y - frame.maxY) < 2 }
        }
        frame = step(frame)
        for _ in 0..<64 {
            if frame.maxX > visible.maxX || frame.minY < visible.minY || frame.maxY > visible.maxY || frame.minX < visible.minX {
                frame.origin = CGPoint(x: visible.minX, y: visible.maxY - frame.height)
                if !isTaken(frame) { break }
                frame = step(frame)
                continue
            }
            if !isTaken(frame) { break }
            frame = step(frame)
        }
        return frame
    }

    private func closed(_ controller: MainWindowController) {
        if showsWindows { controller.window.saveFrame(usingName: Self.frameName) }
        controllers.removeAll { $0 === controller }
        if lastKey === controller { lastKey = nil }
    }

    /// Quitting: the window in front leaves its frame for the next start.
    func saveFrame() {
        guard showsWindows, let controller = keyController else { return }
        controller.window.saveFrame(usingName: Self.frameName)
    }

    // MARK: - Requests from later starts

    /// Handles requests from now on, starting with the ones that came in early.
    func markReady() {
        isReady = true
        let waiting = pending
        pending.removeAll()
        for (request, completion) in waiting { handle(request, completion: completion) }
    }

    func handle(_ request: InstanceRequest, completion: @escaping (OpenResult) -> Void) {
        guard isReady else {
            pending.append((request, completion))
            return
        }
        let mode: ViewMode? = request.mode.map { $0 == "file" ? .file : .diff }
        open(folder: request.folder, files: request.openFiles, mode: mode, completion: completion)
    }

    /// Opens `folder` in a new window, or brings forward the window that already shows it (the same folder,
    /// or the same repository), and opens `files` there as tabs. An empty folder only brings the front window forward.
    func open(folder: String, files: [String] = [], mode: ViewMode? = nil, completion: @escaping (OpenResult) -> Void) {
        if folder.isEmpty {
            guard let controller = keyController else { return completion(.refused("no window open")) }
            present(controller)
            return completion(.focused(controller))
        }
        var isDirectory: ObjCBool = false
        guard folder.hasPrefix("/"), FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return completion(.refused("no such folder: \(folder)"))
        }
        let path = MainWindowController.canonical(folder)
        if let match = window(for: path, root: nil) {
            return completion(reveal(match, files: files, mode: mode))
        }
        // Only a window whose repository contains the folder can be the same repository: otherwise git need not run.
        guard controllers.contains(where: { Self.contains($0.workspace.rootPath, path) }) else {
            return completion(create(path, files: files, mode: mode))
        }
        let scanner = scanner
        Task { [weak self] in
            let root = await Task.detached(priority: .userInitiated) { scanner.resolveRoot(for: path).root }.value
            guard let self else { return }
            if let match = window(for: path, root: root) {
                completion(reveal(match, files: files, mode: mode))
            } else {
                completion(create(path, files: files, mode: mode))
            }
        }
    }

    private func window(for path: String, root: String?) -> MainWindowController? {
        controllers.first { controller in
            controller.folderPath == path || controller.workspace.rootPath == path || (root.map { controller.workspace.rootPath == $0 } ?? false)
        }
    }

    private func reveal(_ controller: MainWindowController, files: [String], mode: ViewMode?) -> OpenResult {
        controller.open(files: files, mode: mode)
        present(controller)
        return .focused(controller)
    }

    private func create(_ path: String, files: [String], mode: ViewMode?) -> OpenResult {
        let controller = makeWindow(path: path)
        controller.open(files: files, mode: mode)
        controller.workspace.start()
        present(controller)
        return .opened(controller)
    }

    /// `path` is `folder` or inside it.
    static func contains(_ folder: String, _ path: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    // MARK: - Window menu

    /// Cmd+`: the next window of this app comes to the front.
    func cycleWindows() {
        let visible = controllers.filter { $0.window.isVisible && !$0.window.isMiniaturized }
        guard visible.count > 1 else { return }
        let index = visible.firstIndex { $0 === keyController } ?? -1
        present(visible[(index + 1) % visible.count])
    }
}
