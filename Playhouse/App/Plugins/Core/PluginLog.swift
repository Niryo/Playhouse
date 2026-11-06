import Foundation

struct PluginLogEntry: Codable, Equatable {
    enum Level: String, Codable {
        case log, info, warn, error
        /// An uncaught JS exception or a failed action.
        case exception
        /// An `api` call and its outcome.
        case api
        /// A call that only exists inside the app, logged instead of run by the dev runner.
        case appOnly = "app-only"
        /// Load, reload and hang notices from the host itself.
        case lifecycle
    }

    var date: Date
    var level: Level
    var message: String

    var line: String { "[\(level.rawValue)] \(message)" }
}

/// A bounded, thread-safe log for one plugin session.
final class PluginLog {
    private let lock = NSLock()
    private var storage: [PluginLogEntry] = []
    private let capacity: Int

    init(capacity: Int = 1_000) { self.capacity = capacity }

    func append(_ level: PluginLogEntry.Level, _ message: String) {
        lock.lock()
        storage.append(PluginLogEntry(date: Date(), level: level, message: message))
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
        lock.unlock()
    }

    var entries: [PluginLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
