import Darwin
import Foundation

enum BridgeSocketError: LocalizedError {
    case pathTooLong(String)
    case connectionClosed
    case readTimedOut
    case daemonNotFound
    case spawnTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .spawnTimedOut(let path): "The daemon at \(path) did not start listening within 10 seconds."
        case .daemonNotFound: "Couldn't find the Playhouse bridge daemon. Reinstall Playhouse."
        case .pathTooLong(let path): "Socket path is too long for a Unix domain socket: \(path)"
        case .connectionClosed: "The bridge connection closed unexpectedly."
        case .readTimedOut: "Timed out waiting for the bridge connection."
        }
    }
}

private func makeUnixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw BridgeSocketError.pathTooLong(path)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
        let buffer = rawBuffer.bindMemory(to: Int8.self)
        for (index, byte) in pathBytes.enumerated() { buffer[index] = Int8(bitPattern: byte) }
        buffer[pathBytes.count] = 0
    }
    return address
}

/// One accepted or outgoing connection over an `AF_UNIX` stream socket. All I/O
/// here is blocking POSIX I/O; callers run it on a dedicated thread/queue, the
/// same way the rest of this codebase bridges blocking child-process I/O
/// (`Process`/`Pipe` readability handlers) into Swift concurrency.
final class BridgeSocketConnection {
    private let descriptor: Int32
    /// Releasing the descriptor number lets the process hand it to guarded file state, so
    /// a write arriving afterwards would not merely fail — it would raise EXC_GUARD and
    /// take the daemon down. Background work that outlives its request still holds the
    /// request's event sink, so such late writes do happen.
    ///
    /// `close()` therefore ends the conversation without releasing the number: it marks
    /// the connection closed and shuts the socket down, and only `deinit` calls
    /// `Darwin.close`. While any late writer can still reach this object, the object is
    /// alive and owns its number, so a late write fails as an ordinary EPIPE/ENOTCONN
    /// instead of landing on an unrelated file. No lock is held across the write itself,
    /// so a stalled peer can never block `close()`.
    private let state = NSLock()
    private var isClosed = false

    private var closedNow: Bool {
        state.lock()
        defer { state.unlock() }
        return isClosed
    }

    deinit {
        Darwin.close(descriptor)
    }

    /// The connected process, as the kernel reports it, or nil when it can't say.
    var peerProcessID: pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
        // Writing to a peer that has gone away returns EPIPE instead of
        // raising SIGPIPE, for the CLI as well as the daemon.
        var on: Int32 = 1
        _ = Darwin.setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func connect(to path: String) throws -> BridgeSocketConnection {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = try makeUnixAddress(path: path)
        let addressSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, addressSize)
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return BridgeSocketConnection(descriptor: descriptor)
    }

    func write(_ data: Data) throws {
        guard !closedNow else { throw BridgeSocketError.connectionClosed }
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                if written == 0 { throw BridgeSocketError.connectionClosed }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }

    /// Blocking reads (and `read()`'s own `EAGAIN`) surface as
    /// `BridgeSocketError.readTimedOut` instead of silently hanging forever,
    /// once `setReceiveTimeout` is used; an empty result (not an error) means
    /// the peer genuinely closed the connection (`read()` returned 0).
    func readAvailable(maxLength: Int = 64 * 1024) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(descriptor, rawBuffer.baseAddress, maxLength)
        }
        if bytesRead < 0 {
            if errno == EINTR { return try readAvailable(maxLength: maxLength) }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw BridgeSocketError.readTimedOut }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Data(buffer.prefix(bytesRead))
    }

    /// Reads and frame-decodes values until `extractMessages` yields at least
    /// one, or the peer closes the connection.
    func readMessages<T: Decodable>(as type: T.Type, buffer: inout Data) throws -> [T] {
        while true {
            let messages = try BridgeFraming.extractMessages(from: &buffer, as: type)
            if !messages.isEmpty { return messages }
            let chunk = try readAvailable()
            if chunk.isEmpty { throw BridgeSocketError.connectionClosed }
            buffer.append(chunk)
        }
    }

    /// `read()` returns `EAGAIN`/`EWOULDBLOCK` (surfaced as `.readTimedOut`)
    /// after this many seconds with nothing to read, instead of blocking
    /// forever — lets a caller enforce its own overall deadline in a loop.
    func setReceiveTimeout(seconds: Double) {
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        _ = Darwin.setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func close() {
        state.lock()
        let wasClosed = isClosed
        isClosed = true
        state.unlock()
        guard !wasClosed else { return }
        // Ends the connection for the peer (it sees EOF) and frees anyone blocked on it,
        // without releasing the descriptor number; `deinit` does that.
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    /// Wakes any thread blocked reading this connection, which a bare `close()`
    /// does not reliably do.
    func shutdown() {
        guard !closedNow else { return }
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    }
}

/// A listening `AF_UNIX` stream socket. `accept()` blocks; the daemon runs it
/// in its own loop on a dedicated thread.
final class BridgeSocketListener {
    private let descriptor: Int32
    let path: String

    private init(descriptor: Int32, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    /// Binds and listens at `path`, replacing a stale socket file a prior
    /// daemon instance left behind (e.g. after a hard crash).
    static func listen(at path: String, backlog: Int32 = 16) throws -> BridgeSocketListener {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Never unlink a socket a daemon is still accepting on. A spawner that only
        // thought nothing was listening (a connect that failed transiently, or a
        // sandboxed caller whose own bind is going to fail) would otherwise leave
        // that daemon alive but unreachable for every later caller.
        if let live = try? BridgeSocketConnection.connect(to: path) {
            live.close()
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EADDRINUSE))
        }
        unlink(path) // best-effort; ENOENT is fine, any other failure surfaces at bind()
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = try makeUnixAddress(path: path)
        let addressSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(descriptor, sockaddrPointer, addressSize)
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        chmod(path, 0o600)
        guard Darwin.listen(descriptor, backlog) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return BridgeSocketListener(descriptor: descriptor, path: path)
    }

    func accept() throws -> BridgeSocketConnection {
        let clientDescriptor = Darwin.accept(descriptor, nil, nil)
        guard clientDescriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return BridgeSocketConnection(descriptor: clientDescriptor)
    }

    func close() {
        Darwin.close(descriptor)
        unlink(path)
    }
}

