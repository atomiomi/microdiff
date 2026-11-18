import Foundation

package struct GitError: Error, Sendable, Equatable {
    package var exitCode: Int32
    package var stderr: String
    package var arguments: [String]

    package init(exitCode: Int32, stderr: String, arguments: [String]) {
        self.exitCode = exitCode
        self.stderr = stderr
        self.arguments = arguments
    }
}

/// Runs the `git` command line tool. This is the only place that spawns processes.
package struct GitRunner: Sendable {
    /// Absolute path of the git binary in use.
    package let gitPath: String

    /// `gitPath` nil = find git once: `$MICRODIFF_GIT` if set, else the first existing of
    /// the Command Line Tools / Xcode git (not the slower `/usr/bin/git` shim when avoidable),
    /// `/opt/homebrew/bin/git`, `/usr/local/bin/git`, `/usr/bin/git`.
    package init(gitPath: String? = nil) {
        self.gitPath = gitPath ?? Self.locateGit()
    }

    private static func locateGit() -> String {
        let fileManager = FileManager.default
        if let custom = ProcessInfo.processInfo.environment["MICRODIFF_GIT"], fileManager.isExecutableFile(atPath: custom) {
            return custom
        }
        let candidates = [
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ]
        return candidates.first(where: fileManager.isExecutableFile(atPath:)) ?? "/usr/bin/git"
    }

    /// Runs `git --no-pager -c core.quotepath=false -c color.ui=false -C <directory> <args...>` and returns stdout.
    ///
    /// - Environment adds `GIT_OPTIONAL_LOCKS=0` (never write the index: the app only reads),
    ///   `GIT_TERMINAL_PROMPT=0`, `LC_ALL=C`. Everything else is inherited.
    /// - stdout and stderr are drained together, so large outputs cannot deadlock.
    /// - Throws `GitError` when the exit code is not in `allowedExitCodes` or the process cannot start (exitCode -1).
    package func run(_ args: [String], in directory: String, allowedExitCodes: Set<Int32> = [0]) throws -> Data {
        try run(args, in: directory, allowedExitCodes: allowedExitCodes, environment: Self.environment, limit: nil)
    }

    /// Runs a command that talks to a remote repository. It can never ask anyone for anything (no prompt on a terminal,
    /// no password window; the user's ssh and credential settings stay as they are, so keys and stored credentials still
    /// work), and it is stopped (killed with everything it started) when `limit` runs out or is cancelled: then it
    /// throws `GitError` with exit code -2.
    package func runRemote(_ args: [String], in directory: String, limit: ChildProcess.Limit) throws -> Data {
        let environment = ChildProcess.environment(overriding: Self.remoteOverrides, removing: Self.remoteRemovals)
        return try run(args, in: directory, allowedExitCodes: [0], environment: environment, limit: limit)
    }

    private func run(
        _ args: [String], in directory: String, allowedExitCodes: Set<Int32>, environment: [String], limit: ChildProcess.Limit?
    ) throws -> Data {
        let argv = [gitPath, "--no-pager", "-c", "core.quotepath=false", "-c", "color.ui=false", "-C", directory] + args
        guard let result = ChildProcess.run(path: gitPath, arguments: argv, environment: environment, limit: limit) else {
            throw GitError(exitCode: -1, stderr: String(cString: strerror(errno)), arguments: args)
        }
        guard !result.wasStopped else { throw GitError(exitCode: -2, stderr: "stopped", arguments: args) }
        guard allowedExitCodes.contains(result.exitCode) else {
            let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(exitCode: result.exitCode, stderr: message, arguments: args)
        }
        return result.stdout
    }

    private static let overrides = [
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
        "LC_ALL": "C",
    ]

    /// The inherited environment plus the overrides, as "KEY=value" strings. Built once.
    private static let environment: [String] = ChildProcess.environment(overriding: overrides)

    /// What a remote command sets on top: an askpass program that answers nothing, ssh never asking for a password.
    package static let remoteOverrides = overrides.merging([
        "GIT_ASKPASS": "/usr/bin/true",
        "SSH_ASKPASS_REQUIRE": "never",
        "GCM_INTERACTIVE": "never",
    ]) { _, new in new }

    /// What a remote command does not inherit: the helpers that would open a window.
    package static let remoteRemovals = ["SSH_ASKPASS", "DISPLAY"]
}

