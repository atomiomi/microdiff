import Darwin
import MicroDiffCore
import Testing

@Suite("ProcessMetrics")
struct ProcessMetricsTests {
    @Test func footprintIsAtLeastOneMegabyte() {
        #expect(ProcessMetrics.footprintBytes() > 1_000_000)
    }

    @Test func footprintGrowsWhenFreshMemoryIsTouched() {
        let size = 32 * 1024 * 1024
        // Pages straight from the kernel, not from malloc: the allocator likes to hand back a big block it
        // freed earlier, which is already counted, and then the footprint would not move.
        guard let memory = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), memory != MAP_FAILED else {
            Issue.record("mmap failed")
            return
        }
        defer { munmap(memory, size) }
        let before = ProcessMetrics.footprintBytes()
        // Writing every page makes the system back all of it with real memory.
        memset(memory, 1, size)
        let during = ProcessMetrics.footprintBytes()
        #expect(during - before >= 16 * 1024 * 1024, "grew by only \(during - before) bytes")
    }

    @Test func millisecondsSinceProcessStartIsPositive() {
        #expect(ProcessMetrics.millisecondsSinceProcessStart() > 0)
    }

    @Test func millisecondsSinceProcessStartIncreasesAcrossASleep() {
        let first = ProcessMetrics.millisecondsSinceProcessStart()
        usleep(30_000)
        let second = ProcessMetrics.millisecondsSinceProcessStart()
        #expect(second > first)
    }
}