/// Connects to the bridge daemon's socket, starting the daemon first if nothing
/// answers. Shared by the CLI and the app, so a window and a command-line call
/// that race to start it can't produce two daemons.
enum BridgeDaemonLauncher {
    static func connect(socketPath: String, serviceName: String, daemonExecutablePath: String?) throws -> BridgeSocketConnection {
        retireStaleDaemonIfNeeded(socketPath: socketPath, daemonExecutablePath: daemonExecutablePath)
        if let connection = try? BridgeSocketConnection.connect(to: socketPath) {
            return connection
        }
        try spawnIfNeeded(socketPath: socketPath, serviceName: serviceName, daemonExecutablePath: daemonExecutablePath)
        let deadline = Date().addingTimeInterval(10)
        var lastError: Error?
        while Date() < deadline {
            do {
                return try BridgeSocketConnection.connect(to: socketPath)
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw BridgeSocketError.spawnTimedOut("\(daemonExecutablePath ?? ""); last connect error: \(lastError.map { "\($0)" } ?? "none")")
    }

    private static let spawnLock = NSLock()
    private static let helloLock = NSLock()
    private static var greetedSockets = Set<String>()

    /// Once per process and socket, asks the daemon listening there whether it
    /// still runs the daemon executable this caller ships beside. After an update
    /// replaced the app bundle, a daemon started from the old bundle keeps
    /// serving at the same path with the old code; it answers `stale` and exits,
    /// and the caller starts the new one. A daemon run from a different copy of
    /// the app is never asked to leave, so two copies never take turns.
    private static func retireStaleDaemonIfNeeded(socketPath: String, daemonExecutablePath: String?) {
        guard let daemonExecutablePath, let expected = BridgeDaemonIdentity(executablePath: daemonExecutablePath) else { return }
        helloLock.lock()
        defer { helloLock.unlock() }
        guard !greetedSockets.contains(socketPath) else { return }
        greetedSockets.insert(socketPath)
        guard let connection = try? BridgeSocketConnection.connect(to: socketPath) else { return }
        let response = try? request(
            BridgeRequest(command: "daemon.hello", arguments: ["expected": (try? BridgeValue.encoding(expected)) ?? .null]),
            over: connection
        )
        connection.close()
        guard let result = response?.result?.object, result["stale"]?.bool == true,
              let processID = result["processID"]?.int, processID > 0 else { return }
        waitForExit(pid_t(processID), timeout: daemonExitTimeout)
    }

    /// Whether `response` is an exiting daemon's refusal, after waiting a moment
    /// so the caller's next connect reaches the daemon that follows it. Gives up
    /// at `deadline`, after which the caller reports the refusal.
    static func shouldRetry(_ response: BridgeResponse, until deadline: Date) -> Bool {
        guard response.error?.code == BridgeContract.daemonExitingCode, Date() < deadline else { return false }
        Thread.sleep(forTimeInterval: 0.1)
        return true
    }

    /// How long to let a stopping daemon finish: it drains open requests for up
    /// to two seconds and hands its agents to the daemon that follows it.
    static let daemonExitTimeout: TimeInterval = 20

    /// Waits for a process to exit, then terminates it if it still runs.
    /// Returns whether it exited by itself within `timeout`.
    @discardableResult
    static func waitForExit(_ processID: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(processID, 0) != 0 { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(processID, SIGTERM)
        let killDeadline = Date().addingTimeInterval(3)
        while Date() < killDeadline {
            if kill(processID, 0) != 0 { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(processID, SIGKILL)
        return false
    }

    /// Sends one request over an open connection and reads its final response,
    /// ignoring events. Used for the daemon's own lifecycle commands.
    static func request(_ request: BridgeRequest, over connection: BridgeSocketConnection, timeout: Double = 15) throws -> BridgeResponse {
        connection.setReceiveTimeout(seconds: timeout)
        try connection.write(BridgeFraming.frame(request))
        var buffer = Data()
        while true {
            for message in try connection.readMessages(as: BridgeWireMessage.self, buffer: &buffer) {
                if case .response(let response) = message { return response }
            }
        }
    }

    /// Lock-guarded so two callers racing to start the daemon for the same
    /// socket path don't both spawn one; the loser simply finds the winner's
    /// daemon already listening once it gets the lock.
    private static func spawnIfNeeded(socketPath: String, serviceName: String, daemonExecutablePath: String?) throws {
        let lockPath = socketPath + ".spawn.lock"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: lockPath).deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // The fcntl record lock below excludes other processes, but it belongs to the whole
        // process: the app's concurrent requests at launch would each take it and each spawn a
        // daemon, and any thread closing its descriptor to the lock file would drop the lock for
        // all of them. This lock excludes the other threads of this process before `open`.
        spawnLock.lock()
        defer { spawnLock.unlock() }
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLKW, &lock) == 0 else { return }
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
        }
        // Someone else may have started the daemon while we waited for the lock.
        if (try? BridgeSocketConnection.connect(to: socketPath))?.close() != nil { return }

        guard let daemonExecutablePath, FileManager.default.isExecutableFile(atPath: daemonExecutablePath) else {
            throw BridgeSocketError.daemonNotFound
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: daemonExecutablePath)
        var environment = ProcessInfo.processInfo.environment
        environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"] = serviceName
        environment["PLAYHOUSE_BRIDGE_SOCKET_PATH"] = socketPath
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        // Keep the daemon's own diagnostics beside its socket, appending so one
        // daemon's start doesn't erase what its predecessors reported.
        let logPath = socketPath + ".log"
        let logDescriptor = Darwin.open(logPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        process.standardError = logDescriptor >= 0
            ? FileHandle(fileDescriptor: logDescriptor, closeOnDealloc: true)
            : FileHandle.nullDevice
        try process.run()

        // `run()` only means fork/exec happened, not that the daemon has bound
        // its socket yet. Hold the lock until it's confirmed listening (or we
        // give up) — releasing it any earlier is exactly what lets a second,
        // concurrently-racing caller also conclude "nothing's listening yet"
        // and spawn a second daemon.
        let readinessDeadline = Date().addingTimeInterval(10)
        while Date() < readinessDeadline {
            if let connection = try? BridgeSocketConnection.connect(to: socketPath) {
                connection.close()
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

/// Which daemon executable file a daemon process runs: its resolved path plus the
/// file's identity on disk. Replacing the app bundle keeps the path and changes
/// the identity, which is how a caller tells a daemon left over from the previous
/// version from its own.
struct BridgeDaemonIdentity: Codable, Equatable {
    var path: String
    var device: Int
    var inode: Int
    var modified: Double
    var size: Int

    init?(executablePath: String) {
        guard let resolved = realpath(executablePath, nil) else { return nil }
        defer { free(resolved) }
        var info = stat()
        guard stat(resolved, &info) == 0 else { return nil }
        path = String(cString: resolved)
        device = Int(info.st_dev)
        inode = Int(info.st_ino)
        modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        size = Int(info.st_size)
    }

    /// The executable of the running process.
    static func currentProcess() -> BridgeDaemonIdentity? {
        var size = UInt32(MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return BridgeDaemonIdentity(executablePath: String(cString: buffer))
    }

    /// True when `other` names this same path but a different file: this one
    /// was replaced on disk after `other`'s process started.
    func isReplacement(of other: BridgeDaemonIdentity) -> Bool {
        path == other.path && self != other
    }
}
