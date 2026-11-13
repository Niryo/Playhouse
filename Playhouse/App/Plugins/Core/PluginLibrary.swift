import Foundation

/// Where an installed plugin's entry button sits. Each placement hands the
/// plugin a different context in `Playhouse.props`.
enum PluginPlacement: String, CaseIterable, Codable, Sendable {
    /// The board's sidebar, below Scheduled Tasks. Standalone: no task.
    case mainSidebar
    /// The conversation task sidebar's first section, above Changes.
    case conversationSidebar
    /// The task sidebar's bottom row, beside the Terminal button.
    case conversationToolbar
    /// The composer's actions row, beside the Skills button.
    case composerActions

    var title: String {
        switch self {
        case .mainSidebar: "Main sidebar"
        case .conversationSidebar: "Conversation sidebar"
        case .conversationToolbar: "Conversation sidebar toolbar"
        case .composerActions: "Chat input actions"
        }
    }

    /// The entry and its "Add here" placeholder show only an icon here.
    var isIconOnly: Bool {
        self == .conversationToolbar || self == .composerActions
    }

    var hasTask: Bool { self != .mainSidebar }

    /// What this placement adds to `Playhouse.props`, for the authoring agent.
    var contextDescription: String {
        switch self {
        case .mainSidebar:
            "Standalone: only `plugin` and `app` (no task)."
        case .conversationSidebar, .conversationToolbar:
            "`plugin`, `app`, `task` ({id, title, status, provider, isStandaloneChat}), `repositories` ([{repositoryPath, worktreePath, branch}]) and `contextFolders` ([path])."
        case .composerActions:
            "`plugin`, `app`, `task`, `repositories`, `contextFolders`, and `composer` ({draft, selection: {location, length, text}}), the composer's current draft and the text selected in it."
        }
    }

    static func parse(_ value: String) throws -> PluginPlacement {
        guard let placement = PluginPlacement(rawValue: value) else {
            throw PluginTreeError(message: "Unknown placement \"\(value)\". Placements: \(allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return placement
    }
}

/// How a plugin's surface opens when its entry button is pressed.
enum PluginPresentation: String, CaseIterable, Codable, Sendable {
    /// Anchored to the entry button.
    case popover
    /// A sheet over the window.
    case modal
    /// A panel that slides in from the trailing edge.
    case sidebar
    /// A full page over the board or the conversation.
    case page
}

/// `plugin.json`, the manifest in each plugin's folder.
struct PluginManifest: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// Monotonically increasing published revision; absent in legacy plugins.
    var version: Int? = nil
    /// An SF Symbol.
    var icon: String?
    var placement: String
    var presentation: String
    /// The script, relative to the plugin's folder; `index.js` when absent.
    var entry: String?
    /// The surface's size in points; each presentation has a default.
    var width: Double?
    var height: Double?
}

/// One plugin folder as `plugin list` reports it.
struct PluginRecord: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let version: Int
    let icon: String
    let placement: String
    let presentation: String
    let width: Double?
    let height: Double?
    let folder: String
    let entryPath: String
    /// Valid plugins are mounted; invalid ones are listed with their errors.
    let valid: Bool
    let errors: [String]
}

/// The plain task details a placement's context is built from, so the core
/// needs no app types.
struct PluginTaskContext: Sendable {
    struct Repository: Sendable {
        var repositoryPath: String
        var worktreePath: String
        var branch: String
    }

    var id: String
    var title: String
    var status: String
    var provider: String
    var isStandaloneChat: Bool
    var repositories: [Repository]
    var contextFolders: [String]
}

/// The composer's draft and the text selected in it, in UTF-16 offsets.
struct PluginComposerContext: Sendable, Equatable {
    var draft: String
    var selectionLocation: Int = 0
    var selectionLength: Int = 0

    var selectedText: String {
        let text = draft as NSString
        let location = min(max(0, selectionLocation), text.length)
        let length = min(max(0, selectionLength), text.length - location)
        return text.substring(with: NSRange(location: location, length: length))
    }
}

