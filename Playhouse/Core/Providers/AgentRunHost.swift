import Foundation

// Provider agents that outlive the daemon that started them. A daemon can die mid-turn (a
// crash, SIGKILL, or a rebuild that replaces it); the agent keeps running in its own session
// with file-backed or socket stdio, and the next daemon of the same service finds it again
// through the manifest written here. Foundation and Darwin only, so the unit tests compile
// this file alone.

/// The bridge service this daemon serves. Every run and shared server is recorded under it,
/// and a daemon only reattaches, sweeps or stops its own service's agents: a test suite's
/// private daemon on the same data folder never touches another service's.
package enum AgentRunService {
    package static var name = "com.playhouse.app.bridge"
}

/// One process, told apart from a later process that reuses its pid by its start time.
package struct AgentProcessIdentity: Codable, Hashable, Sendable {
    package var pid: Int32
    /// `kp_proc.p_starttime` in microseconds since 1970.
    package var startTime: Int64

    /// The live process with this pid, or nil when there is none.
    package static func current(pid: Int32) -> AgentProcessIdentity? {
        guard pid > 0, let startTime = POSIX.processStartMicroseconds(pid: pid) else { return nil }
        return AgentProcessIdentity(pid: pid, startTime: startTime)
    }

    /// False for a missing pid, a zombie, or a different process that reuses the pid.
    package var isAlive: Bool {
        guard !POSIX.isZombie(pid: pid) else { return false }
        return Self.current(pid: pid) == self
    }

    package init(pid: Int32, startTime: Int64) {
        self.pid = pid
        self.startTime = startTime
    }
}

package enum AgentRunHostError: LocalizedError {
    case spawnFailed(String, Int32)
    case lockTimedOut(String)

    package var errorDescription: String? {
        switch self {
        case .spawnFailed(let executable, let code):
            "Couldn't start \(executable) (\(String(cString: strerror(code))))."
        case .lockTimedOut(let path):
            "Another Playhouse service process still owns \(path)."
        }
    }
}

