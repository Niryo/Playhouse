import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Network
import XCTest
import SQLite3
import Vision

struct RunningCLIProcess {
    let process: Process
    let stdout: Pipe
    let stderr: Pipe
}
final class GitConfigReadBarrier {
    private let configURL: URL
    private let backupURL: URL
    private let contents: Data
    private var writerDescriptor: Int32 = -1
    private var isReleased = false

    init(repositoryURL: URL) throws {
        configURL = repositoryURL.appendingPathComponent(".git/config")
        backupURL = configURL.deletingLastPathComponent()
            .appendingPathComponent("config.playhouse-test-\(UUID().uuidString)")
        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw NSError(domain: "PlayhouseUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected an owned regular Git config at \(configURL.path)"])
        }
        contents = try Data(contentsOf: configURL)
        try FileManager.default.moveItem(at: configURL, to: backupURL)
        guard Darwin.mkfifo(configURL.path, mode_t(0o600)) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            try? FileManager.default.moveItem(at: backupURL, to: configURL)
            throw error
        }
    }

    func waitForReader(timeout: TimeInterval = 15) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let descriptor = Darwin.open(configURL.path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 {
                writerDescriptor = descriptor
                return
            }
            guard errno == ENXIO else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            usleep(5_000)
        }
        throw NSError(domain: "PlayhouseUITests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Git did not open the owned config FIFO: \(configURL.path)"])
    }

    func release() throws {
        guard !isReleased else { return }
        if writerDescriptor < 0, isFIFO(at: configURL) {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                let descriptor = Darwin.open(configURL.path, O_WRONLY | O_NONBLOCK)
                if descriptor >= 0 {
                    writerDescriptor = descriptor
                    break
                }
                guard errno == ENXIO else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                usleep(5_000)
            }
        }
        if isFIFO(at: configURL) { try FileManager.default.removeItem(at: configURL) }
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.moveItem(at: backupURL, to: configURL)
        }
        guard writerDescriptor >= 0 else {
            isReleased = true
            return
        }
        defer {
            Darwin.close(writerDescriptor)
            writerDescriptor = -1
        }
        try contents.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(writerDescriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                offset += written
            }
        }
        isReleased = true
    }

    deinit { try? release() }

    private func isFIFO(at url: URL) -> Bool {
        var fileInfo = Darwin.stat()
        guard Darwin.lstat(url.path, &fileInfo) == 0 else { return false }
        return (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFIFO)
    }
}
final class GitHoldBarrier {
    static let directory = WorkspaceFixture.root.appendingPathComponent("git-hold", isDirectory: true)
    private let holdURL = GitHoldBarrier.directory.appendingPathComponent("hold")
    private let waitingURL = GitHoldBarrier.directory.appendingPathComponent("hold.waiting")
    private var isReleased = false

    init(repositoryURL: URL) throws {
        try? FileManager.default.removeItem(at: waitingURL)
        try repositoryURL.resolvingSymlinksInPath().path.write(to: holdURL, atomically: true, encoding: .utf8)
    }

    /// Returns once the wrapper has parked a call for the repository.
    func waitForHeldCall(timeout: TimeInterval = 15) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: waitingURL.path) { return }
            usleep(5_000)
        }
        throw NSError(domain: "PlayhouseUITests", code: 3, userInfo: [NSLocalizedDescriptionKey: "No Git call for the held repository reached \(GitHoldBarrier.directory.path)/git."])
    }

    func release() throws {
        guard !isReleased else { return }
        isReleased = true
        if FileManager.default.fileExists(atPath: holdURL.path) {
            try FileManager.default.removeItem(at: holdURL)
        }
        try? FileManager.default.removeItem(at: waitingURL)
    }

    deinit { try? release() }
}
final class TaskOperationLockBarrier {
    private var descriptor: Int32

