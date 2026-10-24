import Darwin
import Foundation

/// StationAI's own record of a task's provider timeline.
///
/// Codex keeps its full thread history in its app-server, so StationAI stores
/// only which Codex turns belong to each Codex segment. Claude Code turns are
/// stored here in full (visible messages and activities), so a mixed-provider
/// transcript can be reopened in order without depending on another runtime's
/// private session files. Tasks that never left Codex have no transcript file.
struct ConversationTranscript: Codable, Equatable {
    struct Segment: Codable, Equatable, Identifiable {
        let id: String
        let provider: ConversationProvider
        let startedAt: Date
        /// Codex turns that ran while this segment was active, captured when
        /// the task switched away from Codex. Later Codex turns belong to the
        /// last Codex segment.
        var codexTurnIDs: [String] = []
        /// Whether the first prompt of this segment already carried the visible
        /// turns this provider had not seen.
        var handoffDelivered = false
    }

    struct Turn: Codable, Equatable, Identifiable {
        let id: String
        let segmentID: String
        var messages: [ConversationMessage] = []
        var activities: [ConversationActivity] = []
    }

    var version = 1
    var segments: [Segment] = []
    var turns: [Turn] = []

    var isEmpty: Bool { segments.isEmpty && turns.isEmpty }

    func turns(in segment: Segment) -> [Turn] {
        turns.filter { $0.segmentID == segment.id }
    }

    func segmentIndex(of segmentID: String) -> Int? {
        segments.firstIndex { $0.id == segmentID }
    }
}

/// Reads and atomically updates per-task transcripts beside the task store.
/// Writers in the app and the XPC service serialize on a per-task file lock.
struct ConversationTranscriptStore {
    let directory: URL

    func read(_ taskID: UUID) throws -> ConversationTranscript {
        let url = fileURL(taskID)
        guard FileManager.default.fileExists(atPath: url.path) else { return ConversationTranscript() }
        return try JSONDecoder().decode(ConversationTranscript.self, from: Data(contentsOf: url))
    }

    @discardableResult
    func mutate<T>(_ taskID: UUID, _ mutation: (inout ConversationTranscript) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = Darwin.chmod(directory.path, mode_t(0o700))
        let url = fileURL(taskID)
        let descriptor = Darwin.open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = Darwin.close(descriptor) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLKW, &lock) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { lock.l_type = Int16(F_UNLCK); _ = Darwin.fcntl(descriptor, F_SETLK, &lock) }
        var transcript = try read(taskID)
        let original = transcript
        let result = try mutation(&transcript)
        if transcript != original {
            try JSONEncoder().encode(transcript).write(to: url, options: .atomic)
            _ = Darwin.chmod(url.path, mode_t(0o600))
        }
        return result
    }

    func remove(_ taskID: UUID) {
        let url = fileURL(taskID)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("lock"))
    }

    private func fileURL(_ taskID: UUID) -> URL {
        directory.appendingPathComponent("\(taskID.uuidString).json")
    }
}

/// Builds the labeled context a provider receives on its first prompt after a
/// switch. Only visible user and assistant text crosses providers; native tool
/// history and hidden reasoning stay with the runtime that produced them.
enum ConversationHandoff {
    static let openTag = "<stationai-handoff-context>"
    static let closeTag = "</stationai-handoff-context>"
    private static let characterLimit = 40_000

    static func context(for provider: ConversationProvider, messages: [ConversationMessage]) -> String? {
        let lines = messages.compactMap { message -> String? in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, message.phase != "commentary" else { return nil }
            let speaker = message.role == .user ? "User" : (message.provider ?? .codex).displayName
            return "\(speaker): \(text)"
        }
        guard !lines.isEmpty else { return nil }
        var transcript = lines.joined(separator: "\n\n")
        if transcript.count > characterLimit {
            transcript = "[Earlier turns omitted]\n\n" + String(transcript.suffix(characterLimit))
        }
        return """
        \(openTag)
        This StationAI task continued with another assistant while you were not active. These are the visible turns you have not seen, provided as context. Tool history and hidden reasoning are not included; inspect the workspace for the current state of files.

        \(transcript)
        \(closeTag)
        """
    }

    static func prompt(_ text: String, context: String?) -> String {
        guard let context else { return text }
        return text.isEmpty ? context : "\(context)\n\n\(text)"
    }

    /// Removes a handoff block that a native transcript stored with the prompt.
    static func stripContext(from text: String) -> String {
        guard text.hasPrefix(openTag), let close = text.range(of: closeTag) else { return text }
        return String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