package enum AgentRunHost {
    /// Where a spawned agent's standard descriptor comes from.
    package enum StandardStream {
        /// A path opened for the child with these flags.
        case path(String, flags: Int32)
        /// A descriptor the caller holds; the child gets a duplicate.
        case descriptor(Int32)
    }

    /// Starts `executable` in its own session and process group, so signals aimed at the daemon
    /// never reach it, with only the three standard descriptors open: the daemon's bridge socket
    /// and every other descriptor stay behind.
    package static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        stdin: StandardStream,
        stdout: StandardStream,
        stderr: StandardStream
    ) throws -> AgentProcessIdentity {
        var actions = POSIX.spawnFileActions()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (target, stream) in [(Int32(0), stdin), (1, stdout), (2, stderr)] {
            switch stream {
            case .path(let path, let flags):
                posix_spawn_file_actions_addopen(&actions, target, path, flags, 0o600)
            case .descriptor(let descriptor):
                posix_spawn_file_actions_adddup2(&actions, descriptor, target)
            }
        }
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)

        var attributes = POSIX.spawnAttributes()
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, POSIX.detachedSpawnFlags)
        // The daemon ignores SIGPIPE; the agent gets the default dispositions back.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard result == 0 else { throw AgentRunHostError.spawnFailed(executable, result) }
        // The start time exists from the moment the process does.
        return AgentProcessIdentity.current(pid: pid) ?? AgentProcessIdentity(pid: pid, startTime: 0)
    }

    /// SIGTERM to the agent's process group, then SIGKILL after `grace`, only while the identity
    /// still names the process that was started. Never blocks the caller's actor.
    package static func terminate(_ identity: AgentProcessIdentity, grace: TimeInterval = 1) async {
        guard identity.isAlive else {
            if AgentProcessIdentity.current(pid: identity.pid) == identity { reapIfChild(identity.pid) }
            return
        }
        signal(identity, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            reapIfChild(identity.pid)
            guard identity.isAlive else { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        if identity.isAlive { signal(identity, SIGKILL) }
        reapIfChild(identity.pid)
    }

    /// Tool shells can create their own process groups. Signal the root group
    /// and every separately identified descendant captured before teardown.
    package static func killProcessTree(_ identity: AgentProcessIdentity, descendants: [AgentProcessIdentity]) {
        guard identity.isAlive else { return }
        signal(identity, SIGKILL)
        for process in descendants.reversed() where process.isAlive {
            kill(process.pid, SIGKILL)
        }
    }

    private static func signal(_ identity: AgentProcessIdentity, _ signal: Int32) {
        // The agent leads its own group (SETSID); a group signal also reaches its children.
        if killpg(identity.pid, signal) != 0 { kill(identity.pid, signal) }
    }

    /// Collects a child of this process that has exited, so it doesn't linger as a zombie.
    @discardableResult
    package static func reapIfChild(_ pid: Int32) -> Int32? {
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return nil }
        return status
    }

    /// Calls `handler` once when the process exits, also for a process this daemon didn't start.
    /// A child of this process is reaped, and its wait status is passed on.
    package static func onExit(_ identity: AgentProcessIdentity, queue: DispatchQueue = .global(), handler: @escaping @Sendable (Int32?) -> Void) -> ProcessExitWatch {
        let fired = OneShot()
        let watch = WatchReference()
        let fire: @Sendable () -> Void = {
            guard fired.claim() else { return }
            let status = reapIfChild(identity.pid)
            watch.value?.cancel()
            handler(status)
        }
        let source = ProcessExitWatch(pid: identity.pid, queue: queue, handler: fire)
        watch.value = source
        // A process that exited before the watch existed raises no event.
        if !identity.isAlive { queue.async(execute: fire) }
        return source
    }

    /// The watch, for its own handler to cancel once it fired.
    private final class WatchReference: @unchecked Sendable {
        var value: ProcessExitWatch?
    }

    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

/// Writes newline-delimited messages into an agent's input FIFO, off the caller's actor.
///
/// Claude Code's runtime (Bun), like Node and other kqueue-based readers, reads stdin only after
/// kqueue reports it readable. On macOS kqueue does not report a FIFO readable while a blocking
/// write() of more than the FIFO holds is pending, so one such write (a message with an image,
/// say) to an idle agent never completes. The descriptor is non-blocking, so no write() is ever
/// left pending, and lines go out in `chunkSize` pieces; the writer waits for room with poll().
/// The non-blocking descriptor also lets a line that makes no progress for `stallTimeout` fail
/// instead of waiting forever. A failed line may be cut off in the agent's input, so the writer
/// refuses every line after it.
package final class AgentInputWriter: @unchecked Sendable {
    package enum WriteError: LocalizedError, Equatable {
        case stalled(seconds: Int)
        case failed(code: Int32)
        case closed

        package var errorDescription: String? {
            switch self {
            case .stalled(let seconds):
                "The agent stopped reading its input for \(seconds) seconds."
            case .failed(let code):
                "Couldn't write to the agent's input (\(String(cString: strerror(code))))."
            case .closed:
                "The agent's input is closed."
            }
        }
    }

    /// Well under the smallest FIFO buffer macOS gives (8 KiB and above wake an idle reader;
    /// a 16 KiB write does not).
    package static let chunkSize = 4096

    package let path: String
    package let stallTimeout: TimeInterval
    private let queue = DispatchQueue(label: "com.playhouse.agent-input")
    // Confined to `queue`.
    private var descriptor: Int32 = -1
    private var failure: WriteError?

    package init(path: String, stallTimeout: TimeInterval = 30) {
        self.path = path
        self.stallTimeout = stallTimeout
    }

    deinit {
        if descriptor >= 0 { POSIX.close(descriptor) }
    }

    /// Queues `line`. Lines are written whole and one after another, in the order they were
    /// queued; `completion` runs on the writer's queue once the line is written or has failed.
    package func enqueue(_ line: Data, completion: @escaping @Sendable (WriteError?) -> Void) {
        queue.async { completion(self.writeNow(line)) }
    }

    /// Closes the descriptor once the lines already queued are done; later lines fail.
    package func close() {
        queue.async {
            if self.descriptor >= 0 { POSIX.close(self.descriptor) }
            self.descriptor = -1
            if self.failure == nil { self.failure = .closed }
        }
    }

    private func writeNow(_ line: Data) -> WriteError? {
        if let failure { return failure }
        if descriptor < 0 {
            // Opens without waiting: the agent holds its own end, so a reader always exists.
            let opened = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            guard opened >= 0 else { return .failed(code: errno) }
            POSIX.disableSIGPIPE(onFile: opened)
            descriptor = opened
        }
        let result: WriteError? = line.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            var offset = 0
            var lastProgress = ProcessInfo.processInfo.systemUptime
            while offset < bytes.count {
                let written = POSIX.write(descriptor, base + offset, min(Self.chunkSize, bytes.count - offset))
                if written > 0 {
                    offset += written
                    lastProgress = ProcessInfo.processInfo.systemUptime
                    continue
                }
                let code = written < 0 ? errno : EIO
                if code == EINTR { continue }
                guard code == EAGAIN else { return .failed(code: code) }
                let remaining = stallTimeout - (ProcessInfo.processInfo.systemUptime - lastProgress)
                if remaining <= 0 { return .stalled(seconds: Int(stallTimeout.rounded())) }
                // Waits for room, and looks again at least once a second.
                var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                _ = poll(&request, 1, Int32(min(remaining, 1) * 1000))
            }
            return nil
        }
        if let result { failure = result }
        return result
    }
}

