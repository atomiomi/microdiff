import AppKit
import MicroDiffCore
import MicroDiffTestSupport

@testable import MicroDiffUI

// Helpers for the memory tests. No `import Testing` here (it cannot be combined with Foundation in one file):
// tests only see plain functions, numbers and Bools.

enum MemoryEnv {
    /// Set by `scripts/test.sh` for its second pass, where only the isolated suites run, one test at a time.
    /// Heap, footprint, file descriptor and thread counts are process-wide: other tests running at the same
    /// time would make them meaningless.
    static let isolated = ProcessInfo.processInfo.environment["MICRODIFF_ISOLATED"] == "1"

    /// `MICRODIFF_SOAK=<n>` multiplies the iteration counts of the isolated tests (a long soak).
    static let soak = max(1, Int(ProcessInfo.processInfo.environment["MICRODIFF_SOAK"] ?? "") ?? 1)
}

/// Memory measured while one activity was repeated after a warm-up.
struct GrowthReport {
    let name: String
    let iterationsPerRound: Int
    /// Live malloc bytes at the start of the measured window and after every round of it.
    let heap: [Int]
    /// Physical footprint at the same moments.
    let footprint: [Int]
    /// Allowed live-heap growth per iteration, in bytes.
    let heapBudget: Double
    /// Rounds that were added to the warm-up because the heap was still settling.
    let extraWarmupRounds: Int

    var measuredIterations: Int { iterationsPerRound * (heap.count - 1) }

    /// How much the live heap grows per iteration: the median of the slopes between every pair of samples
    /// (Theil-Sen), so one noisy sample cannot fake or hide a trend.
    var heapPerIteration: Double { Self.slope(heap, iterationsPerRound) }

    static func slope(_ samples: [Int], _ perRound: Int) -> Double {
        var slopes: [Double] = []
        for i in samples.indices {
            for j in samples.indices where j > i {
                slopes.append(Double(samples[j] - samples[i]) / Double((j - i) * perRound))
            }
        }
        slopes.sort()
        guard !slopes.isEmpty else { return 0 }
        let mid = slopes.count / 2
        return slopes.count % 2 == 1 ? slopes[mid] : (slopes[mid - 1] + slopes[mid]) / 2
    }

    var heapTotal: Int { (heap.last ?? 0) - (heap.first ?? 0) }
    var footprintTotal: Int { (footprint.last ?? 0) - (footprint.first ?? 0) }
    /// Footprint growth over the whole window, projected from its trend (Theil-Sen again): the footprint moves in
    /// 16 KB pages and sometimes jumps once when malloc maps a new region, which is not a trend.
    var footprintTrend: Double { Self.slope(footprint, iterationsPerRound) * Double(measuredIterations) }

    /// Prints greppable lines and tells whether both budgets hold.
    func holds(footprintMB: Double) -> Bool {
        let perIteration = heapPerIteration
        let footprintOK = footprintTrend <= footprintMB * 1_048_576
        let ok = perIteration <= heapBudget && footprintOK
        print(String(
            format: "MEM %@ iterations=%d heap/iter=%.0fB budget=%.0fB heap-total=%+.1fKB footprint-trend=%+.1fKB (total %+.1fKB) budget=%.1fMB extra-warmup=%d %@",
            name, measuredIterations, perIteration, heapBudget, Double(heapTotal) / 1024, footprintTrend / 1024,
            Double(footprintTotal) / 1024,
            footprintMB, extraWarmupRounds, ok ? "OK" : "FAIL"))
        print("MEM \(name) heap samples KB: \(heap.map { $0 / 1024 }) footprint samples KB: \(footprint.map { $0 / 1024 })")
        return ok
    }
}

