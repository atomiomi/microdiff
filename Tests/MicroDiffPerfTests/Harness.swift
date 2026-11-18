import Darwin
import Foundation
import MicroDiffCore

// The measuring harness. No `import Testing` here (it cannot be combined with Foundation),
// so tests only see plain functions and Bools.

/// Timings of one benchmark, in milliseconds.
struct Measurement {
    var min: Double
    var median: Double
    var max: Double
}

/// Perf budgets are only meaningful in an optimized build; debug runs skip the whole suite.
let perfBuildIsOptimized: Bool = {
    #if DEBUG
    false
    #else
    true
    #endif
}()

/// True when the process runs with the allocator setting the memory tests need (set by `scripts/perf.sh`).
let memoryPassIsConfigured = ProcessInfo.processInfo.environment["MallocLargeCache"] == "0"

/// Runs `body` `warmup + iterations` times and times the last `iterations` runs.
/// `before` runs untimed ahead of every run (to reset caches, for example).
/// Budgets use the median: one slow run on a busy machine does not fail the suite.
func measure(iterations: Int = 9, warmup: Int = 2, before: () -> Void = {}, _ body: () -> Void) -> Measurement {
    let clock = ContinuousClock()
    var samples: [Double] = []
    for run in 0..<(warmup + iterations) {
        before()
        let elapsed = clock.measure(body)
        if run >= warmup {
            let parts = elapsed.components
            samples.append(Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
        }
    }
    samples.sort()
    return Measurement(min: samples[0], median: samples[samples.count / 2], max: samples[samples.count - 1])
}

/// The last result handed to `blackHole`. Writing to a global is a side effect the optimizer must keep,
/// so the work behind the value cannot be removed as dead code.
nonisolated(unsafe) var sink: Any?

/// Keeps a result alive (until the next call) so the measured work really happens.
/// Boxing costs a few dozen ns: in tight loops of tiny calls, add up a checksum and pass that instead.
@_optimize(none) @inline(never)
func blackHole<T>(_ value: T) {
    sink = value
}

private func format(_ ms: Double) -> String {
    ms < 1 ? String(format: "%.4fms", ms) : String(format: "%.2fms", ms)
}

/// Prints the one greppable result line and tells whether the budget holds.
/// `perCall` divides the timings when one run does many calls (a budget "per call").
func report(_ name: String, _ m: Measurement, budgetMs: Double, perCall: Double = 1) -> Bool {
    let median = m.median / perCall
    let ok = median <= budgetMs
    print("PERF \(name) median=\(format(median)) min=\(format(m.min / perCall)) budget=\(format(budgetMs)) \(ok ? "OK" : "FAIL")")
    return ok
}

/// Bytes malloc hands out right now, summed over all zones.
private func heapInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return Int(stats.size_in_use)
}

/// Memory growth in bytes while the value from `build` is alive; the smallest of `runs` tries.
///
/// Two meters, the larger wins: the process footprint (the real cost, includes mapped memory) and the malloc
/// heap in use. Footprint alone under-reports once the process has run other tests: freed blocks stay resident
/// in malloc's caches and `build` reuses them for free. The heap meter does not care about reuse.
func footprintGrowth<T>(runs: Int = 3, _ build: () -> T) -> Int {
    var best = Int.max
    for _ in 0..<runs {
        blackHole(()) // drops the previous run's value
        malloc_zone_pressure_relief(nil, 0)
        let footprintBefore = ProcessMetrics.footprintBytes()
        let heapBefore = heapInUse()
        blackHole(build())
        let footprint = ProcessMetrics.footprintBytes() - footprintBefore
        let heap = heapInUse() - heapBefore
        blackHole(())
        best = Swift.min(best, Swift.max(footprint, heap))
    }
    return best
}

func reportMemory(_ name: String, growthBytes: Int, budgetMB: Double) -> Bool {
    let mb = Double(growthBytes) / 1_048_576
    let ok = mb <= budgetMB
    print("PERF \(name) growth=\(String(format: "%.2fMB", mb)) budget=\(String(format: "%.2fMB", budgetMB)) \(ok ? "OK" : "FAIL")")
    return ok
}
