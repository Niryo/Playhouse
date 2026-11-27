import Foundation

/// One WebSocket client connection (RFC 6455) to a `codex app-server --listen unix://` server.
/// Network.framework's WebSocket stack can't run over a Unix endpoint, so the framing is done
/// here over a plain `AF_UNIX` stream. Each text message is one JSON-RPC message.
package final class CodexSocketConnection: @unchecked Sendable {
    package enum ConnectionError: LocalizedError {
        case connect(String, Int32)
        case handshake(String)
        case closed

        package var errorDescription: String? {
            switch self {
            case .connect(let path, let code): "Couldn't connect to the Codex app-server at \(path) (\(String(cString: strerror(code))))."
            case .handshake(let detail): "The Codex app-server refused the connection: \(detail)"
            case .closed: "The connection to the Codex app-server closed."
            }
        }
    }

    package let path: String
    private let descriptor: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var open = true
    private var buffer = [UInt8]()

    /// Connects and completes the WebSocket handshake. Blocking; call off the main actor.
    package init(path: String) throws {
        self.path = path
        let socketDescriptor = POSIX.unixStreamSocket()
        guard socketDescriptor >= 0 else { throw ConnectionError.connect(path, errno) }
        POSIX.disableSIGPIPE(onSocket: socketDescriptor)
        _ = fcntl(socketDescriptor, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(socketDescriptor)
            throw ConnectionError.connect(path, ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                POSIX.connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            close(socketDescriptor)
            throw ConnectionError.connect(path, code)
        }
        descriptor = socketDescriptor
        do {
            try handshake()
        } catch {
            close(socketDescriptor)
            throw error
        }
    }

    deinit { shutdownConnection() }

    package var isOpen: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return open
    }

    private func handshake() throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        try writeAll(Array("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
        let terminator: [UInt8] = [13, 10, 13, 10]
        var headerEnd: Int?
        while headerEnd == nil {
            try readMore()
            headerEnd = buffer.indices.dropLast(3).first { Array(buffer[$0..<($0 + 4)]) == terminator }
            if buffer.count > 16_384 { throw ConnectionError.handshake("Oversized handshake response.") }
        }
        let header = String(decoding: buffer[..<headerEnd!], as: UTF8.self)
        buffer.removeFirst(headerEnd! + 4)
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first?.contains(" 101 ") == true else { throw ConnectionError.handshake(lines.first ?? "No status line.") }
        let expected = Data(Hashing.sha1(Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let accept = lines.dropFirst().first { $0.lowercased().hasPrefix("sec-websocket-accept:") }
            .map { $0.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces) }
        guard accept == expected else { throw ConnectionError.handshake("Unexpected Sec-WebSocket-Accept.") }
    }

    /// Delivers each message on a dedicated thread until the connection closes, then calls
    /// `onClose` once.
    package func start(onMessage: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        let thread = Thread { [self] in
            while let message = try? readMessage() {
                onMessage(message)
            }
            shutdownConnection()
            onClose()
        }
        thread.name = "playhouse.codex-socket"
        thread.start()
    }

    package func send(_ payload: Data) throws {
        try sendFrame(opcode: 0x1, payload: [UInt8](payload))
    }

    package func shutdownConnection() {
        stateLock.lock()
        let wasOpen = open
        open = false
        stateLock.unlock()
        guard wasOpen else { return }
        POSIX.shutdown(descriptor, Int32(SHUT_RDWR))
        close(descriptor)
    }

    private func sendFrame(opcode: UInt8, payload: [UInt8]) throws {
        guard isOpen else { throw ConnectionError.closed }
        var frame: [UInt8] = [0x80 | opcode]
        let count = payload.count
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else if count < 65_536 {
            frame += [0x80 | 126, UInt8(count >> 8), UInt8(count & 0xFF)]
        } else {
            frame.append(0x80 | 127)
            frame += (0..<8).reversed().map { UInt8((UInt64(count) >> (UInt64($0) * 8)) & 0xFF) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame += mask
        frame.reserveCapacity(frame.count + count)
        for (index, byte) in payload.enumerated() { frame.append(byte ^ mask[index & 3]) }
        writeLock.lock()
        defer { writeLock.unlock() }
        try writeAll(frame)
    }

    private func writeAll(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw ConnectionError.closed }
            offset += written
        }
    }

    private func readMore() throws {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ConnectionError.closed }
            buffer += chunk[0..<count]
            return
        }
    }

    private func take(_ count: Int) throws -> [UInt8] {
        while buffer.count < count { try readMore() }
        let bytes = Array(buffer[0..<count])
        buffer.removeFirst(count)
        return bytes
    }

    /// The next complete text or binary message, answering pings on the way.
    private func readMessage() throws -> Data {
        var message = [UInt8]()
        while true {
            let head = try take(2)
            let opcode = head[0] & 0x0F
            var length = Int(head[1] & 0x7F)
            if length == 126 {
                let bytes = try take(2)
                length = Int(bytes[0]) << 8 | Int(bytes[1])
            } else if length == 127 {
                length = try take(8).reduce(0) { $0 << 8 | Int($1) }
            }
            let mask = head[1] & 0x80 != 0 ? try take(4) : nil
            var payload = try take(length)
            if let mask { for index in payload.indices { payload[index] ^= mask[index & 3] } }
            switch opcode {
            case 0x8:
                try? sendFrame(opcode: 0x8, payload: Array(payload.prefix(2)))
                throw ConnectionError.closed
            case 0x9:
                try sendFrame(opcode: 0xA, payload: payload)
            case 0xA:
                break
            default:
                message += payload
                if head[0] & 0x80 != 0 { return Data(message) }
            }
        }
    }
}

