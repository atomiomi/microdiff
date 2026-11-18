import Darwin
import Dispatch
import Foundation

// One running MicroDiff per user: the first process owns a Unix domain socket, later starts hand it their
// folder and exit. No AppKit here, so all of it is testable on its own.
//
// Wire format (both directions): a magic word, then fields that end in a NUL byte. Paths cannot contain NUL.
//   request:  "MDQ1\0"  "F<folder>\0"  ("O<file>\0")*  ("M<mode>\0")?        then the client shuts down writing
//   reply:    "A"  (as soon as a valid request was read)
//             "MDR1\0" "S<status>\0" "V<activated 0|1>\0" "P<pid>\0" ("B<bundle path>\0")? ("T<message>\0")?   then close
// Anything else is dropped without an answer.

/// What a later start asks the running instance to do.
package struct InstanceRequest: Equatable, Sendable {
    /// Absolute folder to open or focus. Empty: only bring the app to the front.
    package var folder: String
    /// Files to open as tabs: absolute, or relative to the repository root (like `--open`).
    package var openFiles: [String]
    /// "diff", "read" or "edit", nil for the default.
    package var mode: String?

    package init(folder: String, openFiles: [String] = [], mode: String? = nil) {
        self.folder = folder
        self.openFiles = openFiles
        self.mode = mode
    }

    static let magic = "MDQ1"

    package func encoded() -> [UInt8] {
        var fields = [Self.magic, "F" + folder]
        fields += openFiles.map { "O" + $0 }
        if let mode { fields.append("M" + mode) }
        return InstanceWire.encode(fields)
    }

    /// Nil for anything that is not a well-formed request.
    package static func decode(_ bytes: [UInt8]) -> InstanceRequest? {
        guard let fields = InstanceWire.decode(bytes), fields.first == magic else { return nil }
        var folder: String?
        var files: [String] = []
        var mode: String?
        for field in fields.dropFirst() {
            guard let tag = field.first else { return nil }
            let value = String(field.dropFirst())
            switch tag {
            case "F" where folder == nil: folder = value
            case "O" where !value.isEmpty && files.count < InstanceChannel.maxFiles: files.append(value)
            case "M" where mode == nil && ViewMode(name: value) != nil: mode = value
            default: return nil
            }
        }
        guard let folder, folder.isEmpty || folder.hasPrefix("/") else { return nil }
        return InstanceRequest(folder: folder, openFiles: files, mode: mode)
    }
}

/// The running instance's answer.
package struct InstanceReply: Equatable, Sendable {
    package enum Status: String, Sendable {
        /// A new window was made.
        case opened
        /// A window for that folder already existed and was brought to the front.
        case focused
        /// Nothing was done (no such folder).
        case refused
    }

    package var status: Status
    /// The app was the active app when it answered.
    package var activated: Bool
    package var pid: Int32
    /// The running app's bundle, so the launcher can ask LaunchServices to activate it.
    package var bundlePath: String?
    package var message: String?

    package init(status: Status, activated: Bool, pid: Int32 = getpid(), bundlePath: String? = nil, message: String? = nil) {
        self.status = status
        self.activated = activated
        self.pid = pid
        self.bundlePath = bundlePath
        self.message = message
    }

    static let magic = "MDR1"

    package func encoded() -> [UInt8] {
        var fields = [Self.magic, "S" + status.rawValue, "V" + (activated ? "1" : "0"), "P\(pid)"]
        if let bundlePath { fields.append("B" + bundlePath) }
        if let message { fields.append("T" + message) }
        return InstanceWire.encode(fields)
    }

    package static func decode(_ bytes: [UInt8]) -> InstanceReply? {
        guard let fields = InstanceWire.decode(bytes), fields.first == magic else { return nil }
        var status: Status?
        var activated = false
        var pid: Int32 = 0
        var bundlePath: String?
        var message: String?
        for field in fields.dropFirst() {
            guard let tag = field.first else { return nil }
            let value = String(field.dropFirst())
            switch tag {
            case "S": status = Status(rawValue: value)
            case "V": activated = value == "1"
            case "P": pid = Int32(value) ?? 0
            case "B": bundlePath = value
            case "T": message = value
            default: return nil
            }
        }
        guard let status else { return nil }
        return InstanceReply(status: status, activated: activated, pid: pid, bundlePath: bundlePath, message: message)
    }
}

