import Foundation

/// What a task's OpenCode sessions sent their model, kept where the token map reads it.
///
/// OpenCode keeps a session's messages in its own database, and its server lists them: each
/// assistant message is one model request, with the tokens that request was billed. The
/// process that runs an OpenCode turn writes the messages of the turn's session, and of the
/// subagent sessions it started, to `opencode-request-logs/` beside Playhouse's store, one
/// message per line, oldest first. The token map reads those files like the other providers'
/// session files (`OpenCodeMessageLogParser`), in whichever process opens it, without asking
/// OpenCode again; a file stays readable after OpenCode or its server is gone.
enum OpenCodeRequestLog {
    nonisolated static func directory(storeDirectory: URL) -> URL {
        storeDirectory.appendingPathComponent("opencode-request-logs", isDirectory: true)
    }

    /// The main session's file.
    nonisolated static func file(sessionID: String, in directory: URL) -> URL {
        directory.appendingPathComponent(fileName(sessionID) + ".jsonl")
    }

    /// The files of the subagent sessions `sessionID` started, by their session IDs.
    nonisolated static func subagentFiles(of sessionID: String, in directory: URL) -> [(sessionID: String, file: URL)] {
        let prefix = fileName(sessionID) + ".subagent."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".jsonl") }.sorted().map { name in
            (String(name.dropFirst(prefix.count).dropLast(".jsonl".count)), directory.appendingPathComponent(name))
        }
    }

    nonisolated static func subagentFile(_ childID: String, of sessionID: String, in directory: URL) -> URL {
        directory.appendingPathComponent(fileName(sessionID) + ".subagent." + fileName(childID) + ".jsonl")
    }

    /// OpenCode's IDs (`ses_…`) are already safe file names; anything else is replaced.
    private nonisolated static func fileName(_ id: String) -> String {
        String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" ? Character($0) : "_" })
    }

    /// Removes a deleted conversation's session files.
    nonisolated static func remove(sessionID: String, in directory: URL) {
        for file in [file(sessionID: sessionID, in: directory)] + subagentFiles(of: sessionID, in: directory).map(\.file) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Writing

    /// Each session's writes run one after another, so an earlier read never overwrites a later one.
    @MainActor private static var writes: [String: Task<Void, Never>] = [:]
    /// Sessions with an update queued that hasn't started reading yet.
    @MainActor private static var queued: Set<String> = []

    /// Writes the log soon, without waiting: an update asked for while one is queued is that one.
    @MainActor static func update(sessionID: String, connection: OpenCodeServerConnection, directory: URL) {
        guard queued.insert(sessionID).inserted else { return }
        Task { @MainActor in
            await write(sessionID: sessionID, connection: connection, directory: directory) { queued.remove(sessionID) }
        }
    }

    /// Reads the session's and its subagents' messages from OpenCode and writes each file whose
    /// messages changed; an unchanged file is left alone, so its parse is reused. A session
    /// OpenCode can't list keeps the file it had.
    @MainActor static func write(
        sessionID: String, connection: OpenCodeServerConnection, directory: URL, onStart: @escaping @MainActor () -> Void = {}
    ) async {
        let previous = writes[sessionID]
        let current = Task { @MainActor in
            await previous?.value
            onStart()
            await read(sessionID: sessionID, connection: connection, directory: directory)
        }
        writes[sessionID] = current
        await current.value
        if writes[sessionID] == current { writes.removeValue(forKey: sessionID) }
    }

    @MainActor private static func read(sessionID: String, connection: OpenCodeServerConnection, directory: URL) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try store(try await connection.messages(sessionID), at: file(sessionID: sessionID, in: directory))
            let children = (try await connection.request("GET", "api/session", query: ["parentID": sessionID, "limit": "200"]) as? [String: Any])?["data"]
            for child in children as? [[String: Any]] ?? [] {
                guard let childID = child["id"] as? String, (child["parentID"] as? String ?? sessionID) == sessionID else { continue }
                try store(try await connection.messages(childID), at: subagentFile(childID, of: sessionID, in: directory))
            }
        } catch {
            var fields = PlayhouseDiagnostics.errorFields(error)
            fields["sessionID"] = sessionID
            PlayhouseDiagnostics.record("opencode.request_log.failed", fields: fields)
        }
    }

    private static func store(_ messages: [[String: Any]], at file: URL) throws {
        var data = Data()
        for message in messages {
            data.append(try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes]))
            data.append(UInt8(ascii: "\n"))
        }
        guard (try? Data(contentsOf: file)) != data else { return }
        try data.write(to: file, options: .atomic)
    }
}