/// A shared `codex app-server` that outlives the daemon that started it: it listens on a Unix
/// socket, and its manifest lets the next daemon of the same service reconnect to it.
package struct CodexServerManifest: Codable, Equatable {
    package struct Thread: Codable, Equatable {
        package var modelID: String
        package var cwd: String
        package var roots: [String]
        package var developerInstructions: String?
        package var mcpServers: String?

        package init(modelID: String, cwd: String, roots: [String], developerInstructions: String? = nil, mcpServers: String? = nil) {
            self.modelID = modelID
            self.cwd = cwd
            self.roots = roots
            self.developerInstructions = developerInstructions
            self.mcpServers = mcpServers
        }
    }

    package var version = 1
    package var serviceName: String
    package var keyHash: String
    /// The parts the key was built from, so a later daemon can open the same shared client.
    package var keyParts: [String]
    /// `spawning` until the server's identity is recorded, then `running`.
    package var state: String
    package var process: AgentProcessIdentity?
    package var createdAt: Date
    package var socketPath: String
    /// The executable with symlinks resolved: a Homebrew upgrade changes it, so it stands in for
    /// the server's version.
    package var resolvedExecutablePath: String
    package var flags: [String]
    package var codexHome: String?
    /// The threads this server has loaded, with what they were last opened with.
    package var threads: [String: Thread] = [:]

    package init(version: Int = 1, serviceName: String, keyHash: String, keyParts: [String], state: String, process: AgentProcessIdentity? = nil, createdAt: Date, socketPath: String, resolvedExecutablePath: String, flags: [String], codexHome: String? = nil, threads: [String: Thread] = [:]) {
        self.version = version
        self.serviceName = serviceName
        self.keyHash = keyHash
        self.keyParts = keyParts
        self.state = state
        self.process = process
        self.createdAt = createdAt
        self.socketPath = socketPath
        self.resolvedExecutablePath = resolvedExecutablePath
        self.flags = flags
        self.codexHome = codexHome
        self.threads = threads
    }
}