enum PluginContext {
    /// `Playhouse.props` for a plugin at its placement.
    static func props(
        plugin: PluginRecord,
        appearance: String,
        task: PluginTaskContext?,
        composer: PluginComposerContext?
    ) -> [String: PluginValue] {
        var props: [String: PluginValue] = [
            "plugin": .object([
                "id": .string(plugin.id),
                "name": .string(plugin.name),
                "version": .number(Double(plugin.version)),
                "placement": .string(plugin.placement),
                "presentation": .string(plugin.presentation)
            ]),
            "app": .object(["appearance": .string(appearance)])
        ]
        let placement = PluginPlacement(rawValue: plugin.placement)
        if placement?.hasTask == true, let task {
            props["task"] = .object([
                "id": .string(task.id),
                "title": .string(task.title),
                "status": .string(task.status),
                "provider": .string(task.provider),
                "isStandaloneChat": .bool(task.isStandaloneChat)
            ])
            props["repositories"] = .array(task.repositories.map {
                .object([
                    "repositoryPath": .string($0.repositoryPath),
                    "worktreePath": .string($0.worktreePath),
                    "branch": .string($0.branch)
                ])
            })
            props["contextFolders"] = .array(task.contextFolders.map(PluginValue.string))
        }
        if placement == .composerActions {
            let composer = composer ?? PluginComposerContext(draft: "")
            props["composer"] = .object([
                "draft": .string(composer.draft),
                "selection": .object([
                    "location": .number(Double(composer.selectionLocation)),
                    "length": .number(Double(composer.selectionLength)),
                    "text": .string(composer.selectedText)
                ])
            ])
        }
        return props
    }

    /// The sample task a plugin is validated with.
    static let sampleTask = PluginTaskContext(
        id: "00000000-0000-0000-0000-000000000000", title: "Sample task", status: "In Progress",
        provider: "claude", isStandaloneChat: false,
        repositories: [.init(repositoryPath: "/tmp/sample-repository", worktreePath: "/tmp/sample-worktree", branch: "sample-branch")],
        contextFolders: []
    )
}

/// The user's plugins: one folder per plugin in `<data directory>/plugins`,
/// each holding `plugin.json` and its script.
struct PluginLibrary: Sendable {
    static let manifestName = "plugin.json"
    static let defaultEntry = "index.js"
    static let defaultIcon = "puzzlepiece.extension"

    let directory: URL
    var resources: URL? = PluginRuntime.bundledResources

    init(dataDirectory: String, resources: URL? = PluginRuntime.bundledResources) {
        directory = URL(fileURLWithPath: dataDirectory, isDirectory: true).appendingPathComponent("plugins", isDirectory: true)
        self.resources = resources
    }

    /// Lowercase words joined by hyphens, the plugin's folder name.
    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    /// Every plugin folder, sorted by id. With `validate`, each valid-looking
    /// plugin is also rendered once headlessly with sample context, and any
    /// script error marks it invalid.
    func list(validate: Bool = true) -> [PluginRecord] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries.sorted().compactMap { entry in
            guard !entry.hasPrefix(".") else { return nil }
            let folder = directory.appendingPathComponent(entry, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return record(folder: folder, validate: validate)
        }
    }