/// Atomic JSON files: written to a temporary sibling and renamed into place, so a reader never
/// sees half a manifest even when the writer is killed mid-write.
package enum AgentManifestFile {
    package static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    package static func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// An exclusive lock beside a manifest, held by the one daemon that drives its agent. The kernel
/// releases it when that daemon exits however it exits, so a successor takes over as soon as its
/// predecessor is gone and never while it still runs.
package final class AgentOwnershipLock: @unchecked Sendable {
    package let path: String
    private var descriptor: Int32

    private init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    deinit { release() }

    /// Waits up to `timeout` for the lock.
    package static func acquire(path: String, timeout: TimeInterval) async throws -> AgentOwnershipLock {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let lock = try tryAcquire(path: path) { return lock }
            guard Date() < deadline else { throw AgentRunHostError.lockTimedOut(path) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The lock now, or nil while another holder has it. `flock` locks belong to one open
    /// file, so a second holder in this same process is refused too.
    package static func tryAcquire(path: String) throws -> AgentOwnershipLock? {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path]) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
        }
        return AgentOwnershipLock(path: path, descriptor: descriptor)
    }

    /// Whether any holder has the lock right now.
    package static func isHeld(path: String) -> Bool {
        guard let lock = try? tryAcquire(path: path) else { return FileManager.default.fileExists(atPath: path) }
        lock.release()
        return false
    }

    package func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}

/// Splits an append-only log into complete lines. A partial last line stays buffered until its
/// newline arrives, and every line carries the offset just past it, so a reader that commits an
/// offset never commits half a line.
package struct LineTailer {
    package private(set) var offset: UInt64
    private var pending = Data()

    package init(offset: UInt64 = 0) {
        self.offset = offset
    }

    /// The offset the next unconsumed line starts at.
    package var consumedOffset: UInt64 { offset - UInt64(pending.count) }

    package mutating func append(_ data: Data) -> [(line: Data, endOffset: UInt64)] {
        guard !data.isEmpty else { return [] }
        pending.append(data)
        offset += UInt64(data.count)
        var lines: [(Data, UInt64)] = []
        var lineStart = pending.startIndex
        var consumed = offset - UInt64(pending.count)
        while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
            let line = pending[lineStart..<newline]
            consumed += UInt64(newline - lineStart + 1)
            lines.append((Data(line), consumed))
            lineStart = pending.index(after: newline)
        }
        pending = Data(pending[lineStart...])
        return lines
    }

    /// Reads everything `descriptor` holds past what was already read.
    package mutating func read(from descriptor: Int32) -> [(line: Data, endOffset: UInt64)] {
        var lines: [(Data, UInt64)] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = pread(descriptor, &buffer, buffer.count, off_t(offset))
            guard count > 0 else { break }
            lines += append(Data(buffer[0..<count]))
        }
        return lines
    }
}

/// Finds agent processes that no manifest accounts for: processes of this user whose standard
/// descriptors point into one of Playhouse's run folders. A daemon killed between spawning an
/// agent and recording it would otherwise leave that agent running unseen.
package enum AgentProcessSweep {
    package struct Found: Equatable {
        package var identity: AgentProcessIdentity
        package var parentPID: Int32
        /// The run-folder file one of its standard descriptors has open.
        package var path: String

        package init(identity: AgentProcessIdentity, parentPID: Int32, path: String) {
            self.identity = identity
            self.parentPID = parentPID
            self.path = path
        }
    }

    package static func processes(withStandardStreamsUnder roots: [String]) -> [Found] {
        let roots = roots.map { ($0 as NSString).resolvingSymlinksInPath.hasSuffix("/") ? $0 : ($0 as NSString).resolvingSymlinksInPath + "/" }
        let user = getuid()
        var found: [Found] = []
        for pid in POSIX.allProcessIDs() where pid > 0 && pid != getpid() {
            guard let summary = POSIX.processSummary(pid: pid), summary.userID == user else { continue }
            for descriptor in Int32(0)...2 {
                guard let path = POSIX.openFilePath(pid: pid, descriptor: descriptor).map({ ($0 as NSString).resolvingSymlinksInPath }),
                      roots.contains(where: { path.hasPrefix($0) }),
                      let identity = AgentProcessIdentity.current(pid: pid) else { continue }
                found.append(Found(identity: identity, parentPID: summary.parentPID, path: path))
                break
            }
        }
        return found
    }
}