/// Where a shared server's files live, and the rules for finding, starting and retiring one.
package struct CodexSharedServer {
    package let runDirectory: URL
    package let keyHash: String
    package let serviceName: String
    package let keyParts: [String]

    /// One function builds the key from its parts, so dropping a part later (for example the
    /// goal-runtime flag, once the window and the CLI share one server) changes nothing else.
    package static func keyHash(parts: [String], serviceName: String) -> String {
        let digest = Hashing.sha256(Data((parts + [serviceName]).joined(separator: "\u{1}").utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    package static func runsDirectory(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("codex-runs", isDirectory: true)
    }

    package var manifestURL: URL { runDirectory.appendingPathComponent("\(keyHash).json") }
    package var logURL: URL { runDirectory.appendingPathComponent("\(keyHash).log") }
    package var lockPath: String { runDirectory.appendingPathComponent("\(keyHash).owner.lock").path }
    package var preferredSocketPath: String { runDirectory.appendingPathComponent("\(keyHash).sock").path }

    package func readManifest() -> CodexServerManifest? {
        AgentManifestFile.read(CodexServerManifest.self, from: manifestURL)
    }

    package func writeManifest(_ manifest: CodexServerManifest) throws {
        try AgentManifestFile.write(manifest, to: manifestURL)
    }

    /// Removes the server's files once its process is gone.
    package func removeFiles(socketPath: String?) {
        for url in [manifestURL, logURL] { try? FileManager.default.removeItem(at: url) }
        if let socketPath { unlink(socketPath) }
        unlink(preferredSocketPath)
    }

    /// Starts a server and records it. The manifest is written before the spawn, so a daemon
    /// killed in between leaves a `spawning` entry the orphan sweep can match.
    package func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        resolvedExecutablePath: String,
        flags: [String],
        codexHome: String?
    ) throws -> CodexServerManifest {
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(runDirectory.path, 0o700)
        let socketPath = AgentSocketPath.resolve(preferred: preferredSocketPath, fileName: "\(keyHash).sock")
        unlink(socketPath)
        var manifest = CodexServerManifest(
            serviceName: serviceName, keyHash: keyHash, keyParts: keyParts, state: "spawning", process: nil, createdAt: Date(),
            socketPath: socketPath, resolvedExecutablePath: resolvedExecutablePath, flags: flags, codexHome: codexHome
        )
        try writeManifest(manifest)
        let identity = try AgentRunHost.spawn(
            executable: executable,
            arguments: arguments + ["--listen", "unix://\(socketPath)"],
            environment: environment,
            workingDirectory: workingDirectory,
            stdin: .path("/dev/null", flags: O_RDONLY),
            stdout: .path(logURL.path, flags: O_WRONLY | O_CREAT | O_APPEND),
            stderr: .path(logURL.path, flags: O_WRONLY | O_CREAT | O_APPEND)
        )
        manifest.process = identity
        manifest.state = "running"
        try writeManifest(manifest)
        return manifest
    }

    /// Connects once the server listens, giving up when it exits or `timeout` passes.
    package static func connect(to manifest: CodexServerManifest, timeout: TimeInterval) async throws -> CodexSocketConnection {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = CodexSocketConnection.ConnectionError.closed
        while Date() < deadline {
            if let process = manifest.process, !process.isAlive { break }
            do {
                return try await Task.detached { try CodexSocketConnection(path: manifest.socketPath) }.value
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw lastError
    }

    /// Every server manifest `serviceName` left in `runsDirectory` (every service's, for nil).
    package static func manifests(in runsDirectory: URL, serviceName: String?) -> [(server: CodexSharedServer, manifest: CodexServerManifest)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }.compactMap { url in
            guard let manifest = AgentManifestFile.read(CodexServerManifest.self, from: url),
                  serviceName == nil || manifest.serviceName == serviceName else { return nil }
            return (CodexSharedServer(runDirectory: runsDirectory, keyHash: manifest.keyHash, serviceName: manifest.serviceName, keyParts: manifest.keyParts), manifest)
        }
    }

    package init(runDirectory: URL, keyHash: String, serviceName: String, keyParts: [String]) {
        self.runDirectory = runDirectory
        self.keyHash = keyHash
        self.serviceName = serviceName
        self.keyParts = keyParts
    }
}