    func plugin(id: String, validate: Bool = true) throws -> PluginRecord {
        guard Self.isValidID(id) else { throw PluginTreeError(message: "\"\(id)\" is not a plugin id.") }
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw PluginLibraryError.notFound(id)
        }
        return record(folder: folder, validate: validate)
    }

    /// Drafts and historical revisions live outside the installed-plugin listing.
    var draftDataDirectory: URL { directory.appendingPathComponent(".drafts", isDirectory: true) }
    var draftLibrary: PluginLibrary { PluginLibrary(dataDirectory: draftDataDirectory.path, resources: resources) }

    func prepareDraft(id: String) throws {
        guard Self.isValidID(id) else { throw PluginTreeError(message: "Invalid plugin id.") }
        let fm = FileManager.default
        let target = draftLibrary.directory.appendingPathComponent(id)
        guard !fm.fileExists(atPath: target.path) else { return }
        try fm.createDirectory(at: draftLibrary.directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent(id)
        if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: target) }
    }

    func hasDraftChanges(id: String) -> Bool {
        guard Self.isValidID(id) else { return false }
        let fm = FileManager.default
        let draft = draftLibrary.directory.appendingPathComponent(id)
        let installed = directory.appendingPathComponent(id)
        guard fm.fileExists(atPath: draft.path) else { return false }
        guard fm.fileExists(atPath: installed.path) else { return true }
        let draftPaths = Set((fm.enumerator(atPath: draft.path)?.allObjects as? [String]) ?? [])
        let installedPaths = Set((fm.enumerator(atPath: installed.path)?.allObjects as? [String]) ?? [])
        guard draftPaths == installedPaths else { return true }
        for path in draftPaths {
            let left = draft.appendingPathComponent(path).path
            let right = installed.appendingPathComponent(path).path
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: left, isDirectory: &isDirectory) else { return true }
            if !isDirectory.boolValue && !fm.contentsEqual(atPath: left, andPath: right) { return true }
        }
        return false
    }

    func discardDraft(id: String) throws {
        guard Self.isValidID(id) else { throw PluginTreeError(message: "Invalid plugin id.") }
        let fm = FileManager.default
        let target = draftLibrary.directory.appendingPathComponent(id)
        let installed = directory.appendingPathComponent(id)
        guard fm.fileExists(atPath: installed.path) else {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            return
        }
        try fm.createDirectory(at: draftLibrary.directory, withIntermediateDirectories: true)
        let staging = draftLibrary.directory.appendingPathComponent(".reset-" + UUID().uuidString)
        try fm.copyItem(at: installed, to: staging)
        defer { try? fm.removeItem(at: staging) }
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staging)
        } else { try fm.moveItem(at: staging, to: target) }
    }

    func versions(id: String) throws -> [Int] {
        guard Self.isValidID(id) else { throw PluginTreeError(message: "Invalid plugin id.") }
        let folder = directory.appendingPathComponent(".versions").appendingPathComponent(id)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap(Int.init).sorted(by: >)
    }

    /// Publish a validated draft, preserving the installed tree before replacing it.
    func saveDraft(id: String, source: PluginLibrary? = nil, resetDraft: Bool = true) throws -> (plugin: PluginRecord, draftSyncFailed: Bool) {
        let draft = try (source ?? draftLibrary).plugin(id: id)
        guard draft.valid else { throw PluginTreeError(message: draft.errors.joined(separator: "\n")) }
        let fm = FileManager.default
        let installed = directory.appendingPathComponent(id)
        let old = try? plugin(id: id, validate: false)
        let next = max(old?.version ?? 0, (try versions(id: id).max()) ?? 0) + 1
        let staging = directory.appendingPathComponent(".publish-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: draft.folder), to: staging)
        defer { try? fm.removeItem(at: staging) }
        let manifestURL = staging.appendingPathComponent(Self.manifestName)
        var manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: manifestURL))
        manifest.version = next
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        if let old {
            let history = directory.appendingPathComponent(".versions").appendingPathComponent(id)
            try fm.createDirectory(at: history, withIntermediateDirectories: true)
            let backup = history.appendingPathComponent(String(old.version))
            guard !fm.fileExists(atPath: backup.path) else { throw PluginTreeError(message: "Version \(old.version) already exists.") }
            try fm.copyItem(at: installed, to: backup)
            let backupManifest = backup.appendingPathComponent(Self.manifestName)
            if let data = try? Data(contentsOf: backupManifest),
               var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                json["version"] = old.version
                do { try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: backupManifest, options: .atomic) }
                catch { try? fm.removeItem(at: backup); throw error }
            }
            do { _ = try fm.replaceItemAt(installed, withItemAt: staging) }
            catch { try? fm.removeItem(at: backup); throw error }
        } else {
            try fm.moveItem(at: staging, to: installed)
        }
        // Publication already succeeded; preserve the existing draft if refreshing it fails.
        var draftSyncFailed = false
        if resetDraft {
            do { try discardDraft(id: id) } catch { draftSyncFailed = true }
        }
        return (try plugin(id: id, validate: false), draftSyncFailed)
    }

    func restoreVersion(id: String, version: Int) throws -> (plugin: PluginRecord, draftSyncFailed: Bool) {
        guard Self.isValidID(id), version >= 0 else { throw PluginTreeError(message: "Invalid plugin version.") }
        let source = directory.appendingPathComponent(".versions").appendingPathComponent(id).appendingPathComponent(String(version))
        guard FileManager.default.fileExists(atPath: source.path) else { throw PluginTreeError(message: "Plugin version not found.") }
        // Restore through an isolated staging library: a failed restore must never
        // remove or overwrite the user's draft. Keep a dirty draft after success.
        let dirty = hasDraftChanges(id: id)
        let temporary = directory.appendingPathComponent(".restore-" + UUID().uuidString)
        let staging = PluginLibrary(dataDirectory: temporary.path, resources: resources)
        try FileManager.default.createDirectory(at: staging.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: staging.directory.appendingPathComponent(id))
        let restored = try saveDraft(id: id, source: staging, resetDraft: false)
        var draftSyncFailed = false
        if !dirty {
            do { try discardDraft(id: id) } catch { draftSyncFailed = true }
        }
        return (restored.plugin, draftSyncFailed)
    }

    /// Removes the plugin's folder.
    func delete(id: String) throws {
        let record = try plugin(id: id, validate: false)
        let folder = URL(fileURLWithPath: record.folder, isDirectory: true).standardizedFileURL
        // Only ever a direct child of the plugins folder.
        guard folder.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else {
            throw PluginTreeError(message: "\(folder.path) is not inside \(directory.path).")
        }
        let fm = FileManager.default
        try fm.removeItem(at: folder)
        for auxiliary in [draftLibrary.directory.appendingPathComponent(id), directory.appendingPathComponent(".versions").appendingPathComponent(id)] {
            if fm.fileExists(atPath: auxiliary.path) { try fm.removeItem(at: auxiliary) }
        }
    }

    private func record(folder: URL, validate: Bool) -> PluginRecord {
        let folderID = folder.lastPathComponent
        var errors: [String] = []
        var manifest = PluginManifest(id: folderID, name: folderID, placement: "", presentation: "")
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent(Self.manifestName))
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch let error as DecodingError {
            errors.append("\(Self.manifestName) is invalid: \(Self.describe(error))")
        } catch {
            errors.append("\(Self.manifestName) is missing.")
        }
        if errors.isEmpty {
            if manifest.id != folderID { errors.append("The manifest's id \"\(manifest.id)\" does not match its folder \"\(folderID)\".") }
            if !Self.isValidID(folderID) { errors.append("The folder name \"\(folderID)\" must be lowercase words joined by hyphens.") }
            if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("The manifest needs a name.") }
            if PluginPlacement(rawValue: manifest.placement) == nil {
                errors.append("Unknown placement \"\(manifest.placement)\". Placements: \(PluginPlacement.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            if PluginPresentation(rawValue: manifest.presentation) == nil {
                errors.append("Unknown presentation \"\(manifest.presentation)\". Presentations: \(PluginPresentation.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
        }
        let entry = folder.appendingPathComponent(manifest.entry ?? Self.defaultEntry)
        let entryInside = entry.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
        if !entryInside {
            errors.append("The entry \"\(manifest.entry ?? "")\" must be inside the plugin's folder.")
        } else if errors.isEmpty, !FileManager.default.fileExists(atPath: entry.path) {
            errors.append("The entry script \(entry.lastPathComponent) is missing.")
        }
        var record = PluginRecord(
            id: folderID, name: manifest.name, version: manifest.version ?? 0, icon: manifest.icon ?? Self.defaultIcon,
            placement: manifest.placement, presentation: manifest.presentation,
            width: manifest.width, height: manifest.height,
            folder: folder.path, entryPath: entry.path, valid: errors.isEmpty, errors: errors
        )
        if validate, errors.isEmpty {
            let renderErrors = self.renderErrors(record)
            if !renderErrors.isEmpty {
                record = PluginRecord(
                    id: record.id, name: record.name, version: record.version, icon: record.icon, placement: record.placement,
                    presentation: record.presentation, width: record.width, height: record.height,
                    folder: record.folder, entryPath: record.entryPath, valid: false, errors: renderErrors
                )
            }
        }
        return record
    }

    /// Renders the plugin once with sample context and its timers settled.
    /// Host calls are answered with an error, since nothing is mounted.
    private func renderErrors(_ record: PluginRecord) -> [String] {
        do {
            let source = try String(contentsOfFile: record.entryPath, encoding: .utf8)
            let props = PluginContext.props(
                plugin: record, appearance: "dark", task: PluginContext.sampleTask,
                composer: PluginComposerContext(draft: "Sample draft", selectionLocation: 0, selectionLength: 6)
            )
            let runtime = try PluginRuntime(
                source: source, sourceName: URL(fileURLWithPath: record.entryPath).lastPathComponent,
                props: props, resources: resources, timers: .manual
            )
            runtime.runDueTimers()
            for call in runtime.pendingHostCalls {
                runtime.answerHostCall(call.id, result: .failure(PluginHostError(code: "unavailable", message: "Host calls are not answered while a plugin is validated.")))
            }
            runtime.runDueTimers()
            return runtime.errors
        } catch {
            return [error.localizedDescription]
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): "missing \"\(key.stringValue)\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            "\"\(context.codingPath.map(\.stringValue).joined(separator: "."))\" has the wrong type"
        case .dataCorrupted(let context): context.debugDescription
        @unknown default: error.localizedDescription
        }
    }
}