/// Unix socket paths are limited to 104 bytes, and a worktree's data folder can exceed that.
package enum AgentSocketPath {
    package static let maximumLength = 103

    /// `preferred` when it fits, otherwise a private per-user folder in /tmp.
    package static func resolve(preferred: String, fileName: String) -> String {
        if preferred.utf8.count <= maximumLength { return preferred }
        // Same layout as the bridge socket's folder: private to this user.
        let directory = "/tmp/playhouse-codex/\(getuid())"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return "\(directory)/\(fileName)"
    }
}

/// What a daemon records about one `claude -p` run with file-backed stdio, so a later daemon of
/// the same service can carry it on. Claude Code speaks only stdio: its stdin is a FIFO the run
/// itself also holds open (so it never sees end of input between writers), and its stdout and
/// stderr are append-only files the daemon tails.
package struct ClaudeRunManifest: Codable, Equatable {
    package var version = 1
    package var serviceName: String
    package var sessionID: String
    /// `spawning` until the process identity is recorded, then `running`.
    package var state: String
    package var process: AgentProcessIdentity?
    package var createdAt: Date
    package var mode: String
    /// Everything before this offset of `agent.out` was handled and its transcript written.
    package var consumedOffset: UInt64 = 0
    /// The highest `playhouse-N` control request ID sent; a later runner never reuses one.
    package var maxRequestID = 0
    /// Questions read from the log and still waiting for the user's answer.
    package var pendingRequestIDs: [String] = []
    /// Control requests already answered; a later daemon never answers them again.
    package var answeredRequestIDs: [String] = []
    /// Set while a line is being written to `agent.in`. Claude Code exits on a malformed line,
    /// so a daemon killed mid-write leaves a turn that can't continue.
    package var writeInProgress = false

    /// Answers written for requests read up to `offset`: committed together, so a daemon that
    /// dies before the commit answers them again (Claude Code ignores a repeated reply) and one
    /// that dies after never does.
    package mutating func commit(answered: [String], pending: [String] = [], offset: UInt64) {
        answeredRequestIDs = Array(Set(answeredRequestIDs).union(answered)).sorted()
        pendingRequestIDs = Array(Set(pendingRequestIDs).union(pending).subtracting(answeredRequestIDs)).sorted()
        consumedOffset = max(consumedOffset, offset)
    }

    package func hasAnswered(_ requestID: String) -> Bool { answeredRequestIDs.contains(requestID) }

    package init(version: Int = 1, serviceName: String, sessionID: String, state: String, process: AgentProcessIdentity? = nil, createdAt: Date, mode: String, consumedOffset: UInt64 = 0, maxRequestID: Int = 0, pendingRequestIDs: [String] = [], answeredRequestIDs: [String] = [], writeInProgress: Bool = false) {
        self.version = version
        self.serviceName = serviceName
        self.sessionID = sessionID
        self.state = state
        self.process = process
        self.createdAt = createdAt
        self.mode = mode
        self.consumedOffset = consumedOffset
        self.maxRequestID = maxRequestID
        self.pendingRequestIDs = pendingRequestIDs
        self.answeredRequestIDs = answeredRequestIDs
        self.writeInProgress = writeInProgress
    }
}

package enum ClaudeRunFiles {
    package static func runsDirectory(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("provider-runs", isDirectory: true)
    }

    package static func manifestURL(_ runDirectory: URL) -> URL { runDirectory.appendingPathComponent("run.json") }
    package static func inputPath(_ runDirectory: URL) -> String { runDirectory.appendingPathComponent("agent.in").path }
    package static func outputPath(_ runDirectory: URL) -> String { runDirectory.appendingPathComponent("agent.out").path }
    package static func errorPath(_ runDirectory: URL) -> String { runDirectory.appendingPathComponent("agent.err").path }

    /// Every run `serviceName` left in `runsDirectory` (every service's, for nil), with its folder.
    package static func runs(in runsDirectory: URL, serviceName: String? = AgentRunService.name) -> [(directory: URL, manifest: ClaudeRunManifest)] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let manifest = AgentManifestFile.read(ClaudeRunManifest.self, from: manifestURL(folder)),
                  serviceName == nil || manifest.serviceName == serviceName else { return nil }
            return (folder, manifest)
        }
    }

    package static func manifests(in runsDirectory: URL) -> [ClaudeRunManifest] { runs(in: runsDirectory).map(\.manifest) }

    /// A reattached runner numbers its control requests well past any the previous daemon
    /// sent, so a late reply to an old request can never answer a new one.
    package static func firstRequestID(afterReattaching savedMaximum: Int) -> Int { savedMaximum + 1000 }

    /// A reply to a request the previous daemon sent, which no one is waiting for any more.
    package static func isStaleReply(_ requestID: String, savedMaximum: Int) -> Bool {
        guard requestID.hasPrefix("playhouse-"), let number = Int(requestID.dropFirst("playhouse-".count)) else { return false }
        return number <= savedMaximum
    }
}