enum InstanceWire {
    static func encode(_ fields: [String]) -> [UInt8] {
        var bytes: [UInt8] = []
        for field in fields {
            bytes += field.utf8.filter { $0 != 0 }
            bytes.append(0)
        }
        return bytes
    }

    /// Fields of a message that ends in NUL, each valid UTF-8. Nil otherwise.
    static func decode(_ bytes: [UInt8]) -> [String]? {
        guard let last = bytes.last, last == 0 else { return nil }
        var fields: [String] = []
        for slice in bytes.dropLast().split(separator: 0, omittingEmptySubsequences: false) {
            // Invalid UTF-8 would be repaired with U+FFFD by `decoding`: reject it instead.
            let field = String(decoding: slice, as: UTF8.self)
            guard field.utf8.elementsEqual(slice) else { return nil }
            fields.append(field)
        }
        return fields
    }
}

/// The socket itself: finding its path, claiming it, and the client side of one request.
package enum InstanceChannel {
    /// Bigger requests are dropped (a thousand long paths fit easily).
    package static let maxRequestBytes = 256 * 1024
    package static let maxFiles = 1000
    /// `sun_path` holds 104 bytes including the final NUL.
    package static let maxPathBytes = 103
    /// How long the server waits for a whole request, and the client for the quick "A".
    package static let readTimeout = 1.0

    /// The socket path for this user: `$MICRODIFF_SOCKET`, else the per-user temporary folder
    /// (`/var/folders/…/T/`, readable only by this user), else `/tmp` when that path is too long.
    package static func socketPath(environment: [String: String]) -> String {
        if let custom = environment["MICRODIFF_SOCKET"], !custom.isEmpty { return custom }
        let name = "dev.microdiff.sock"
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            let dir = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            let path = (dir.hasSuffix("/") ? dir : dir + "/") + name
            if dir.hasPrefix("/"), path.utf8.count <= maxPathBytes { return path }
        }
        return "/tmp/microdiff-\(getuid()).sock"
    }

    package enum Claim {
        /// An instance answers on the socket: send it the request.
        case client(InstanceConnection)
        /// No instance was running: this process owns the socket now.
        case owner(InstanceServer)
        /// Neither worked (path too long, an owner that does not answer, …): run on its own.
        case unavailable
    }

    /// Connects to the running instance, or becomes it.
    ///
    /// A lock file next to the socket stays locked for the owner's whole life. The kernel drops the lock when the
    /// owner dies, however it dies. So: if connecting fails and the lock is free, the socket file is stale and is
    /// replaced. If the lock is taken, someone else just became the owner (or is busy): retry connecting for a moment.
    package static func claim(path: String, patience: Double = 1.0) -> Claim {
        guard path.utf8.count <= maxPathBytes else { return .unavailable }
        if let connection = InstanceConnection(path: path) { return .client(connection) }
        let deadline = now() + patience
        var pause: useconds_t = 1000
        while true {
            if let lock = OwnerLock(path: path + ".lock") {
                // Between our failed connect and taking the lock an owner may have come and gone; try once more.
                if let connection = InstanceConnection(path: path) {
                    lock.release()
                    return .client(connection)
                }
                guard let server = InstanceServer(path: path, lock: lock) else {
                    lock.release()
                    return .unavailable
                }
                return .owner(server)
            }
            if let connection = InstanceConnection(path: path) { return .client(connection) }
            if now() >= deadline { return .unavailable }
            usleep(pause)
            pause = min(pause * 2, 20_000)
        }
    }

    static func now() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }

    static func makeAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathBytes else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// A socket that is closed in child processes (git) and never raises SIGPIPE.
    static func makeSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        prepare(fd)
        return fd
    }

    static func prepare(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// The peer runs as this same user.
    static func peerIsSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    /// Reads until the peer closes, `limit` bytes are exceeded (nil), or `deadline` passes (nil).
    /// With `stopAfter`, returns as soon as that many bytes arrived.
    static func read(_ fd: Int32, limit: Int, deadline: Double, stopAfter: Int? = nil) -> [UInt8]? {
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if let stopAfter, result.count >= stopAfter { return result }
            let left = deadline - now()
            guard left > 0 else { return nil }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(max(1, (left * 1000).rounded(.up))))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let wanted = stopAfter.map { min(chunk.count, $0 - result.count) } ?? chunk.count
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, wanted) }
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return count == 0 ? result : nil }
            result += chunk[0..<count]
            if result.count > limit { return nil }
        }
    }
}

