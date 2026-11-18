import Darwin

/// Process-wide resource counters for the memory and resource tests (and the soak mode).
/// All numbers cover the whole process, so they are only meaningful when nothing else runs at the same time.
package enum MemoryProbe {
    /// Bytes malloc has handed out and not got back, summed over all zones.
    /// Steadier than the physical footprint: it does not depend on which freed pages the allocator still keeps.
    package static func liveHeapBytes() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    /// Asks malloc to give free pages back to the system, so the footprint reflects what is really in use.
    package static func relieve() {
        malloc_zone_pressure_relief(nil, 0)
    }

    /// Open file descriptors (files, pipes, sockets, kqueues) of this process.
    package static func openFileDescriptorCount() -> Int {
        let pid = getpid()
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return -1 }
        // Room for some growth between the two calls.
        let capacity = Int(needed) / MemoryLayout<proc_fdinfo>.stride + 64
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let filled = buffer.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        return filled < 0 ? -1 : Int(filled) / MemoryLayout<proc_fdinfo>.stride
    }

    /// Threads of this process right now.
    package static func threadCount() -> Int {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let result = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size)
        return result == size ? Int(info.pti_threadnum) : -1
    }

    /// Child processes of this process that have exited but were never waited for.
    package static func zombieChildCount() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return -1 }
        size += 16 * MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return -1 }
        let me = getpid()
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).filter {
            $0.kp_eproc.e_ppid == me && $0.kp_proc.p_stat == SZOMB
        }.count
    }
}