/// Runs a child process to completion and collects its output.
///
/// Built on `posix_spawn` and `waitpid` instead of Foundation's `Process`: `Process.waitUntilExit`
/// depends on the main thread being free, which made every git call slow (about 70 ms instead of 5)
/// whenever the app was busy launching or drawing.
package enum ChildProcess {
    package struct Result: Sendable {
        package var exitCode: Int32
        package var stdout: Data
        package var stderr: Data
        /// The process was killed because its `Limit` ran out or was cancelled (the exit code then says nothing).
        package var wasStopped = false
    }

    /// Says when a process is to be stopped: after `seconds`, or as soon as `cancel` is cancelled.
    package struct Limit: Sendable {
        package var seconds: TimeInterval
        package var cancel: CancelToken?

        package init(seconds: TimeInterval, cancel: CancelToken? = nil) {
            self.seconds = seconds
            self.cancel = cancel
        }
    }

    /// The current environment with `overrides` applied and the `removing` names taken out, as "KEY=value" strings.
    package static func environment(overriding overrides: [String: String], removing removed: [String] = []) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        for key in removed { environment[key] = nil }
        for (key, value) in overrides { environment[key] = value }
        return environment.map { "\($0.key)=\($0.value)" }
    }

    /// Runs `path` with `arguments` (the first is the program name), stdin from /dev/null.
    /// With a `limit` the process gets a session of its own (no terminal to ask on) and is killed together with
    /// everything it started when the limit runs out; its pipes, thread and process are all released before this returns.
    /// Returns nil when the process cannot be started; `errno` then says why.
    package static func run(path: String, arguments: [String], environment: [String], limit: Limit? = nil) -> Result? {
        guard let (pid, outFD, errFD) = spawn(
            path: path, arguments: arguments, environment: environment, ownSession: limit != nil) else { return nil }
        let deadline = limit.map { ContinuousClock.now + .seconds($0.seconds) }
        var wasStopped = false

        // One thread reads both pipes: if either fills up while we block on the other, the child stalls.
        var output = Data()
        var errors = Data()
        var fds = [pollfd(fd: outFD, events: Int16(POLLIN), revents: 0), pollfd(fd: errFD, events: Int16(POLLIN), revents: 0)]
        var open = 2
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while open > 0 {
            var wait: Int32 = -1
            if let limit, let deadline {
                let left = deadline - ContinuousClock.now
                if left <= .zero || limit.cancel?.isCancelled == true {
                    wasStopped = true
                    break
                }
                // Short steps when it can be cancelled from outside; otherwise just until the deadline.
                let milliseconds = Int64(left.components.seconds) * 1000 + left.components.attoseconds / 1_000_000_000_000_000
                wait = Int32(min(milliseconds + 1, limit.cancel == nil ? Int64(Int32.max) : 100))
            }
            if poll(&fds, 2, wait) < 0 {
                if errno == EINTR { continue }
                break
            }
            for i in 0..<2 where fds[i].fd >= 0 && fds[i].revents != 0 {
                let count = read(fds[i].fd, buffer, bufferSize)
                if count > 0 {
                    if i == 0 { output.append(buffer, count: count) } else { errors.append(buffer, count: count) }
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    close(fds[i].fd)
                    fds[i].fd = -1
                    open -= 1
                }
            }
        }
        for descriptor in fds where descriptor.fd >= 0 { close(descriptor.fd) }
        // The process leads its own group: everything it started (ssh, a remote helper) goes with it.
        if wasStopped { kill(-pid, SIGKILL) }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        // Same decoding as the WIFEXITED / WEXITSTATUS / WTERMSIG macros.
        let signal = status & 0x7F
        return Result(exitCode: signal == 0 ? (status >> 8) & 0xFF : 128 + signal, stdout: output, stderr: errors, wasStopped: wasStopped)
    }

    /// Serializes the short moment between creating pipes and spawning. A child spawned by another thread in
    /// that moment could inherit a pipe's write end, and its reader would then never see end-of-file.
    private static let spawnLock = NSLock()

    private static func spawn(
        path: String, arguments: [String], environment: [String], ownSession: Bool
    ) -> (pid: pid_t, out: Int32, err: Int32)? {
        spawnLock.lock()
        defer { spawnLock.unlock() }

        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { return nil }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0])
            close(outPipe[1])
            return nil
        }
        for descriptor in outPipe + errPipe { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // The child gets stdin/stdout/stderr and nothing else of ours.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | (ownSession ? POSIX_SPAWN_SETSID : 0)))

        let cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let cEnvironment: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            for pointer in cArguments + cEnvironment { free(pointer) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, cArguments, cEnvironment)
        close(outPipe[1])
        close(errPipe[1])
        guard result == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            errno = result
            return nil
        }
        return (pid, outPipe[0], errPipe[0])
    }
}

/// Lets one thread stop work that another thread is doing.
package final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    package init() {}

    package var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    package func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
