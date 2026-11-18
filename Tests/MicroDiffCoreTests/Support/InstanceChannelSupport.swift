import Darwin
import Dispatch
import MicroDiffCore

// Helpers for InstanceChannelTests (kept out of the test file, which imports Testing).

nonisolated(unsafe) private var socketCounter = 0
private let counterLock = NSLockBox()

/// The per-user temporary folder, ending in "/".
func tempDir() -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    _ = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    let dir = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    return dir.hasSuffix("/") ? dir : dir + "/"
}

/// A fresh socket path no other test (or real app) uses.
func socketPath() -> String {
    let n = counterLock.withLock { () -> Int in
        socketCounter += 1
        return socketCounter
    }
    // The same names every run, so leftover lock files do not pile up in the temp folder.
    let path = tempDir() + "microdiff-test-\(n).sock"
    unlink(path)
    unlink(path + ".lock")
    return path
}

func owner(_ path: String) -> InstanceServer? {
    if case let .owner(server) = InstanceChannel.claim(path: path) { return server }
    return nil
}

func client(_ path: String) -> InstanceConnection? { InstanceConnection(path: path) }

func now() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_MONOTONIC, &time)
    return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
}

func makeAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes.prefix(raw.count - 1))
    }
    return address
}

/// A plain connection, for clients that misbehave.
func rawConnect(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = makeAddress(path)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if result != 0 {
        close(fd)
        return nil
    }
    return fd
}

@discardableResult
func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if written <= 0 { return false }
        offset += written
    }
    return true
}

/// Everything the peer sends until it closes; nil when it does not close within `timeout`.
func readUntilClosed(_ fd: Int32, timeout: Double) -> [UInt8]? {
    let deadline = now() + timeout
    var result: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 4096)
    while now() < deadline {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, 50) >= 0 else { return nil }
        if poller.revents == 0 { continue }
        let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count <= 0 { return result }
        result += chunk[0..<count]
    }
    return nil
}

/// A value shared between threads.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLockBox()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func update(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}

final class NSLockBox: @unchecked Sendable {
    private var mutex = pthread_mutex_t()
    init() { pthread_mutex_init(&mutex, nil) }
    func withLock<T>(_ body: () -> T) -> T {
        pthread_mutex_lock(&mutex)
        defer { pthread_mutex_unlock(&mutex) }
        return body()
    }
}

enum DispatchApply {
    /// Runs `body` on `count` threads at once.
    static func run(_ count: Int, _ body: @Sendable (Int) -> Void) {
        DispatchQueue.concurrentPerform(iterations: count, execute: body)
    }
}