    init(dataDirectory: URL, taskID: String) throws {
        let directory = dataDirectory.appendingPathComponent("task-operation-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("\(taskID).lock")
        descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    func release() throws {
        guard descriptor >= 0 else { return }
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { try? release() }
}
final class TaskStoreWriteLockBarrier {
    private var descriptor: Int32

    init(dataDirectory: URL) throws {
        let lockURL = dataDirectory.appendingPathComponent("store-write.lock")
        descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    func release() throws {
        guard descriptor >= 0 else { return }
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { try? release() }
}
final class ConversationTurnLockBarrier {
    private var descriptor: Int32

    /// Whether another process (the daemon or app running the task's turn) holds the task's
    /// conversation-turn reservation. A turn keeps it after the task already reads Review,
    /// while the PR mode's pull request is created. Never call this while the test itself
    /// holds a barrier for the same task: closing the probe's descriptor would drop that lock.
    static func isHeldByAnotherProcess(dataDirectory: URL, taskID: String) -> Bool {
        let lockURL = dataDirectory.appendingPathComponent("conversation-turn-locks", isDirectory: true)
            .appendingPathComponent("\(taskID).lock")
        let probe = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC)
        guard probe >= 0 else { return false }
        defer { Darwin.close(probe) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(probe, F_GETLK, &lock) == 0 else { return true }
        return lock.l_type != Int16(F_UNLCK)
    }

    init(dataDirectory: URL, taskID: String) throws {
        let directory = dataDirectory.appendingPathComponent("conversation-turn-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("\(taskID).lock")
        descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    func release() throws {
        guard descriptor >= 0 else { return }
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { try? release() }
}
final class RepositoryAllocationLockBarrier {
    private var descriptor: Int32

    init(dataDirectory: URL, repositoryURL: URL) throws {
        let directory = dataDirectory.appendingPathComponent("repository-allocation-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canonicalPath = repositoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        var hash: UInt64 = 14695981039346656037
        for byte in canonicalPath.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        let lockURL = directory.appendingPathComponent(String(format: "%016llx.lock", hash))
        descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    func release() throws {
        guard descriptor >= 0 else { return }
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { try? release() }
}
final class DrainingPipe: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private let finished = DispatchGroup()

    init() {
        finished.enter()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.finished.leave()
            } else {
                self.lock.lock(); self.buffer.append(data); self.lock.unlock()
            }
        }
    }

    func drainedText() -> String {
        _ = finished.wait(timeout: .now() + 10)
        lock.lock(); defer { lock.unlock() }
        return String(data: buffer, encoding: .utf8) ?? ""
    }
}
final class PluginFetchServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "plugin-fetch-server")
    let port: UInt16

    init() throws {
        listener = try Self.loopbackListener()
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.receive(connection, buffer: Data())
        }
        port = try Self.start(listener, queue: queue)
    }

    deinit { listener.cancel() }

    /// A loopback port nothing listens on: bound, read, then released.
    static func closedPort() throws -> UInt16 {
        let probe = try loopbackListener()
        let port = try start(probe, queue: DispatchQueue(label: "plugin-fetch-probe"))
        probe.cancel()
        return port
    }

    private static func loopbackListener() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        return try NWListener(using: parameters)
    }

    private static func start(_ listener: NWListener, queue: DispatchQueue) throws -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        if listener.newConnectionHandler == nil { listener.newConnectionHandler = { $0.cancel() } }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue, port != 0 else {
            throw NSError(domain: "PluginFetchServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "The fetch fixture server couldn't listen on 127.0.0.1."])
        }
        return port
    }

    /// Reads one request (headers, then Content-Length bytes of body) and answers it.
    private static func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let length = Int(headers["content-length"] ?? "") ?? 0
                let body = buffer[end.upperBound...]
                if body.count >= length {
                    let parts = (lines.first ?? "").split(separator: " ")
                    let method = parts.first.map(String.init) ?? ""
                    let path = parts.count > 1 ? String(parts[1]) : "/"
                    respond(connection, method: method, path: path, headers: headers, body: String(decoding: body.prefix(length), as: UTF8.self))
                    return
                }
            }
            if isComplete || error != nil { connection.cancel(); return }
            receive(connection, buffer: buffer)
        }
    }

    private static func respond(_ connection: NWConnection, method: String, path: String, headers: [String: String], body: String) {
        var status = 404
        var reason = "Not Found"
        var text = "unexpected"
        var contentType = "text/plain"
        var extra: [String] = []
        switch (method, path) {
        case ("GET", "/greeting"):
            (status, reason, text, contentType) = (200, "OK", #"{"message": "hello from the fixture"}"#, "application/json")
            extra.append("X-Fixture: playhouse")
        case ("POST", "/echo"):
            let echo: [String: Any] = ["method": method, "token": headers["x-token"] ?? NSNull(), "contentType": headers["content-type"] ?? NSNull(), "body": body]
            let json = (try? JSONSerialization.data(withJSONObject: echo)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            (status, reason, text, contentType) = (200, "OK", json, "application/json")
        case ("GET", "/missing"):
            text = "nothing here"
        case ("GET", "/redirect"):
            (status, reason, text) = (302, "Found", "")
            extra.append("Location: /greeting")
        default:
            break
        }
        let payload = Data(text.utf8)
        let head = (["HTTP/1.1 \(status) \(reason)", "Content-Type: \(contentType)", "Content-Length: \(payload.count)", "Connection: close"] + extra)
            .joined(separator: "\r\n") + "\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}
struct WorkspaceFixture {
    static let root = URL(fileURLWithPath: "/tmp/playhouse-ui-test-fixtures", isDirectory: true)
    static let ownerMarker = ".playhouse-bridge-fixture"
    static let ownerContents = "Playhouse bridge tests own this deterministic fixture (v1).\n"

    let parent: URL
    let primary: URL
    let secondary: URL
    let alternate: URL
    let alternateParent: URL
    let custom: URL
    let changes: URL
    let missing: URL
    let nested: URL
    let linkedOutside: URL
    let existingWorktree: URL
    let emptyGitRepository: URL

    static func load() throws -> WorkspaceFixture {
        let marker = root.appendingPathComponent(ownerMarker)
        guard let contents = try? String(contentsOf: marker, encoding: .utf8), contents == ownerContents else {
            throw NSError(domain: "PlayhouseUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The deterministic Git fixtures are missing or not owned by Playhouse. Run scripts/test-ui.sh first."
            ])
        }
        let parent = root.appendingPathComponent("suggested-parent", isDirectory: true)
        let locations: [String: URL] = [
            "parent": parent,
            "primary": parent.appendingPathComponent("primary", isDirectory: true),
            "secondary": parent.appendingPathComponent("group/secondary", isDirectory: true),
            "alternateParent": parent.appendingPathComponent("alternate-parent", isDirectory: true),
            "alternate": parent.appendingPathComponent("alternate-parent/alternate", isDirectory: true),
            "custom": parent.appendingPathComponent("custom-folder", isDirectory: true),
            "changes": parent.appendingPathComponent("changes", isDirectory: true),
            "emptyGitRepository": root.appendingPathComponent("empty-git-repo", isDirectory: true),
            "nested": parent.appendingPathComponent("primary/nested", isDirectory: true),
            "linkedOutside": parent.appendingPathComponent("linked-outside", isDirectory: true)
        ]
        for (name, url) in locations where name != "linkedOutside" {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NSError(domain: "PlayhouseUITests", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Missing \(name) fixture folder at \(url.path)."
                ])
            }
        }
        return WorkspaceFixture(
            parent: parent,
            primary: locations["primary"]!,
            secondary: locations["secondary"]!,
            alternate: locations["alternate"]!,
            alternateParent: locations["alternateParent"]!,
            custom: locations["custom"]!,
            changes: locations["changes"]!,
            missing: parent.appendingPathComponent("missing", isDirectory: true),
            nested: locations["nested"]!,
            linkedOutside: locations["linkedOutside"]!,
            existingWorktree: root.appendingPathComponent("existing-worktree", isDirectory: true),
            emptyGitRepository: locations["emptyGitRepository"]!
        )
    }

}
extension XCUIElement {
    /// Waits like `waitForExistence(timeout:)`, polling every 0.1 s. XCTest's own wait makes
    /// its first check about a second after it starts, even when the element is already there;
    /// almost every wait in this suite is satisfied on that first check, so the delay added up
    /// to roughly 40% of a full run. The activity keeps the "Waiting Ns for … to exist" step
    /// in the log for triage.
    func waitToExist(timeout: TimeInterval) -> Bool {
        XCTContext.runActivity(named: "Waiting \(timeout)s for \(self) to exist") { _ in
            let deadline = Date().addingTimeInterval(timeout)
            while !exists {
                guard Date() < deadline else { return false }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            return true
        }
    }
}