/// Repeats `step` `warmup` times, then measures `rounds` x `perRound` more, sampling memory at the start and after
/// every round. `step` runs inside an autorelease pool; `wait` runs after it (let background work finish).
/// Before each sample: `settle` (wait until quiet), `flush` (empty caches that are bounded on purpose, so every
/// sample sees them in the same state), then malloc gives free pages back.
///
/// Warm-up is adaptive: one-time costs (runtime metadata, first-use caches of AppKit and CoreText) take a while
/// to level off. While the measured window still grows faster than half of `heapBudget`, its oldest sample is
/// dropped and one more round is run, at most `maxExtraRounds` times. A real leak grows in every window and still fails.
@MainActor
func measureSteadyState(
    _ name: String, warmup: Int, rounds: Int = 6, perRound: Int, heapBudget: Double, maxExtraRounds: Int = 3,
    flush: () -> Void = {}, settle: () async -> Void = {},
    step: (Int) -> Void, wait: () async -> Void = {}
) async -> GrowthReport {
    var iteration = 0
    func run(_ count: Int) async {
        for _ in 0..<count {
            autoreleasepool { step(iteration) }
            await wait()
            iteration += 1
        }
    }
    func sample() async -> (heap: Int, footprint: Int) {
        await settle()
        autoreleasepool { flush() }
        // Lets queued main-queue work (autorelease pools, deferred frees) run.
        try? await Task.sleep(for: .milliseconds(5))
        MemoryProbe.relieve()
        var heap = Int.max
        for _ in 0..<3 { heap = min(heap, MemoryProbe.liveHeapBytes()) }
        return (heap, ProcessMetrics.footprintBytes())
    }

    await run(warmup)
    var heap: [Int] = []
    var footprint: [Int] = []
    let first = await sample()
    heap.append(first.heap)
    footprint.append(first.footprint)
    for _ in 0..<rounds {
        await run(perRound)
        let next = await sample()
        heap.append(next.heap)
        footprint.append(next.footprint)
    }
    var extra = 0
    while extra < maxExtraRounds, GrowthReport.slope(heap, perRound) > heapBudget / 2 {
        extra += 1
        heap.removeFirst()
        footprint.removeFirst()
        await run(perRound)
        let next = await sample()
        heap.append(next.heap)
        footprint.append(next.footprint)
    }
    return GrowthReport(
        name: name, iterationsPerRound: perRound, heap: heap, footprint: footprint, heapBudget: heapBudget,
        extraWarmupRounds: extra)
}

/// Live heap after letting malloc tidy up (for before/after comparisons of single big objects).
@MainActor
func settledHeap() async -> Int {
    try? await Task.sleep(for: .milliseconds(5))
    MemoryProbe.relieve()
    var heap = Int.max
    for _ in 0..<3 { heap = min(heap, MemoryProbe.liveHeapBytes()) }
    return heap
}

// MARK: - The repository the soak tests work on

/// A repository with everything the app deals with all day: a diff with folds, a long file to scroll,
/// nested folders, untracked files.
final class SoakRepo {
    let repo = TestRepo()
    var path: String { repo.path }

    static let bigLineCount = 20_000

    init() {
        repo.write("src/app.swift", Self.swiftSource(lines: 400, salt: 0))
        repo.write("src/big.swift", Self.swiftSource(lines: Self.bigLineCount, salt: 0))
        repo.write("src/mid.swift", Self.swiftSource(lines: 1500, salt: 0))
        repo.write("notes.txt", "one\n")
        for dir in 0..<12 {
            repo.write("pkg/m\(dir)/sub/file\(dir).txt", "x\n")
        }
        repo.commitAll("first")
        // Changes far apart, so the diff has folds between them.
        repo.write("src/app.swift", Self.swiftSource(lines: 400, salt: 1))
        repo.write("src/big.swift", Self.swiftSource(lines: Self.bigLineCount, salt: 1))
    }

    /// Swift-looking lines; `salt` changes every 50th line.
    static func swiftSource(lines: Int, salt: Int) -> String {
        var text = ""
        text.reserveCapacity(lines * 48)
        for i in 0..<lines {
            if i % 50 == 25, salt > 0 {
                text += "    let changed\(i) = \"salt \(salt)\" // edited\n"
            } else {
                text += "    func item\(i)(value: Int) -> Int { return value * \(i) } // \(i)\n"
            }
        }
        return text
    }

    func absolute(_ relative: String) -> String { path + "/" + relative }
}

// MARK: - Driving the real window, offscreen

/// The app's window controller for a folder. The window is never shown.
@MainActor
func makeController(_ path: String, width: CGFloat = 1180, height: CGFloat = 720) -> MainWindowController {
    _ = NSApplication.shared
    let controller = MainWindowController(path: path)
    controller.window.setContentSize(NSSize(width: width, height: height))
    controller.window.contentView?.layoutSubtreeIfNeeded()
    return controller
}

@MainActor
extension MainWindowController {
    var rootView: RootView { window.contentView as! RootView }

    func resize(width: CGFloat, height: CGFloat) {
        window.setContentSize(NSSize(width: width, height: height))
        rootView.layoutSubtreeIfNeeded()
    }
}

/// Draws views into reused bitmaps (one per size), the way the window would draw them.
@MainActor
final class OffscreenPainter {
    private var reps: [String: NSBitmapImageRep] = [:]

