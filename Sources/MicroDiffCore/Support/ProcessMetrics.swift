import Darwin
import Foundation

/// Cheap measurements of the running process, used by the performance checks.
package enum ProcessMetrics {
    /// Memory the system charges to this process ("Memory" in Activity Monitor), in bytes.
    package static func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// Milliseconds since the kernel started this process (includes loading the binary, before `main`).
    package static func millisecondsSinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_starttime
        var now = timeval()
        gettimeofday(&now, nil)
        let seconds = Double(now.tv_sec - start.tv_sec)
        let micros = Double(now.tv_usec - start.tv_usec)
        return seconds * 1000 + micros / 1000
    }
}
