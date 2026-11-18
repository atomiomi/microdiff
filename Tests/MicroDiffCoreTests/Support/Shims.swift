@_exported import MicroDiffTestSupport
import Foundation

// This machine's Command Line Tools ship a broken `_Testing_Foundation` overlay, so a test file must not
// import both Foundation and Testing. Test files use these module-wide helpers instead of importing Foundation.
typealias Data = Foundation.Data
typealias Date = Foundation.Date

func isExecutableFile(_ path: String) -> Bool {
    FileManager.default.isExecutableFile(atPath: path)
}

func symlinkFolder(_ link: String, to target: String) {
    try! FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
}

func fileText(_ path: String) -> String? {
    (try? String(contentsOfFile: path, encoding: .utf8))
}

/// Whether a process with this id is alive (a process that was killed and not yet collected still counts).
func processExists(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

/// How many file descriptors this process has open right now.
func openDescriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
}
