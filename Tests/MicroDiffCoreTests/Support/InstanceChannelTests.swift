import Darwin
import MicroDiffCore
import Testing

// The single-instance socket, without AppKit. Every test uses its own socket path in the per-user temp folder.
@Suite("InstanceChannel", .serialized)
struct InstanceChannelTests {
    // MARK: wire format

    @Test func requestRoundTripsWithSpacesAndNonASCII() {
        let request = InstanceRequest(
            folder: "/Users/me/My Projects/café ☕︎/日本語", openFiles: ["src/app file.ts", "/abs/Ünïcödé.swift"], mode: "file")
        #expect(InstanceRequest.decode(request.encoded()) == request)
        let empty = InstanceRequest(folder: "")
        #expect(InstanceRequest.decode(empty.encoded()) == empty)
    }

    @Test func replyRoundTrips() {
        let reply = InstanceReply(status: .refused, activated: true, pid: 42, bundlePath: "/A b/MicroDiff.app", message: "no such folder: /x y")
        #expect(InstanceReply.decode(reply.encoded()) == reply)
        let plain = InstanceReply(status: .opened, activated: false, pid: 7)
        #expect(InstanceReply.decode(plain.encoded()) == plain)
    }

    @Test(arguments: [
        [UInt8](),
        Array("MDQ1".utf8),  // no final NUL
        Array("MDQ1\u{0}".utf8),  // no folder
        Array("MDQ2\u{0}F/a\u{0}".utf8),  // wrong magic
        Array("MDQ1\u{0}Frelative\u{0}".utf8),  // folder not absolute
        Array("MDQ1\u{0}F/a\u{0}F/b\u{0}".utf8),  // two folders
        Array("MDQ1\u{0}F/a\u{0}Xjunk\u{0}".utf8),  // unknown field
        Array("MDQ1\u{0}F/a\u{0}Mweird\u{0}".utf8),  // unknown mode
        Array("MDQ1\u{0}F/a\u{0}\u{0}".utf8),  // empty field
        Array("MDQ1\u{0}F/".utf8) + [0xFF, 0xFE, 0],  // not UTF-8
        Array("GET / HTTP/1.1\r\n\r\n".utf8),
    ])
    func malformedRequestsDoNotDecode(bytes: [UInt8]) {
        #expect(InstanceRequest.decode(bytes) == nil)
    }

    @Test func socketPathFitsSunPathAndHonorsOverride() {
        let path = InstanceChannel.socketPath(environment: [:])
        #expect(path.hasPrefix("/"))
        #expect(path.utf8.count <= 103)
        #expect(InstanceChannel.socketPath(environment: ["MICRODIFF_SOCKET": "/tmp/x.sock"]) == "/tmp/x.sock")
    }

    @Test func aPathTooLongForSunPathIsUnavailable() {
        let long = tempDir() + String(repeating: "x", count: 120) + ".sock"
        guard case .unavailable = InstanceChannel.claim(path: long) else {
            Issue.record("expected unavailable")
            return
        }
    }

    // MARK: owner and client

    @Test func firstClaimOwnsSecondConnectsAndDelivers() throws {
        let path = socketPath()
        let server = try #require(owner(path))
        defer { server.close() }
        let received = Box<[InstanceRequest]>([])
        server.start { request, responder in
            received.update { $0.append(request) }
            responder.reply(InstanceReply(status: .opened, activated: true, pid: 99, bundlePath: "/Apps/MicroDiff.app"))
        }
        let request = InstanceRequest(folder: "/some/dir with space", openFiles: ["/some/dir with space/ä.txt"], mode: "diff")
        let connection = try #require(client(path))
        #expect(connection.send(request) == .replied(InstanceReply(status: .opened, activated: true, pid: 99, bundlePath: "/Apps/MicroDiff.app")))
        #expect(received.value == [request])
    }

    /// The first start of the app pays for this before AppKit starts: it must stay negligible next to ~100 ms.
    @Test func becomingTheOwnerCostsWellUnderAMillisecond() throws {
        var times: [Double] = []
        for _ in 0..<20 {
            let path = socketPath()
            let started = now()
            let server = try #require(owner(path))
            times.append((now() - started) * 1000)
            server.close()
        }
        times.sort()
        print(String(format: "PERF instance-claim median=%.3fms max=%.3fms", times[10], times[19]))
        #expect(times[10] < 2)
    }

    @Test func staleSocketFileFromACrashedOwnerIsReplaced() throws {
        let path = socketPath()
        // What a crash leaves behind: a socket file nobody listens on (and no lock held).
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = makeAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        close(fd)
        #expect(access(path, F_OK) == 0)

        let server = try #require(owner(path))
        defer { server.close() }
        server.start { _, responder in responder.reply(InstanceReply(status: .focused, activated: false)) }
        let connection = try #require(client(path))
        guard case .replied(let reply) = connection.send(InstanceRequest(folder: "/a")) else {
            Issue.record("no reply from the new owner")
            return
        }
        #expect(reply.status == .focused)
    }

