import Foundation
#if canImport(OSLog)
import OSLog
#endif

@MainActor
package enum PlayhouseDiagnostics {
    private static var directoryOverride: URL?
    private static var ingressPendingBytes = 0
    private static var ingressDroppedEvents = 0
    nonisolated private static let writeLock = NSLock()
    nonisolated(unsafe) private static var logDescriptor: Int32 = -1
    nonisolated(unsafe) private static var lockDescriptor: Int32 = -1
    nonisolated(unsafe) private static var openedLockPath: String?
    nonisolated(unsafe) private static var openedLogPath: String?
    nonisolated(unsafe) private static var flushScheduled = false
    /// Buffered records keyed by where each was routed when recorded. One
    /// process can serve requests for different stores (the bridge daemon), so
    /// a flush must not move one request's records into another's log.
    nonisolated(unsafe) private static var bufferedEvents: [Destination: Data] = [:]
    nonisolated(unsafe) private static var pendingWriterBytes = 0
    nonisolated(unsafe) private static var droppedBufferedEvents = 0
    nonisolated(unsafe) private static var failedWriteCount = 0
    nonisolated(unsafe) private static var lastWriteFailure = ""
    nonisolated private static let totalLogLimit = 10 * 1024 * 1024
    nonisolated private static let perFileLimit = totalLogLimit / 2
    nonisolated private static let eventLimit = 512 * 1024
    nonisolated private static let batchLimit = 128 * 1024
    nonisolated private static let pendingWriterLimit = 2 * 1024 * 1024
    #if canImport(OSLog)
    nonisolated private static let logger = Logger(subsystem: "com.playhouse.app", category: "diagnostics")
    #endif

    /// Reports a failure of the diagnostics log itself: to the unified log, keeping `detail`
    /// private, or to standard error where there is no unified log.
    nonisolated private static func logFailure(_ message: String, detail: String) {
        #if canImport(OSLog)
        logger.error("\(message, privacy: .public)\(detail, privacy: .private)")
        #else
        FileHandle.standardError.write(Data((message + detail + "\n").utf8))
        #endif
    }
    nonisolated private static let writerQueue = DispatchQueue(label: "com.playhouse.diagnostics.writer", qos: .utility)

    package static func useDataDirectory(_ path: String?) {
        let url = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let scope = PlayhouseRequestContext.diagnosticsScope else {
            directoryOverride = url
            return
        }
        scope.directoryOverride = url
        if scope.awaitingDirectory { releaseHeldRecords(of: scope) }
    }

    /// The store directory diagnostics route to: this request's own selection
    /// inside a bridge request, otherwise the process-wide one.
    package static var currentDirectoryOverride: URL? {
        if let scope = PlayhouseRequestContext.diagnosticsScope { return scope.directoryOverride }
        return directoryOverride
    }

    private enum Destination: Hashable {
        case file(URL)
        case awaitingDirectory(UUID)
    }

    private static var logDestination: Destination {
        if let scope = PlayhouseRequestContext.diagnosticsScope, scope.awaitingDirectory {
            return .awaitingDirectory(scope.id)
        }
        return .file(logURL)
    }

    /// Sends the records a request made before choosing its store directory
    /// to that request's log; later records go there directly.
    private static func releaseHeldRecords(of scope: PlayhouseDiagnosticsScope) {
        scope.awaitingDirectory = false
        let target = logURL
        let held = Destination.awaitingDirectory(scope.id)
        writerQueue.async {
            if let records = bufferedEvents.removeValue(forKey: held) {
                bufferedEvents[.file(target), default: Data()].append(records)
            }
        }
    }

    package static var logURL: URL {
        let directory: URL
        if let directoryOverride = currentDirectoryOverride {
            directory = directoryOverride
        } else if let dataDirectory = PlayhouseProcessEnvironment.current["PLAYHOUSE_DATA_DIRECTORY"] {
            directory = URL(fileURLWithPath: dataDirectory, isDirectory: true)
        } else if PlayhouseAppIdentity.worktreeKey != nil,
                  let worktreeDirectory = try? PlayhouseAppIdentity.defaultDataDirectory() {
            directory = worktreeDirectory
        } else if let logsDirectory = try? FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            directory = logsDirectory.appendingPathComponent("Logs/Playhouse", isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("Playhouse", isDirectory: true)
        }
        return directory.appendingPathComponent("Diagnostics.jsonl")
    }

    package static var storeURL: URL {
        let directory: URL
        if let directoryOverride = currentDirectoryOverride {
            directory = directoryOverride
        } else if let dataDirectory = PlayhouseProcessEnvironment.current["PLAYHOUSE_DATA_DIRECTORY"] {
            directory = URL(fileURLWithPath: dataDirectory, isDirectory: true)
        } else if let supportDirectory = try? PlayhouseAppIdentity.defaultDataDirectory() {
            directory = supportDirectory
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("Playhouse", isDirectory: true)
        }
        return directory.appendingPathComponent(PlayhouseStore.storeFileName)
    }

    package static func storeContextFields(for storeURL: URL?) -> [String: String] {
        guard let storeURL else { return ["storePathAvailable": "false"] }

        let fileManager = FileManager.default
        let directoryURL = storeURL.deletingLastPathComponent()
        var fields = [
            "storePathAvailable": "true",
            "storePath": storeURL.standardizedFileURL.path,
            "storeDirectoryExists": String(fileManager.fileExists(atPath: directoryURL.path)),
            "storeDirectoryReadable": String(fileManager.isReadableFile(atPath: directoryURL.path)),
            "storeDirectoryWritable": String(fileManager.isWritableFile(atPath: directoryURL.path))
        ]
        appendFileSnapshot(storeURL, prefix: "storeFile", to: &fields)
        appendFileSnapshot(
            URL(fileURLWithPath: storeURL.path + "-wal"),
            prefix: "storeWAL",
            to: &fields
        )
        appendFileSnapshot(
            URL(fileURLWithPath: storeURL.path + "-shm"),
            prefix: "storeSHM",
            to: &fields
        )
        return fields
    }

    private static func appendFileSnapshot(_ url: URL, prefix: String, to fields: inout [String: String]) {
        let fileManager = FileManager.default
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        fields["\(prefix)Exists"] = String(attributes != nil)
        fields["\(prefix)Readable"] = String(fileManager.isReadableFile(atPath: url.path))
        fields["\(prefix)Writable"] = String(fileManager.isWritableFile(atPath: url.path))
        if let size = attributes?[.size] as? NSNumber {
            fields["\(prefix)SizeBytes"] = size.stringValue
        }
        if let permissions = attributes?[.posixPermissions] as? NSNumber {
            fields["\(prefix)Permissions"] = String(format: "%04o", permissions.intValue)
        }
        if let modified = attributes?[.modificationDate] as? Date {
            fields["\(prefix)ModifiedAt"] = ISO8601DateFormatter().string(from: modified)
        }
    }

    package static func jsonString<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return "<encoding-failed>"
        }
        let safeObject = sanitizeImagePayloads(object)
        guard let safeData = try? JSONSerialization.data(withJSONObject: safeObject, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "<encoding-failed>"
        }
        return String(data: safeData, encoding: .utf8) ?? "<encoding-failed>"
    }

    package nonisolated static func jsonStringOffMain<T: Encodable>(_ value: T) async -> String {
        let transfer = DiagnosticValueTransfer(value)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: jsonStringForDiagnostic(transfer.value))
            }
        }
    }

    nonisolated private static func jsonStringForDiagnostic<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return "<encoding-failed>"
        }
        let safeObject = sanitizeImagePayloads(object)
        guard let safeData = try? JSONSerialization.data(withJSONObject: safeObject, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "<encoding-failed>"
        }
        return String(data: safeData, encoding: .utf8) ?? "<encoding-failed>"
    }

    package nonisolated static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return String(describing: value)
        }
        let safeObject = sanitizeImagePayloads(object)
        guard let safeData = try? JSONSerialization.data(withJSONObject: safeObject, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "<encoding-failed>"
        }
        return String(data: safeData, encoding: .utf8) ?? "<encoding-failed>"
    }

    nonisolated private static func sanitizeImagePayloads(_ value: Any) -> Any {
        if let string = value as? String, string.hasPrefix("data:image/") {
            let mime = string.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "unknown"
            return ["mime": mime, "encodedCharacterCount": string.count]
        }
        if let values = value as? [Any] {
            return values.map(sanitizeImagePayloads)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(sanitizeImagePayloads)
        }
        return value
    }

    package static func endBatch() async {
        if let scope = PlayhouseRequestContext.diagnosticsScope, scope.awaitingDirectory {
            releaseHeldRecords(of: scope)
        }
        let ingressDrops = ingressDroppedEvents
        ingressDroppedEvents = 0
        let url = logURL
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async {
                droppedBufferedEvents += ingressDrops
                flushBufferedEvents(at: url)
                continuation.resume()
            }
        }
    }

    package static func recordAndFlush(_ event: String, fields: [String: String] = [:]) {
        record(event, fields: fields)
        let url = logURL
        writerQueue.sync {
            flushBufferedEvents(at: url)
        }
    }

    package static func record(_ event: String, fields: [String: String] = [:]) {
        var entry = fields
        entry["timestamp"] = ISO8601DateFormatter().string(from: Date())
        entry["event"] = event
        entry["process"] = ProcessInfo.processInfo.processName
        entry["processID"] = String(ProcessInfo.processInfo.processIdentifier)
        enqueue(entry, structuredFields: [:])
    }

    package static func record(_ event: String, fields: [String: String] = [:], structuredFields: [String: Any]) {
        var entry = fields
        entry["timestamp"] = ISO8601DateFormatter().string(from: Date())
        entry["event"] = event
        entry["process"] = ProcessInfo.processInfo.processName
        entry["processID"] = String(ProcessInfo.processInfo.processIdentifier)
        enqueue(entry, structuredFields: structuredFields)
    }

    private static func enqueue(_ originalEntry: [String: String], structuredFields originalStructuredFields: [String: Any]) {
        var entry = originalEntry
        var structuredFields = originalStructuredFields
        var estimatedBytes = estimateRetainedBytes(entry) + estimateRetainedBytes(structuredFields)
        if estimatedBytes > pendingWriterLimit {
            entry = [
                "timestamp": entry["timestamp"] ?? ISO8601DateFormatter().string(from: Date()),
                "event": entry["event"] ?? "diagnostics.event",
                "process": ProcessInfo.processInfo.processName,
                "processID": String(ProcessInfo.processInfo.processIdentifier),
                "recording": "omitted_event_larger_than_writer_queue_limit",
                "originalByteCount": String(estimatedBytes)
            ]
            structuredFields = [:]
            estimatedBytes = entry.reduce(into: 0) { total, pair in
                total += pair.key.utf8.count + pair.value.utf8.count + 8
            }
        }
        guard ingressPendingBytes + estimatedBytes <= pendingWriterLimit else {
            ingressDroppedEvents += 1
            return
        }
        ingressPendingBytes += estimatedBytes
        let ingressDrops = ingressDroppedEvents
        ingressDroppedEvents = 0
        let destination = logDestination
        let transfer = DiagnosticValueTransfer(structuredFields)
        writerQueue.async {
            droppedBufferedEvents += ingressDrops
            var encodedEntry = entry
            for (key, value) in transfer.value {
                encodedEntry[key] = jsonString(value)
            }
            appendSerializedEvent(encodedEntry, at: destination)
            Task { @MainActor in
                ingressPendingBytes = max(0, ingressPendingBytes - estimatedBytes)
            }
        }
    }

    nonisolated private static func estimateRetainedBytes(_ value: Any, limit: Int = pendingWriterLimit) -> Int {
        let overLimit = limit + 1
        if let string = value as? String { return min(string.utf8.count, overLimit) }
        if let dictionary = value as? [String: String] {
            var total = 0
            for (key, value) in dictionary {
                total += key.utf8.count + min(value.utf8.count, overLimit) + 8
                if total > limit { return overLimit }
            }
            return total
        }
        if let dictionary = value as? [String: Any] {
            var total = 0
            for (key, nestedValue) in dictionary {
                total += key.utf8.count + 8
                if total > limit { return overLimit }
                total += estimateRetainedBytes(nestedValue, limit: limit - total)
                if total > limit { return overLimit }
            }
            return total
        }
        if let values = value as? [Any] {
            var total = 0
            for nestedValue in values {
                total += estimateRetainedBytes(nestedValue, limit: limit - total) + 4
                if total > limit { return overLimit }
            }
            return total
        }
        if value is NSNull { return 4 }
        return min(16, overLimit)
    }

    nonisolated private static func appendSerializedEvent(_ originalEntry: [String: String], at url: Destination) {
        var entry = originalEntry
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        if data.count + 1 > eventLimit {
            guard data.count <= perFileLimit else {
                entry = [
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "event": originalEntry["event"] ?? "diagnostics.event",
                    "process": ProcessInfo.processInfo.processName,
                    "processID": String(ProcessInfo.processInfo.processIdentifier),
                    "recording": "omitted_event_larger_than_per_file_limit",
                    "originalByteCount": String(data.count + 1)
                ]
                guard let compactData = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
                data = compactData
                data.append(0x0A)
                buffer(data, at: url)
                return
            }
            let payload = data.base64EncodedString()
            let payloadChunkSize = eventLimit / 2
            let chunks = stride(from: 0, to: payload.count, by: payloadChunkSize).map { offset in
                let start = payload.index(payload.startIndex, offsetBy: offset)
                let end = payload.index(start, offsetBy: min(payloadChunkSize, payload.distance(from: start, to: payload.endIndex)))
                return String(payload[start..<end])
            }
            for (index, chunk) in chunks.enumerated() {
                let chunkEntry: [String: String] = [
                    "timestamp": entry["timestamp"] ?? ISO8601DateFormatter().string(from: Date()),
                    "event": "session.payload.chunk",
                    "payloadEvent": originalEntry["event"] ?? "diagnostics.event",
                    "payloadEncoding": "base64-json",
                    "chunkIndex": String(index),
                    "chunkCount": String(chunks.count),
                    "payload": chunk,
                    "process": ProcessInfo.processInfo.processName,
                    "processID": String(ProcessInfo.processInfo.processIdentifier)
                ]
                guard var chunkData = try? JSONSerialization.data(withJSONObject: chunkEntry, options: [.sortedKeys]) else { continue }
                chunkData.append(0x0A)
                buffer(chunkData, at: url)
            }
            return
        }
        data.append(0x0A)
        buffer(data, at: url)
    }

    nonisolated private static func buffer(_ data: Data, at destination: Destination) {
        bufferedEvents[destination, default: Data()].append(data)
        if bufferedEvents.values.reduce(0, { $0 + $1.count }) >= batchLimit {
            flushBufferedEvents()
        } else if !flushScheduled {
            flushScheduled = true
            writerQueue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                flushScheduled = false
                flushBufferedEvents()
            }
        }
    }

    /// Writes every record routed to a log so far to that log; records still
    /// waiting for their request's store directory stay buffered. `url` only
    /// receives a pending loss report when nothing else is written.
    nonisolated private static func flushBufferedEvents(at url: URL? = nil) {
        var files: [(URL, Data)] = []
        for (destination, data) in bufferedEvents {
            if case .file(let fileURL) = destination { files.append((fileURL, data)) }
        }
        for (fileURL, _) in files { bufferedEvents.removeValue(forKey: .file(fileURL)) }
        if files.isEmpty {
            guard droppedBufferedEvents > 0 || failedWriteCount > 0 else { return }
            write(Data(), reportingLossTo: url ?? URL(fileURLWithPath: "/"))
            return
        }
        for (targetURL, data) in files {
            write(data, reportingLossTo: targetURL)
        }
    }

    nonisolated private static func write(_ events: Data, reportingLossTo targetURL: URL) {
        var data = events
        do {
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: targetURL.deletingLastPathComponent().path
            )
        } catch {
            droppedBufferedEvents += data.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
            logFailure("Playhouse couldn't create diagnostics directory: ", detail: error.localizedDescription)
            return
        }
        let lossLockPath = targetURL.path + ".loss.lock"
        let lossLockDescriptor = open(lossLockPath, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
        guard lossLockDescriptor >= 0 else {
            droppedBufferedEvents += data.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
            logFailure("Playhouse couldn't open diagnostics loss-state lock: ", detail: String(cString: strerror(errno)))
            return
        }
        _ = fchmod(lossLockDescriptor, S_IRUSR | S_IWUSR)
        guard flock(lossLockDescriptor, LOCK_EX) == 0 else {
            let lockError = String(cString: strerror(errno))
            close(lossLockDescriptor)
            droppedBufferedEvents += data.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
            logFailure("Playhouse couldn't lock diagnostics loss state: ", detail: lockError)
            return
        }
        defer {
            _ = flock(lossLockDescriptor, LOCK_UN)
            close(lossLockDescriptor)
        }
        if !data.isEmpty && pendingWriterBytes + data.count > pendingWriterLimit {
            droppedBufferedEvents += data.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
            return
        }
        let persistedLoss = readPendingLoss(at: targetURL)
        let reportedDrops = (persistedLoss?.droppedEventCount ?? 0) + droppedBufferedEvents
        let reportedFailures = (persistedLoss?.failedWriteCount ?? 0) + failedWriteCount
        let reportedError = lastWriteFailure
            .isEmpty ? (persistedLoss?.lastWriteError ?? "") : lastWriteFailure
        let reportsLoss = reportedDrops > 0 || reportedFailures > 0
        var includedLossMarker = false
        if reportsLoss,
           let marker = try? JSONSerialization.data(withJSONObject: [
               "timestamp": ISO8601DateFormatter().string(from: Date()),
               "event": "diagnostics.writer.loss",
                "droppedEventCount": String(reportedDrops),
               "failedWriteCount": String(reportedFailures),
               "lastWriteError": reportedError
           ], options: [.sortedKeys]) {
            var markerData = marker
            markerData.append(0x0A)
            if pendingWriterBytes + data.count + markerData.count <= pendingWriterLimit {
                data.insert(contentsOf: markerData, at: 0)
                includedLossMarker = true
            }
        }
        pendingWriterBytes += data.count
        if let error = write(data, at: targetURL) {
            let saved = persistPendingLoss(
                droppedEventCount: reportedDrops,
                failedWriteCount: reportedFailures + 1,
                lastWriteError: error,
                at: targetURL
            )
            if saved {
                droppedBufferedEvents = 0
                failedWriteCount = 0
                lastWriteFailure = ""
            } else {
                failedWriteCount += 1
                lastWriteFailure = error
            }
        } else if reportsLoss && includedLossMarker {
            droppedBufferedEvents = 0
            failedWriteCount = 0
            lastWriteFailure = ""
            try? FileManager.default.removeItem(at: pendingLossURL(for: targetURL))
        }
        pendingWriterBytes = max(0, pendingWriterBytes - data.count)
    }

    private struct PendingLoss: Decodable {
        let droppedEventCount: Int
        let failedWriteCount: Int
        let lastWriteError: String
    }

    nonisolated private static func pendingLossURL(for url: URL) -> URL {
        url.appendingPathExtension("loss")
    }

    nonisolated private static func readPendingLoss(at url: URL) -> PendingLoss? {
        guard let data = try? Data(contentsOf: pendingLossURL(for: url)) else { return nil }
        return try? JSONDecoder().decode(PendingLoss.self, from: data)
    }

    nonisolated private static func persistPendingLoss(
        droppedEventCount: Int,
        failedWriteCount: Int,
        lastWriteError: String,
        at url: URL
    ) -> Bool {
        let state: [String: Any] = [
            "droppedEventCount": droppedEventCount,
            "failedWriteCount": failedWriteCount,
            "lastWriteError": lastWriteError
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return false }
        let stateURL = pendingLossURL(for: url)
        do {
            try data.write(to: stateURL, options: .atomic)
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            } catch {
                logFailure("Playhouse couldn't secure diagnostics loss state: ", detail: error.localizedDescription)
            }
            return true
        } catch {
            logFailure("Playhouse couldn't persist diagnostics loss state: ", detail: error.localizedDescription)
            return false
        }
    }

    nonisolated private static func write(_ data: Data, at url: URL) -> String? {
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.deletingLastPathComponent().path
            )
            let lockPath = url.path + ".lock"
            if openedLockPath != lockPath {
                if lockDescriptor >= 0 { close(lockDescriptor) }
                lockDescriptor = -1
                openedLockPath = lockPath
            }
            if lockDescriptor < 0 {
                lockDescriptor = open(lockPath, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
                guard lockDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            guard flock(lockDescriptor, LOCK_EX) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { _ = flock(lockDescriptor, LOCK_UN) }
            try rotateLogIfNeeded(for: data.count, at: url)
            var descriptorInfo = stat()
            var pathInfo = stat()
            let descriptorExists = logDescriptor >= 0 && fstat(logDescriptor, &descriptorInfo) == 0
            let pathExists = lstat(url.path, &pathInfo) == 0
            let descriptorMatchesPath = descriptorExists && pathExists
                && descriptorInfo.st_dev == pathInfo.st_dev
                && descriptorInfo.st_ino == pathInfo.st_ino
            if openedLogPath != url.path || !descriptorMatchesPath {
                if logDescriptor >= 0 { close(logDescriptor) }
                logDescriptor = -1
                openedLogPath = url.path
            }
            if logDescriptor < 0 {
                logDescriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
                guard logDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            var fileInfo = stat()
            guard fstat(logDescriptor, &fileInfo) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let originalSize = fileInfo.st_size
            var writeFailureErrno = EIO
            let writeResult = data.withUnsafeBytes { buffer -> Bool in
                guard let baseAddress = buffer.baseAddress else { return data.isEmpty }
                var offset = 0
                while offset < buffer.count {
                    let written = POSIX.write(logDescriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                    guard written > 0 else {
                        writeFailureErrno = errno
                        return false
                    }
                    offset += written
                }
                return true
            }
            guard writeResult else {
                _ = ftruncate(logDescriptor, originalSize)
                close(logDescriptor)
                logDescriptor = -1
                throw POSIXError(POSIXErrorCode(rawValue: writeFailureErrno) ?? .EIO)
            }
            return nil
        } catch {
            logFailure("Playhouse couldn't write diagnostics: ", detail: error.localizedDescription)
            return error.localizedDescription
        }
    }

    nonisolated private static func rotateLogIfNeeded(for incomingBytes: Int, at url: URL) throws {
        let previousURL = url.appendingPathExtension("1")
        let currentSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
        let previousSize = ((try? FileManager.default.attributesOfItem(atPath: previousURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        if previousSize > perFileLimit || currentSize + previousSize + incomingBytes > totalLogLimit {
            try? FileManager.default.removeItem(at: previousURL)
        }
        guard currentSize + incomingBytes > perFileLimit else { return }

        if logDescriptor >= 0 {
            close(logDescriptor)
            logDescriptor = -1
        }
        try? FileManager.default.removeItem(at: previousURL)
        if currentSize > 0 {
            try FileManager.default.moveItem(at: url, to: previousURL)
        }
        openedLogPath = nil

        // The two files are each bounded to half the total allowance.
        // This also trims an older generation immediately during rotation.
        let rotatedSize = ((try? FileManager.default.attributesOfItem(atPath: previousURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        if rotatedSize > perFileLimit { try FileManager.default.removeItem(at: previousURL) }
    }

    package static func errorFields(_ error: Error, includeUserInfoDetails: Bool = false) -> [String: String] {
        var fields: [String: String] = [:]
        fields["errorDescription"] = error.localizedDescription
        var underlying: NSError? = error as NSError
        var depth = 0
        while let current = underlying, depth < 5 {
            let prefix = "error\(depth)"
            fields["\(prefix)Domain"] = current.domain
            fields["\(prefix)Code"] = String(current.code)
            fields["\(prefix)Description"] = String(current.localizedDescription.prefix(4_096))
            let userInfoKeys = current.userInfo.keys.map(String.init(describing:)).sorted()
            fields["\(prefix)UserInfoKeys"] = userInfoKeys.joined(separator: ",")
            fields["\(prefix)UserInfoKeyCount"] = String(userInfoKeys.count)
            if let reason = current.localizedFailureReason { fields["\(prefix)Reason"] = reason }
            if includeUserInfoDetails {
                let diagnosticUserInfo = current.userInfo
                    .filter { $0.key != NSUnderlyingErrorKey }
                    .reduce(into: [String: Any]()) { result, item in
                        result[item.key] = diagnosticUserInfoValue(item.value)
                    }
                if let data = try? JSONSerialization.data(withJSONObject: diagnosticUserInfo, options: [.sortedKeys]),
                   let summary = String(data: data, encoding: .utf8) {
                    fields["\(prefix)UserInfo"] = String(summary.prefix(8_192))
                    fields["\(prefix)UserInfoTruncated"] = String(summary.utf8.count > 8_192)
                }
                if let debugDescription = current.userInfo["NSDebugDescription"] as? String {
                    fields["\(prefix)DebugDescription"] = String(debugDescription.prefix(4_096))
                }
                if let filePath = current.userInfo[NSFilePathErrorKey] as? String {
                    fields["\(prefix)FilePath"] = String(filePath.prefix(4_096))
                }
                if let recoverySuggestion = current.localizedRecoverySuggestion {
                    fields["\(prefix)RecoverySuggestion"] = String(recoverySuggestion.prefix(2_048))
                }
                if let failingURL = current.userInfo["NSURLErrorKey"] as? URL {
                    var components = URLComponents(url: failingURL, resolvingAgainstBaseURL: false)
                    components?.query = nil
                    components?.fragment = nil
                    fields["\(prefix)URL"] = components?.string ?? failingURL.path
                } else if let failingURL = current.userInfo["NSURLErrorKey"] as? String {
                    var components = URLComponents(string: failingURL)
                    components?.query = nil
                    components?.fragment = nil
                    fields["\(prefix)URL"] = components?.string ?? String(failingURL.prefix(4_096))
                }
            }
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return fields
    }

    private static func diagnosticUserInfoValue(_ value: Any, depth: Int = 0) -> Any {
        guard depth < 3 else { return "<nested-value-truncated>" }
        if let string = value as? String { return String(string.prefix(4_096)) }
        if let number = value as? NSNumber { return number }
        if let url = value as? URL {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            components?.fragment = nil
            return components?.string ?? url.path
        }
        if let date = value as? Date { return ISO8601DateFormatter().string(from: date) }
        if let data = value as? Data { return ["byteCount": data.count] }
        if let error = value as? NSError {
            return ["domain": error.domain, "code": error.code, "description": String(error.localizedDescription.prefix(4_096))]
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().prefix(32).reduce(into: [String: Any]()) { result, key in
                if let nested = dictionary[key] {
                    result[key] = diagnosticUserInfoValue(nested, depth: depth + 1)
                }
            }
        }
        if let values = value as? [Any] {
            return values.prefix(32).map { diagnosticUserInfoValue($0, depth: depth + 1) }
        }
        return ["type": String(reflecting: type(of: value))]
    }

    package static func errorFields(_ error: Error, redacting values: [String]) -> [String: String] {
        var fields = errorFields(error, includeUserInfoDetails: true)
        let secrets = values.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        guard !secrets.isEmpty else { return fields }

        let redactableFields = ["errorDescription"] + (0..<5).flatMap { index in
            ["Description", "Reason", "UserInfo", "DebugDescription", "FilePath", "RecoverySuggestion", "URL"].map {
                "error\(index)\($0)"
            }
        }
        for key in redactableFields {
            guard var value = fields[key] else { continue }
            for secret in secrets {
                value = value.replacingOccurrences(of: secret, with: "[redacted]")
            }
            fields[key] = value
        }
        return fields
    }
}

private struct DiagnosticValueTransfer<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