/// What a host refuses from a plugin, the same in the window and in
/// `plugin render`, so the headless check matches what the user sees.
enum PluginHostRules {
    static let uiCalls: Set<String> = ["close", "openTask", "composer.setDraft", "composer.insertText", "composer.replaceSelection", "composer.focus"]

    /// Nil when the host should answer `call`. `placement` is nil for a plugin
    /// rendered from a file or a catalog page, which may call anything.
    static func refusal(kind: String, name: String, placement: PluginPlacement?) -> PluginHostError? {
        switch kind {
        case "bridge":
            // Every other bridge command is the plugin's to call; rendering plugins would recurse.
            return name == "plugin.render" ? PluginHostError(code: "invalid_argument", message: "A plugin can't render plugins.") : nil
        case "ui":
            guard uiCalls.contains(name) else { return PluginHostError(code: "invalid_argument", message: "Unknown host call ui.\(name).") }
            if name.hasPrefix("composer."), let placement, !placement.hasTask {
                return PluginHostError(code: "unavailable", message: "There is no composer at the \(placement.title) placement.")
            }
            return nil
        case "net":
            // fetch reaches the network from every placement; `PluginNetwork` checks its URL.
            return name == "fetch" ? nil : PluginHostError(code: "invalid_argument", message: "Unknown host call net.\(name).")
        default:
            return PluginHostError(code: "invalid_argument", message: "Unknown host call \(kind).\(name).")
        }
    }
}

enum PluginLibraryError: LocalizedError {
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let id): "No plugin has the id \"\(id)\"."
        }
    }
}