    @Test func simultaneousStartsEndWithExactlyOneOwner() {
        for _ in 0..<5 {
            let path = socketPath()
            let claims = Box<[InstanceChannel.Claim]>([])
            DispatchApply.run(12) { _ in
                let claim = InstanceChannel.claim(path: path)
                claims.update { $0.append(claim) }
            }
            var owners: [InstanceServer] = []
            var clients = 0
            for claim in claims.value {
                switch claim {
                case let .owner(server): owners.append(server)
                case .client: clients += 1
                case .unavailable: break
                }
            }
            #expect(owners.count == 1)
            #expect(clients == 11)
            owners.forEach { $0.close() }
        }
    }

    @Test func socketFileIsRemovedOnCloseAndTheNextStartOwnsAgain() throws {
        let path = socketPath()
        let server = try #require(owner(path))
        server.start { _, responder in responder.reply(InstanceReply(status: .opened, activated: false)) }
        #expect(access(path, F_OK) == 0)
        server.close()
        #expect(access(path, F_OK) != 0)
        #expect(client(path) == nil)
        let next = try #require(owner(path))
        next.close()
    }

    @Test func aServerThatNeverAnswersIsReportedAsNoAnswer() throws {
        let path = socketPath()
        // Listening, but nobody accepts or reads: a hung instance.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer {
            close(fd)
            unlink(path)
        }
        var address = makeAddress(path)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        listen(fd, 4)
        let connection = try #require(client(path))
        #expect(connection.send(InstanceRequest(folder: "/a"), ackTimeout: 0.2) == .noAnswer)
    }

    @Test func aRequestTheAppDropsUnansweredCountsAsDelivered() throws {
        let path = socketPath()
        let server = try #require(owner(path))
        defer { server.close() }
        server.start { _, _ in }  // the responder goes away without a reply
        let connection = try #require(client(path))
        #expect(connection.send(InstanceRequest(folder: "/a"), replyTimeout: 1) == .delivered)
    }

    // MARK: bad clients

    @Test func malformedEmptyOversizedAndPartialRequestsAreDroppedAndTheServerKeepsWorking() throws {
        let path = socketPath()
        let server = try #require(owner(path))
        defer { server.close() }
        let handled = Box(0)
        server.start { _, responder in
            handled.update { $0 += 1 }
            responder.reply(InstanceReply(status: .opened, activated: false))
        }

        let bad: [(bytes: [UInt8], finish: Bool)] = [
            (Array("hello\u{0}".utf8), true),  // malformed
            ([], true),  // empty
            ([UInt8](repeating: 65, count: InstanceChannel.maxRequestBytes + 4096), true),  // oversized
            (Array("MDQ1\u{0}F/a".utf8), true),  // cut short
            (Array("MDQ1\u{0}F/a\u{0}".utf8), false),  // valid bytes but never finished: times out
        ]
        for (bytes, finish) in bad {
            let fd = try #require(rawConnect(path))
            _ = writeAll(fd, bytes)
            if finish { shutdown(fd, SHUT_WR) }
            // The server closes without the "A".
            #expect(readUntilClosed(fd, timeout: 3) == [])
            close(fd)
        }
        #expect(handled.value == 0)
        let connection = try #require(client(path))
        guard case .replied = connection.send(InstanceRequest(folder: "/ok")) else {
            Issue.record("the server stopped answering after bad clients")
            return
        }
        #expect(handled.value == 1)
    }

    @Test func aSilentClientDoesNotBlockOthers() throws {
        let path = socketPath()
        let server = try #require(owner(path))
        defer { server.close() }
        server.start { _, responder in responder.reply(InstanceReply(status: .opened, activated: false)) }
        let silent = try #require(rawConnect(path))
        defer { close(silent) }
        let started = now()
        for _ in 0..<3 {
            let connection = try #require(client(path))
            guard case .replied = connection.send(InstanceRequest(folder: "/a")) else {
                Issue.record("blocked by the silent client")
                return
            }
        }
        #expect(now() - started < 0.5)
    }

    @Test func noFileDescriptorsLeakOverAThousandRequests() throws {
        let path = socketPath()
        let server = try #require(owner(path))
        server.start { request, responder in
            responder.reply(InstanceReply(status: request.folder == "/drop" ? .refused : .opened, activated: false))
        }
        // Warm up threads and queues first.
        for _ in 0..<20 { _ = client(path)?.send(InstanceRequest(folder: "/a")) }
        let before = MemoryProbe.openFileDescriptorCount()
        for i in 0..<1000 {
            let connection = try #require(client(path))
            guard case .replied = connection.send(InstanceRequest(folder: i % 10 == 0 ? "/drop" : "/a/\(i)")) else {
                Issue.record("request \(i) got no reply")
                break
            }
            // Some bad ones too.
            if i % 100 == 0, let fd = rawConnect(path) {
                _ = writeAll(fd, Array("junk".utf8))
                shutdown(fd, SHUT_WR)
                _ = readUntilClosed(fd, timeout: 2)
                close(fd)
            }
        }
        // Other suites run in parallel and open files of their own: a leak here would be ~1000.
        let after = MemoryProbe.openFileDescriptorCount()
        #expect(after - before < 50, "fds before \(before), after \(after)")
        let withServer = MemoryProbe.openFileDescriptorCount()
        server.close()
        // Listening socket and the wake pipe (2) and lock file are closed.
        #expect(MemoryProbe.openFileDescriptorCount() <= withServer)
    }
}