    func paint(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let key = "\(Int(bounds.width))x\(Int(bounds.height))"
        if reps[key] == nil { reps[key] = view.bitmapImageRepForCachingDisplay(in: bounds) }
        guard let rep = reps[key] else { return }
        view.cacheDisplay(in: bounds, to: rep)
    }
}

/// Waits until the workspace has no scan and no load in flight.
@MainActor
func waitIdle(_ workspace: Workspace, timeout: Duration = .seconds(10)) async {
    _ = await waitUntil(timeout: timeout) { !workspace.isScanning && !workspace.isLoading }
}

/// Waits until the workspace stayed idle for `quiet` in a row (file events from earlier writes have arrived
/// and their throttled rescans are done).
@MainActor
func waitQuiet(_ workspace: Workspace, quiet: Duration = .milliseconds(450), timeout: Duration = .seconds(15)) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var idleSince: ContinuousClock.Instant?
    while clock.now < deadline {
        if !workspace.isScanning && !workspace.isLoading {
            let since = idleSince ?? clock.now
            idleSince = since
            if clock.now - since >= quiet { return }
        } else {
            idleSince = nil
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Reading private state (without widening access in the app)

/// A stored property of `object`, found by name through reflection (also private ones).
func storedProperty<T>(_ object: Any, _ path: String...) -> T? {
    var current: Any = object
    for name in path {
        guard let child = Mirror(reflecting: current).children.first(where: { $0.label == name }) else { return nil }
        current = child.value
        // Unwrap optionals.
        let mirror = Mirror(reflecting: current)
        if mirror.displayStyle == .optional {
            guard let some = mirror.children.first else { return nil }
            current = some.value
        }
    }
    return current as? T
}

/// Number of elements of a stored collection property (private ones too), found by reflection.
func storedCount(_ object: Any, _ name: String) -> Int? {
    guard let child = Mirror(reflecting: object).children.first(where: { $0.label == name }) else { return nil }
    return Mirror(reflecting: child.value).children.count
}

/// Weak box, so tests can check that an object is gone.
final class WeakRef<T: AnyObject> {
    weak var object: T?
    init(_ object: T?) { self.object = object }
    var isGone: Bool { object == nil }
}

/// Polls until `condition` holds (giving the main actor and background threads time), or the timeout passes.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

// MARK: - File descriptors, threads, child processes

struct ResourceCounts {
    var fileDescriptors: Int
    var threads: Int
    var zombies: Int

    static func now() -> ResourceCounts {
        ResourceCounts(
            fileDescriptors: MemoryProbe.openFileDescriptorCount(), threads: MemoryProbe.threadCount(),
            zombies: MemoryProbe.zombieChildCount())
    }

    /// Idle worker threads of Dispatch and of the Swift concurrency pool come and go on their own: a couple more
    /// than before is not a leak. Anything that grows per operation is far above this.
    static let threadSlack = 2

    func isBack(to before: ResourceCounts) -> Bool {
        fileDescriptors <= before.fileDescriptors && threads <= before.threads + Self.threadSlack && zombies == 0
    }

    /// Waits (up to `timeout`) until the counts are back where `before` was, then returns the comparison.
    @MainActor
    static func settle(to before: ResourceCounts, timeout: Duration = .seconds(10)) async -> ResourceCheck {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var after = now()
        while !after.isBack(to: before), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            after = now()
        }
        return ResourceCheck(before: before, after: after)
    }
}

struct ResourceCheck {
    let before: ResourceCounts
    let after: ResourceCounts

    /// Prints one greppable line and tells whether nothing was left behind.
    func holds() -> Bool {
        let ok = after.isBack(to: before)
        print("RES fds=\(before.fileDescriptors)->\(after.fileDescriptors) threads=\(before.threads)->\(after.threads) zombies=\(after.zombies) \(ok ? "OK" : "FAIL")")
        return ok
    }
}

/// Runs `body` in an autorelease pool, so objects AppKit autoreleases are not kept alive by the test.
@MainActor
func withPool<T>(_ body: () -> T) -> T {
    autoreleasepool(invoking: body)
}

/// A big text file (about `megabytes` MB) at `relative` in `repo`.
func writeBigFile(_ repo: TestRepo, _ relative: String, megabytes: Int, salt: Int = 0) {
    let line = String(repeating: "abcdefghij", count: 9) + " \(salt)\n"
    let count = megabytes * 1_048_576 / line.utf8.count
    var text = ""
    text.reserveCapacity(count * line.utf8.count)
    for _ in 0..<count { text += line }
    repo.write(relative, text)
}