/// The client side: a connection to the running instance that carries one request.
package final class InstanceConnection {
    private var fd: Int32

    /// Nil when nobody (of this user) listens on `path`.
    package init?(path: String) {
        guard var address = InstanceChannel.makeAddress(path), let fd = InstanceChannel.makeSocket() else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, InstanceChannel.peerIsSameUser(fd) else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
    }

    deinit { close() }

    package func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    package enum Outcome: Equatable {
        case replied(InstanceReply)
        /// Nothing came back in time: the instance is hung (or the request was refused as malformed).
        case noAnswer
        /// The request arrived (the instance said so) but the final answer did not come in time.
        case delivered
    }

    /// Sends the request and waits for the answer: up to `ackTimeout` for the quick "A", then up to
    /// `replyTimeout` for the reply (the instance answers once the window is up).
    package func send(_ request: InstanceRequest, ackTimeout: Double = InstanceChannel.readTimeout, replyTimeout: Double = 4) -> Outcome {
        defer { close() }
        guard fd >= 0, InstanceChannel.writeAll(fd, request.encoded()) else { return .noAnswer }
        shutdown(fd, SHUT_WR)
        guard let ack = InstanceChannel.read(fd, limit: 1, deadline: InstanceChannel.now() + ackTimeout, stopAfter: 1),
              ack == [UInt8(ascii: "A")]
        else { return .noAnswer }
        guard let bytes = InstanceChannel.read(fd, limit: 64 * 1024, deadline: InstanceChannel.now() + replyTimeout),
              let reply = InstanceReply.decode(bytes)
        else { return .delivered }
        return .replied(reply)
    }
}

/// The lock that marks the owner of a socket path. Held from claiming until the server closes (or the process dies).
final class OwnerLock {
    private var fd: Int32

    /// Nil when another process (or another claim in this process) holds it.
    init?(path: String) {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
    }

    deinit { release() }

    func release() {
        if fd >= 0 { close(fd) }
        fd = -1
    }
}

/// Answers one request. Replying closes the connection; dropping it unanswered closes it too.
package final class InstanceResponder: @unchecked Sendable {
    private let lock = PlainLock()
    private var fd: Int32

    init(fd: Int32) { self.fd = fd }

    deinit { finish(nil) }

    package func reply(_ reply: InstanceReply) { finish(reply) }

    private func finish(_ reply: InstanceReply?) {
        lock.withLock {
            guard fd >= 0 else { return }
            if let reply { _ = InstanceChannel.writeAll(fd, reply.encoded()) }
            close(fd)
            fd = -1
        }
    }
}

/// The owner side: accepts connections on its own thread and hands every valid request to `handler`.
package final class InstanceServer: @unchecked Sendable {
    package let path: String
    private let lock = PlainLock()
    private var listenFD: Int32
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var ownerLock: OwnerLock?
    /// Device and inode of the socket file this server made: only that file is removed on close.
    private let identity: (dev_t, ino_t)
    private var started = false
    private let readers = DispatchQueue(label: "microdiff.instance.read", attributes: .concurrent)
    private let finished = DispatchSemaphore(value: 0)

    /// Replaces a stale socket file at `path` and listens on it. The caller holds `lock`.
    fileprivate init?(path: String, lock: OwnerLock) {
        guard var address = InstanceChannel.makeAddress(path), let fd = InstanceChannel.makeSocket() else { return nil }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Only this user may connect: the file is 0600 (the per-user folder is private too) and peers are checked.
        // Set on the file before listening, not through the umask: that is process-wide and would also reach a git
        // started at the same moment, which then makes folders it cannot write into.
        var info = stat()
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 64) == 0, lstat(path, &info) == 0 else {
            Darwin.close(fd)
            return nil
        }
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            Darwin.close(fd)
            unlink(path)
            return nil
        }
        for end in pipeFDs { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        self.path = path
        listenFD = fd
        wakeRead = pipeFDs[0]
        wakeWrite = pipeFDs[1]
        identity = (info.st_dev, info.st_ino)
        ownerLock = lock
    }

    deinit { close() }

    /// Starts accepting. `handler` runs on a background queue, once per valid request; it must answer through the
    /// responder (from any thread). Malformed, oversized, silent or foreign connections never reach it.
    package func start(handler: @escaping @Sendable (InstanceRequest, InstanceResponder) -> Void) {
        let (listenFD, wakeRead) = lock.withLock { () -> (Int32, Int32) in
            started = true
            return (self.listenFD, self.wakeRead)
        }
        guard listenFD >= 0 else { return }
        let readers = readers
        let finished = finished
        let thread = Thread {
            var fds = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0), pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            while true {
                fds[0].revents = 0
                fds[1].revents = 0
                let ready = poll(&fds, 2, -1)
                if ready < 0, errno == EINTR { continue }
                if ready < 0 || fds[1].revents != 0 { break }
                guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
                let client = accept(listenFD, nil, nil)
                guard client >= 0 else { continue }
                InstanceChannel.prepare(client)
                guard InstanceChannel.peerIsSameUser(client) else {
                    Darwin.close(client)
                    continue
                }
                readers.async { Self.serve(client, handler: handler) }
            }
            finished.signal()
        }
        thread.name = "MicroDiff instance channel"
        thread.start()
    }

    private static func serve(_ fd: Int32, handler: @Sendable (InstanceRequest, InstanceResponder) -> Void) {
        let deadline = InstanceChannel.now() + InstanceChannel.readTimeout
        guard let bytes = InstanceChannel.read(fd, limit: InstanceChannel.maxRequestBytes, deadline: deadline),
              let request = InstanceRequest.decode(bytes),
              InstanceChannel.writeAll(fd, [UInt8(ascii: "A")])
        else {
            Darwin.close(fd)
            return
        }
        handler(request, InstanceResponder(fd: fd))
    }

    /// Stops listening, removes the socket file (if it is still ours) and releases the owner lock.
    package func close() {
        let (wasStarted, wake) = lock.withLock { () -> (Bool, Int32) in
            guard listenFD >= 0 else { return (false, -1) }
            var info = stat()
            if lstat(path, &info) == 0, info.st_dev == identity.0, info.st_ino == identity.1 { unlink(path) }
            return (started, wakeWrite)
        }
        guard wake >= 0 else { return }
        if wasStarted {
            var byte: UInt8 = 1
            _ = write(wake, &byte, 1)
            finished.wait()
        }
        lock.withLock {
            Darwin.close(listenFD)
            Darwin.close(wakeRead)
            Darwin.close(wakeWrite)
            listenFD = -1
            wakeRead = -1
            wakeWrite = -1
            ownerLock?.release()
            ownerLock = nil
        }
    }
}

/// A plain mutex.
final class PlainLock: @unchecked Sendable {
    private var mutex = pthread_mutex_t()

    init() { pthread_mutex_init(&mutex, nil) }
    deinit { pthread_mutex_destroy(&mutex) }

    func withLock<T>(_ body: () -> T) -> T {
        pthread_mutex_lock(&mutex)
        defer { pthread_mutex_unlock(&mutex) }
        return body()
    }
}
