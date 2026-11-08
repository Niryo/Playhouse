import Foundation

// MARK: - Model

/// Where an MCP server is configured. Claude Code reads `mcpServers` in its
/// state file and a repository's `.mcp.json`; Codex reads `[mcp_servers]` in
/// its `config.toml` and a trusted repository's `.codex/config.toml`. Playhouse
/// lists them as one set and hands each server to the provider that would not
/// otherwise start it.
enum McpLayout: String, Codable, Sendable {
    /// `<repo>/.mcp.json`, Claude Code's project servers.
    case projectJSON
    /// `<repo>/.codex/config.toml`, Codex's project servers.
    case codexProject
    /// `mcpServers` in `~/.claude.json` (or `$CLAUDE_CONFIG_DIR/.claude.json`), Claude Code's user servers.
    case claudeUser
    /// `[mcp_servers]` in `$CODEX_HOME/config.toml`.
    case codexGlobal
    /// The organization's `managed-mcp.json`, which only Claude Code reads.
    case claudeManaged

    var displayName: String {
        switch self {
        case .projectJSON: ".mcp.json"
        case .codexProject: ".codex/config.toml"
        case .claudeUser: "Claude ~/.claude.json"
        case .codexGlobal: "Codex config.toml"
        case .claudeManaged: "Managed managed-mcp.json"
        }
    }

    /// The provider that reads this file on its own.
    var nativeProvider: ConversationProvider {
        switch self {
        case .projectJSON, .claudeUser, .claudeManaged: .claude
        case .codexProject, .codexGlobal: .codex
        }
    }

    var isCodexTOML: Bool { self == .codexProject || self == .codexGlobal }
}

enum McpScope: String, Codable, Sendable, CaseIterable {
    case repo
    case global
    case managed
}

/// One server's definition in the form both providers share. Claude Code's
/// `${VAR}` references stand for environment variables; Codex's `env_vars`,
/// `bearer_token_env_var` and `env_http_headers` are read into the same form.
struct McpServerConfig: Codable, Equatable, Sendable {
    enum Transport: String, Codable, Sendable, CaseIterable {
        /// A local command that speaks MCP over stdin and stdout.
        case stdio
        /// A remote server over streamable HTTP.
        case http
        /// A remote server over server-sent events, which only Claude Code supports.
        case sse
    }

    var transport: Transport
    var command: String?
    var args: [String] = []
    var env: [String: String] = [:]
    var url: String?
    var headers: [String: String] = [:]
    /// The folder a Codex server's command runs in, which Claude Code has no place for.
    var cwd: String?

    /// The command line or URL, to tell servers apart at a glance.
    var summary: String {
        switch transport {
        case .stdio: ([command ?? ""] + args).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        case .http, .sse: url ?? ""
        }
    }

    /// What is wrong with the definition itself, or nil when it can run.
    var problem: String? {
        switch transport {
        case .stdio:
            return (command ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "It has no command to run." : nil
        case .http, .sse:
            return (url ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "It has no URL." : nil
        }
    }

    // MARK: Claude Code JSON

    init(transport: Transport, command: String? = nil, args: [String] = [], env: [String: String] = [:], url: String? = nil, headers: [String: String] = [:], cwd: String? = nil) {
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.cwd = cwd
    }

    private enum CodingKeys: String, CodingKey { case transport, command, args, env, url, headers, cwd }

    /// Every field but the transport may be left out.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            transport: try container.decode(Transport.self, forKey: .transport),
            command: try container.decodeIfPresent(String.self, forKey: .command),
            args: try container.decodeIfPresent([String].self, forKey: .args) ?? [],
            env: try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:],
            url: try container.decodeIfPresent(String.self, forKey: .url),
            headers: try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
            cwd: try container.decodeIfPresent(String.self, forKey: .cwd)
        )
    }

    init(claude json: [String: Any]) {
        let url = json["url"] as? String
        let type = (json["type"] as? String).flatMap(Transport.init(rawValue:)) ?? (url != nil && json["command"] == nil ? .http : .stdio)
        self.init(
            transport: type,
            command: json["command"] as? String,
            args: (json["args"] as? [Any] ?? []).map { "\($0)" },
            env: Self.strings(json["env"]),
            url: url,
            headers: Self.strings(json["headers"])
        )
    }

    var claudeJSON: [String: Any] {
        switch transport {
        case .stdio:
            return ["type": "stdio", "command": command ?? "", "args": args, "env": env]
        case .http, .sse:
            var json: [String: Any] = ["type": transport.rawValue, "url": url ?? ""]
            if !headers.isEmpty { json["headers"] = headers }
            return json
        }
    }

    /// Replaces the fields Playhouse edits and keeps every other key, such as
    /// an OAuth client ID, as written.
    func claudeJSON(merging existing: [String: Any]) -> [String: Any] {
        var json = existing
        for key in ["type", "command", "args", "env", "url", "headers"] { json[key] = nil }
        json.merge(claudeJSON) { _, new in new }
        return json
    }

    // MARK: Codex TOML

    private static let codexKeys = ["command", "args", "env", "env_vars", "url", "http_headers", "env_http_headers", "bearer_token_env_var"]

    init(codex table: [String: Any]) {
        var env = Self.strings(table["env"])
        for name in table["env_vars"] as? [Any] ?? [] { env["\(name)"] = "${\(name)}" }
        var headers = Self.strings(table["http_headers"])
        for (header, variable) in Self.strings(table["env_http_headers"]) { headers[header] = "${\(variable)}" }
        if let variable = table["bearer_token_env_var"] as? String { headers["Authorization"] = "Bearer ${\(variable)}" }
        let url = table["url"] as? String
        self.init(
            transport: url != nil && table["command"] == nil ? .http : .stdio,
            command: table["command"] as? String,
            args: (table["args"] as? [Any] ?? []).map { "\($0)" },
            env: env,
            url: url,
            headers: headers,
            cwd: table["cwd"] as? String
        )
    }

    /// Why Claude Code can't run the server, or nil when it can.
    var claudeProblem: String? {
        cwd == nil ? nil : "Claude Code can't use it: it runs in a working folder (cwd), which Claude Code's configuration has no place for."
    }

    /// The `[mcp_servers.<name>]` table Codex reads, or why Codex can't use the server.
    func codexTable() -> Result<[String: Any], McpTranslationError> {
        func reject(_ message: String) -> Result<[String: Any], McpTranslationError> { .failure(McpTranslationError(message: message)) }
        switch transport {
        case .sse:
            return reject("Codex runs local commands and streamable HTTP servers, not SSE servers.")
        case .stdio:
            guard let command, !Self.hasReference(command), !args.contains(where: Self.hasReference) else {
                return reject("Codex doesn't expand ${…} references in a server's command or arguments.")
            }
            var table: [String: Any] = ["command": command]
            if !args.isEmpty { table["args"] = args }
            if let cwd { table["cwd"] = cwd }
            var literal: [String: String] = [:]
            var passed: [String] = []
            for (key, value) in env {
                if value == "${\(key)}" { passed.append(key) }
                else if Self.hasReference(value) { return reject("Codex can pass \(key) through from the environment only under its own name, not as \(value).") }
                else { literal[key] = value }
            }
            if !literal.isEmpty { table["env"] = literal }
            if !passed.isEmpty { table["env_vars"] = passed.sorted() }
            return .success(table)
        case .http:
            guard let url, !Self.hasReference(url) else { return reject("Codex doesn't expand ${…} references in a server's URL.") }
            var table: [String: Any] = ["url": url]
            var literal: [String: String] = [:]
            var fromEnvironment: [String: String] = [:]
            for (header, value) in headers {
                if header.caseInsensitiveCompare("Authorization") == .orderedSame, let variable = Self.reference(in: value, prefix: "Bearer ") {
                    table["bearer_token_env_var"] = variable
                } else if let variable = Self.reference(in: value, prefix: "") {
                    fromEnvironment[header] = variable
                } else if Self.hasReference(value) {
                    return reject("Codex can read the \(header) header from one environment variable, not from \(value).")
                } else {
                    literal[header] = value
                }
            }
            if !literal.isEmpty { table["http_headers"] = literal }
            if !fromEnvironment.isEmpty { table["env_http_headers"] = fromEnvironment }
            return .success(table)
        }
    }

    /// Replaces the fields Playhouse edits and keeps Codex's own, such as
    /// `startup_timeout_sec` or `enabled_tools`, as written.
    func codexTable(merging existing: [String: Any]) -> Result<[String: Any], McpTranslationError> {
        codexTable().map { table in
            var merged = existing
            for key in Self.codexKeys { merged[key] = nil }
            merged.merge(table) { _, new in new }
            return merged
        }
    }

    /// The definition as each provider would run it, so two files that say
    /// the same thing in their own syntax compare equal.
    var normalized: McpServerConfig {
        var copy = self
        copy.command = command?.trimmingCharacters(in: .whitespaces)
        copy.url = url?.trimmingCharacters(in: .whitespaces)
        if copy.transport == .stdio { copy.url = nil; copy.headers = [:] } else { copy.command = nil; copy.args = []; copy.env = [:]; copy.cwd = nil }
        return copy
    }

    private static func strings(_ value: Any?) -> [String: String] {
        (value as? [String: Any] ?? [:]).mapValues { "\($0)" }
    }

    static func hasReference(_ text: String) -> Bool { text.contains("${") }

    /// The variable name in a value that is exactly `<prefix>${NAME}`.
    private static func reference(in value: String, prefix: String) -> String? {
        guard value.hasPrefix(prefix + "${"), value.hasSuffix("}") else { return nil }
        let name = value.dropFirst(prefix.count + 2).dropLast()
        return name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil ? String(name) : nil
    }
}

struct McpTranslationError: Error, Equatable {
    let message: String
}

struct McpLocation: Codable, Equatable, Sendable {
    /// The file that defines the server.
    let path: String
    let layout: McpLayout
    /// False for a server written inline in a config.toml, which Playhouse leaves to the user.
    let editable: Bool
}

struct McpServerRecord: Codable, Equatable, Identifiable, Sendable {
    /// Stable across tasks: a repository server is keyed by its source
    /// repository and its name, so its enabled state follows the repository.
    let id: String
    let name: String
    let scope: McpScope
    let repositoryPath: String?
    let rootPath: String?
    let transport: McpServerConfig.Transport
    /// The command line or URL.
    let summary: String
    /// Only the names: values can be secrets.
    let envNames: [String]
    let headerNames: [String]
    let locations: [McpLocation]
    /// Providers that start the server on their own outside Playhouse.
    let nativeProviders: [ConversationProvider]
    /// Providers that get the server in sessions Playhouse launches.
    let providers: [ConversationProvider]
    /// Providers that get the server only because Playhouse passes it to them.
    let sharedWith: [ConversationProvider]
    /// Providers that keep starting the server even while it is turned off,
    /// because Playhouse can't hide it from them for one run.
    let alwaysOnFor: [ConversationProvider]
    let enabled: Bool
    let editable: Bool
    /// Both providers start it on their own, so it also works outside Playhouse.
    let availableOutsidePlayhouse: Bool
    /// Link can write it into the configuration of the provider that lacks it.
    let linkable: Bool
    let conflict: Bool
    let issue: String?
    /// Why one provider can't use the server, such as Codex for an SSE server.
    let limitation: String?
}

struct McpRepositorySection: Codable, Equatable, Sendable {
    let repositoryPath: String
    let rootPath: String
    let name: String
    let servers: [McpServerRecord]
}

/// A configuration file Playhouse could not read, so its servers are missing.
struct McpFileProblem: Codable, Equatable, Sendable {
    let path: String
    let message: String
}

struct McpCatalog: Codable, Equatable, Sendable {
    let repositories: [McpRepositorySection]
    let global: [McpServerRecord]
    let managed: [McpServerRecord]
    let problems: [McpFileProblem]

    var allServers: [McpServerRecord] { repositories.flatMap(\.servers) + global + managed }
    func server(id: String) -> McpServerRecord? { allServers.first { $0.id == id } }

    func replacing(_ record: McpServerRecord) -> McpCatalog {
        func swap(_ servers: [McpServerRecord]) -> [McpServerRecord] { servers.map { $0.id == record.id ? record : $0 } }
        return McpCatalog(
            repositories: repositories.map {
                McpRepositorySection(repositoryPath: $0.repositoryPath, rootPath: $0.rootPath, name: $0.name, servers: swap($0.servers))
            },
            global: swap(global),
            managed: swap(managed),
            problems: problems
        )
    }
}

/// What each provider reports about the servers it starts, such as one that
/// needs the user to sign in.
struct McpProviderStatus: Codable, Equatable, Sendable {
    let name: String
    let status: String
    let needsSignIn: Bool
}

struct McpStatusReport: Codable, Equatable, Sendable {
    var claude: [McpProviderStatus] = []
    var codex: [McpProviderStatus] = []
    /// A provider that could not be asked, with why.
    var errors: [String: String] = [:]
}

/// A sign-in one provider started for an MCP server: the page opens the link
/// in the user's browser, and the provider finishes the login when the browser
/// redirects back to it.
struct McpLoginStart: Codable, Equatable, Sendable {
    let provider: ConversationProvider
    let name: String
    let authorizationUrl: String
}

struct McpLoginResult: Codable, Equatable, Sendable {
    let provider: ConversationProvider
    let name: String
    /// The provider now reports the server as signed in.
    let signedIn: Bool
    let error: String?
}

enum McpLogin {
    /// How long a started sign-in waits for the user to finish in the browser.
    static var timeout: Duration {
        let seconds = PlayhouseProcessEnvironment.current["PLAYHOUSE_E2E_MCP_LOGIN_TIMEOUT_SECONDS"].flatMap(Double.init) ?? 300
        return .milliseconds(Int(seconds * 1000))
    }

    static let pollInterval: Duration = .seconds(2)

    static func pollInterval(for timeout: Duration) -> Duration {
        timeout < .seconds(30) ? .milliseconds(250) : pollInterval
    }

    static func timedOut(provider: ConversationProvider, name: String) -> McpLoginResult {
        McpLoginResult(provider: provider, name: name, signedIn: false,
                       error: "The sign-in to \(name) wasn't finished in the browser in time. Click Sign in to try again.")
    }

    static func notStarted(provider: ConversationProvider, name: String) -> McpLoginResult {
        McpLoginResult(provider: provider, name: name, signedIn: false,
                       error: "No sign-in to \(name) is in progress for \(provider.displayName).")
    }
}

/// What a provider launch needs so it starts every server that is on. Nothing
/// is written to the user's files: Claude Code gets `--mcp-config` and
/// `--settings`, and Codex gets the thread's `mcp_servers` config, which Codex
/// merges server by server over its own `config.toml`.
struct McpBridgeLaunch: Codable, Equatable, Sendable {
    struct SharedServer: Codable, Equatable, Sendable {
        let id: String
        let name: String
    }

    var claudeShared: [SharedServer] = []
    /// `--mcp-config` JSON with the servers Claude Code doesn't read itself.
    var claudeMcpConfig: String?
    /// The working repository's `.mcp.json` servers to start or skip in this run.
    var claudeEnabledProjectServers: [String] = []
    var claudeDisabledProjectServers: [String] = []
    var codexShared: [SharedServer] = []
    /// Codex's own servers turned off in this thread.
    var codexDisabled: [String] = []
    /// The thread's `mcp_servers` config as sorted-key JSON, so a change is
    /// noticed and the thread is resumed with it.
    var codexServersJSON: String?

    var claudeSettings: [String: Any] {
        var settings: [String: Any] = [:]
        if !claudeEnabledProjectServers.isEmpty { settings["enabledMcpjsonServers"] = claudeEnabledProjectServers }
        if !claudeDisabledProjectServers.isEmpty { settings["disabledMcpjsonServers"] = claudeDisabledProjectServers }
        return settings
    }

    var codexServers: [String: Any]? {
        guard let codexServersJSON, let data = codexServersJSON.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - Config files

/// Reads and writes the JSON files Claude Code keeps MCP servers in.
enum McpJSONFile {
    /// The file's top-level object, or nil when it doesn't exist.
    static func read(_ path: String) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeCommandError(code: "invalid_argument", message: "\(path) is not a JSON object.")
        }
        return object
    }

    /// Reads, changes, and writes the file atomically. Claude Code rewrites its
    /// state file often and locks it with a `<file>.lock` folder, so Playhouse
    /// takes the same lock for the moment it writes.
    static func update(_ path: String, _ change: (inout [String: Any]) throws -> Void) throws {
        try withLock(path) {
            var object = try read(path) ?? [:]
            try change(&object)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try write(data + Data("\n".utf8), to: path)
        }
    }

    /// Writes atomically through a symlinked file (a dotfiles setup) to the
    /// file it points at, and keeps the file's permissions, which may be 0600
    /// for a file that holds tokens.
    static func write(_ data: Data, to path: String) throws {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let fileManager = FileManager.default
        let permissions = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The new copy has the old permissions before it replaces the file, so a
        // 0600 file is never readable by others, even for a moment.
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).playhouse-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: permissions ?? 0o644]) else {
            throw BridgeCommandError(code: "io_error", message: "Playhouse couldn't write beside \(target.path).")
        }
        guard rename(staging.path, target.path) == 0 else {
            let message = String(cString: strerror(errno))
            try? fileManager.removeItem(at: staging)
            throw BridgeCommandError(code: "io_error", message: "Playhouse couldn't replace \(target.path): \(message).")
        }
    }

    private static func withLock(_ path: String, _ body: () throws -> Void) throws {
        let lock = path + ".lock"
        let fileManager = FileManager.default
        let deadline = Date().addingTimeInterval(5)
        while true {
            do {
                try fileManager.createDirectory(atPath: lock, withIntermediateDirectories: false)
                break
            } catch {
                let modified = (try? fileManager.attributesOfItem(atPath: lock)[.modificationDate] as? Date) ?? .distantPast
                // A lock nobody refreshed for 10 seconds was left by a process that died.
                if Date().timeIntervalSince(modified) > 10 { try? fileManager.removeItem(atPath: lock); continue }
                guard Date() < deadline else {
                    throw BridgeCommandError(code: "busy", message: "\(path) is locked by another program. Try again in a moment.")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        defer { try? fileManager.removeItem(atPath: lock) }
        try body()
    }
}

// MARK: - Manager

/// Reads and manages the MCP servers shared by both providers. The GUI and the
/// CLI reach it through the same bridge commands.
@MainActor
final class McpCatalogManager {
    static let disabledServersKey = "disabledMcpServerIDs"

    private let environment: SkillEnvironment
    private let preferences: UserDefaults
    private let fileManager = FileManager.default

    init(environment: SkillEnvironment, preferences: UserDefaults) {
        self.environment = environment
        self.preferences = preferences
    }

    var disabledServerIDs: Set<String> {
        Set(preferences.stringArray(forKey: Self.disabledServersKey) ?? [])
    }

    var claudeStatePath: String { environment.claudeStateFile }
    var codexConfigPath: String { environment.codexHome + "/config.toml" }
    var managedPath: String { environment.managedClaudeDirectory + "/managed-mcp.json" }
    static func projectJSONPath(_ root: String) -> String { root + "/.mcp.json" }
    static func codexProjectPath(_ root: String) -> String { root + "/.codex/config.toml" }

    // MARK: Reading

    private struct Scanned {
        let name: String
        let config: McpServerConfig
        let raw: [String: Any]
        let location: McpLocation
        /// Codex's own `enabled = false`, so Codex doesn't start it on its own either.
        var offInFile = false
    }

    private struct Entry {
        var record: McpServerRecord
        let config: McpServerConfig
        /// Providers that start the server themselves in a Playhouse launch.
        let nativeInLaunch: Set<ConversationProvider>
        let codexTable: [String: Any]?
        let rootIndex: Int?
    }

    func catalog(roots: [SkillRoot]) -> McpCatalog {
        let (entries, problems) = self.entries(roots: roots)
        let sections = roots.enumerated().map { index, root in
            McpRepositorySection(
                repositoryPath: root.repositoryPath, rootPath: root.path, name: root.name,
                servers: entries.filter { $0.rootIndex == index }.map(\.record)
            )
        }
        return McpCatalog(
            repositories: sections,
            global: entries.filter { $0.record.scope == .global }.map(\.record),
            managed: entries.filter { $0.record.scope == .managed }.map(\.record),
            problems: problems
        )
    }

    private func entries(roots: [SkillRoot]) -> (entries: [Entry], problems: [McpFileProblem]) {
        let disabled = disabledServerIDs
        var problems: [McpFileProblem] = []
        var result: [Entry] = []

        for (index, root) in roots.enumerated() {
            let scanned = scanJSON(Self.projectJSONPath(root.path), layout: .projectJSON, problems: &problems)
                + scanTOML(Self.codexProjectPath(root.path), layout: .codexProject, problems: &problems)
            for group in grouped(scanned) {
                result.append(entry(group, scope: .repo, root: root, rootIndex: index, disabled: disabled))
            }
        }
        let global = scanJSON(claudeStatePath, layout: .claudeUser, problems: &problems)
            + scanTOML(codexConfigPath, layout: .codexGlobal, problems: &problems)
        for group in grouped(global) {
            result.append(entry(group, scope: .global, root: nil, rootIndex: nil, disabled: disabled))
        }
        for group in grouped(scanJSON(managedPath, layout: .claudeManaged, problems: &problems)) {
            result.append(entry(group, scope: .managed, root: nil, rootIndex: nil, disabled: disabled))
        }
        return (result, problems)
    }

    private func scanJSON(_ path: String, layout: McpLayout, problems: inout [McpFileProblem]) -> [Scanned] {
        let object: [String: Any]?
        do {
            object = try McpJSONFile.read(path)
        } catch {
            problems.append(McpFileProblem(path: path, message: "Playhouse can't read it as JSON, so its servers are not listed."))
            return []
        }
        let servers = object?["mcpServers"] as? [String: Any] ?? [:]
        return servers.keys.sorted().compactMap { name in
            guard let raw = servers[name] as? [String: Any] else { return nil }
            return Scanned(name: name, config: McpServerConfig(claude: raw), raw: raw,
                           location: McpLocation(path: path, layout: layout, editable: true))
        }
    }

    private func scanTOML(_ path: String, layout: McpLayout, problems: inout [McpFileProblem]) -> [Scanned] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        do {
            return try CodexConfigTOML.servers(in: text).map { server in
                Scanned(name: server.name, config: McpServerConfig(codex: server.table), raw: server.table,
                        location: McpLocation(path: path, layout: layout, editable: server.editable),
                        offInFile: server.table["enabled"] as? Bool == false)
            }
        } catch {
            problems.append(McpFileProblem(path: path, message: "Playhouse can't read it as TOML (\(error.localizedDescription)), so its servers are not listed."))
            return []
        }
    }

    /// Definitions with one name in one scope are one server, in scan order.
    private func grouped(_ scanned: [Scanned]) -> [[Scanned]] {
        var order: [String] = []
        var groups: [String: [Scanned]] = [:]
        for item in scanned {
            if groups[item.name] == nil { order.append(item.name) }
            groups[item.name, default: []].append(item)
        }
        return order.sorted().compactMap { groups[$0] }
    }

    private func entry(_ group: [Scanned], scope: McpScope, root: SkillRoot?, rootIndex: Int?, disabled: Set<String>) -> Entry {
        let primary = group[0]
        let name = primary.name
        let id: String
        switch scope {
        case .repo: id = Self.repoID(repositoryPath: root?.repositoryPath ?? "", name: name)
        case .global: id = Self.globalID(name: name)
        case .managed: id = Self.managedID(name: name)
        }
        let layouts = Set(group.map(\.location.layout))
        let native = Set(layouts.map(\.nativeProvider))
        let conflict = Set(group.map { Self.fingerprint($0.config) }).count > 1
        // Claude Code starts the working repository's .mcp.json and its own
        // servers; Codex merges Playhouse's thread config over its own
        // config.toml, so only that file's servers count as already started.
        var inLaunch = Set<ConversationProvider>()
        if layouts.contains(.claudeUser) || layouts.contains(.claudeManaged) || (layouts.contains(.projectJSON) && rootIndex == 0) {
            inLaunch.insert(.claude)
        }
        let codexDefinition = group.first { $0.location.layout.isCodexTOML }
        // Codex's own `enabled = false` turns the server off for Codex and keeps
        // Playhouse from passing it to Claude Code.
        let offInCodex = codexDefinition?.offInFile == true
        if layouts.contains(.codexGlobal), !offInCodex { inLaunch.insert(.codex) }

        let codexTable: [String: Any]?
        var limitation: String?
        if offInCodex {
            codexTable = nil
            limitation = "It is turned off in \(codexDefinition!.location.layout.displayName) (enabled = false), so Playhouse doesn't start it."
        } else if let codexDefinition {
            codexTable = codexDefinition.raw
        } else {
            switch primary.config.codexTable() {
            case .success(let table): codexTable = table
            case .failure(let error):
                codexTable = nil
                limitation = "Codex can't use it: " + error.message
            }
        }
        let claudeCanRun = native.contains(.claude) || (primary.config.claudeProblem == nil && !offInCodex)
        if !native.contains(.claude), !offInCodex, let problem = primary.config.claudeProblem { limitation = problem }
        if scope == .managed { limitation = "Your organization manages it for Claude Code, so Playhouse doesn't pass it to Codex." }
        let issue = primary.config.problem.map { "\(name): \($0)" } ?? (conflict
            ? "\(group.map(\.location.layout.displayName).joined(separator: " and ")) define \(name) differently. Each provider keeps its own until you make them match or remove one."
            : nil)

        var reaching = Set<ConversationProvider>()
        if issue == nil {
            if claudeCanRun { reaching.insert(.claude) }
            if codexTable != nil, scope != .managed { reaching.insert(.codex) }
        }
        if conflict { reaching = inLaunch }
        let alwaysOn = inLaunch.intersection(layouts.contains(.claudeUser) || layouts.contains(.claudeManaged) ? [.claude] : [])
        let enabled = scope == .managed || !disabled.contains(id)
        // A server written inline in a config.toml is left to the user, like a managed one.
        let editable = scope != .managed && group.allSatisfy(\.location.editable)
        let bothNative = native.isSuperset(of: ConversationProvider.allCases)
        let record = McpServerRecord(
            id: id, name: name, scope: scope, repositoryPath: root?.repositoryPath, rootPath: root?.path,
            transport: primary.config.transport, summary: primary.config.summary,
            envNames: primary.config.env.keys.sorted(), headerNames: primary.config.headers.keys.sorted(),
            locations: group.map(\.location),
            nativeProviders: RuleCatalogManager.ordered(native),
            providers: RuleCatalogManager.ordered(enabled ? reaching : alwaysOn),
            sharedWith: RuleCatalogManager.ordered(enabled ? reaching.subtracting(inLaunch) : []),
            alwaysOnFor: RuleCatalogManager.ordered(alwaysOn),
            enabled: enabled,
            editable: editable,
            availableOutsidePlayhouse: bothNative,
            linkable: editable && !bothNative && !conflict && issue == nil && claudeCanRun && (native.contains(.codex) || codexTable != nil),
            conflict: conflict,
            issue: issue,
            limitation: limitation
        )
        return Entry(record: record, config: primary.config, nativeInLaunch: inLaunch, codexTable: codexTable, rootIndex: rootIndex)
    }

    private static func fingerprint(_ config: McpServerConfig) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(config.normalized)) ?? Data()
    }

    static func globalID(name: String) -> String { "global:\(name)" }
    static func repoID(repositoryPath: String, name: String) -> String { "repo:\(repositoryPath)#\(name)" }
    static func managedID(name: String) -> String { "managed:\(name)" }

    /// The server's definition with every value, for the editor.
    func config(id: String, roots: [SkillRoot]) throws -> McpServerConfig {
        let (entries, _) = self.entries(roots: roots)
        guard let entry = entries.first(where: { $0.record.id == id }) else {
            throw BridgeCommandError(code: "not_found", message: "No MCP server matches \(id).")
        }
        return entry.config
    }

    // MARK: Managing

    static func validate(name: String) throws {
        guard name.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else {
            throw BridgeCommandError(code: "invalid_argument", message: "A server name uses letters, digits, hyphens, and underscores, up to 64 characters.")
        }
    }

    static func validate(config: McpServerConfig) throws {
        func reject(_ message: String) -> BridgeCommandError { BridgeCommandError(code: "invalid_argument", message: message) }
        switch config.transport {
        case .stdio:
            guard !(config.command ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { throw reject("A local server needs a command to run.") }
            guard (config.url ?? "").isEmpty, config.headers.isEmpty else { throw reject("A local server has a command, not a URL or headers.") }
        case .http:
            let url = (config.url ?? "").trimmingCharacters(in: .whitespaces)
            guard url.hasPrefix("https://") || url.hasPrefix("http://") || url.hasPrefix("${") else { throw reject("A remote server needs an http:// or https:// URL.") }
            guard (config.command ?? "").isEmpty, config.args.isEmpty, config.env.isEmpty else { throw reject("A remote server has a URL, not a command or environment.") }
        case .sse:
            throw reject("Playhouse writes local command and streamable HTTP servers, which both agents can use.")
        }
        if let key = config.env.keys.sorted().first(where: { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil }) {
            throw reject("\(key) is not an environment variable name.")
        }
        if let header = config.headers.keys.sorted().first(where: { $0.isEmpty || $0.contains(":") || $0.contains(" ") }) {
            throw reject("\"\(header)\" is not a header name.")
        }
    }

    private func trimmed(_ config: McpServerConfig) -> McpServerConfig {
        var copy = config
        copy.command = config.command?.trimmingCharacters(in: .whitespaces)
        copy.url = config.url?.trimmingCharacters(in: .whitespaces)
        if copy.command?.isEmpty == true { copy.command = nil }
        if copy.url?.isEmpty == true { copy.url = nil }
        return copy
    }

    /// Writes a new server. A global one goes straight into both providers'
    /// own configuration, Claude Code's `mcpServers` and Codex's config.toml; a
    /// repository one goes into the repository's `.mcp.json`, committed like
    /// any change, and Playhouse passes it to Codex.
    func create(name: String, config: McpServerConfig, scope: McpScope, root: SkillRoot?, roots: [SkillRoot]) throws -> McpServerRecord {
        try Self.validate(name: name)
        let config = trimmed(config)
        try Self.validate(config: config)
        let current = catalog(roots: roots)
        switch scope {
        case .global:
            guard !current.global.contains(where: { $0.name == name }) else {
                throw BridgeCommandError(code: "already_exists", message: "A global MCP server named \(name) already exists. Open it to edit it instead.")
            }
            // Codex's file is checked before either file is written, and Claude's,
            // which can be locked, is written first, so a failure leaves neither half-done.
            let codexText = try updatedTOML(codexConfigPath, name: name, table: try codexTable(config))
            try McpJSONFile.update(claudeStatePath) { object in
                var servers = object["mcpServers"] as? [String: Any] ?? [:]
                servers[name] = config.claudeJSON
                object["mcpServers"] = servers
            }
            try McpJSONFile.write(Data(codexText.utf8), to: codexConfigPath)
        case .repo:
            guard let root else {
                throw BridgeCommandError(code: "invalid_argument", message: "Choose one of the task's repositories for a repository MCP server.")
            }
            guard !(current.repositories.first { $0.rootPath == root.path }?.servers ?? []).contains(where: { $0.name == name }) else {
                throw BridgeCommandError(code: "already_exists", message: "\(root.name) already has an MCP server named \(name). Open it to edit it instead.")
            }
            try McpJSONFile.update(Self.projectJSONPath(root.path)) { object in
                var servers = object["mcpServers"] as? [String: Any] ?? [:]
                servers[name] = config.claudeJSON
                object["mcpServers"] = servers
            }
        case .managed:
            throw BridgeCommandError(code: "invalid_argument", message: "Your organization manages its MCP servers; Playhouse can't add one.")
        }
        PlayhouseDiagnostics.record("mcp.created", fields: ["scope": scope.rawValue, "transport": config.transport.rawValue])
        return try existing(id: scope == .global ? Self.globalID(name: name) : Self.repoID(repositoryPath: root?.repositoryPath ?? "", name: name), roots: roots)
    }

    /// Rewrites the server in every file that defines it, so both providers keep one definition.
    func update(id: String, config: McpServerConfig, roots: [SkillRoot]) throws -> McpServerRecord {
        let record = try editable(id: id, roots: roots)
        let config = trimmed(config)
        try Self.validate(config: config)
        // Every file is checked before any is written.
        var tomlTexts: [String: String] = [:]
        for location in record.locations where location.layout.isCodexTOML {
            let existing = try tomlServer(location.path, name: record.name)?.table ?? [:]
            switch config.codexTable(merging: existing) {
            case .success(let table): tomlTexts[location.path] = try updatedTOML(location.path, name: record.name, table: table)
            case .failure(let error): throw BridgeCommandError(code: "invalid_argument", message: error.message + " Change it so Codex can run it, or remove it from Codex's config.toml.")
            }
        }
        for location in record.locations {
            if let text = tomlTexts[location.path] {
                try McpJSONFile.write(Data(text.utf8), to: location.path)
            } else {
                try McpJSONFile.update(location.path) { object in
                    var servers = object["mcpServers"] as? [String: Any] ?? [:]
                    servers[record.name] = config.claudeJSON(merging: servers[record.name] as? [String: Any] ?? [:])
                    object["mcpServers"] = servers
                }
            }
        }
        PlayhouseDiagnostics.record("mcp.updated", fields: ["scope": record.scope.rawValue])
        return try existing(id: id, roots: roots)
    }

    /// Removes each server from every file that defines it. Every server is
    /// checked first, so one read-only or missing server deletes nothing.
    func delete(ids: [String], roots: [SkillRoot]) throws {
        guard !ids.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose at least one MCP server to delete.")
        }
        let records = try Array(Set(ids)).sorted().map { try editable(id: $0, roots: roots) }
        var disabled = disabledServerIDs
        defer { preferences.set(Array(disabled).sorted(), forKey: Self.disabledServersKey) }
        for record in records {
            for location in record.locations {
                if location.layout.isCodexTOML {
                    let text = try Self.existingText(location.path)
                    if let updated = try CodexConfigTOML.removing(server: record.name, from: text) {
                        try McpJSONFile.write(Data(updated.utf8), to: location.path)
                    }
                } else {
                    try McpJSONFile.update(location.path) { object in
                        var servers = object["mcpServers"] as? [String: Any] ?? [:]
                        servers[record.name] = nil
                        object["mcpServers"] = servers
                    }
                }
            }
            disabled.remove(record.id)
            PlayhouseDiagnostics.record("mcp.deleted", fields: ["scope": record.scope.rawValue])
        }
    }

    func setEnabled(id: String, enabled: Bool, roots: [SkillRoot]) throws -> McpServerRecord {
        let record = try existing(id: id, roots: roots)
        guard record.scope != .managed else {
            throw BridgeCommandError(code: "invalid_argument", message: "Your organization manages \(record.name), so Claude Code always starts it.")
        }
        var disabled = disabledServerIDs
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        preferences.set(Array(disabled).sorted(), forKey: Self.disabledServersKey)
        PlayhouseDiagnostics.record("mcp.enabled.changed", fields: ["id": id, "enabled": String(enabled)])
        return try existing(id: id, roots: roots)
    }

    /// Writes the server into the configuration of the provider that doesn't
    /// read it yet, so both CLIs start it outside Playhouse too.
    func link(id: String, roots: [SkillRoot]) throws -> McpServerRecord {
        let record = try editable(id: id, roots: roots)
        guard !record.conflict else {
            throw BridgeCommandError(code: "invalid_argument", message: record.issue ?? "Resolve the conflict first.")
        }
        guard !record.availableOutsidePlayhouse else { return record }
        if let issue = record.issue { throw BridgeCommandError(code: "invalid_argument", message: issue) }
        let config = try self.config(id: id, roots: roots)
        let native = Set(record.nativeProviders)
        if !native.contains(.codex) {
            let table = try codexTable(config)
            let path = record.scope == .global ? codexConfigPath : Self.codexProjectPath(record.rootPath ?? "")
            try McpJSONFile.write(Data(try updatedTOML(path, name: record.name, table: table).utf8), to: path)
        }
        if !native.contains(.claude) {
            let path = record.scope == .global ? claudeStatePath : Self.projectJSONPath(record.rootPath ?? "")
            try McpJSONFile.update(path) { object in
                var servers = object["mcpServers"] as? [String: Any] ?? [:]
                servers[record.name] = config.claudeJSON
                object["mcpServers"] = servers
            }
        }
        PlayhouseDiagnostics.record("mcp.linked", fields: ["scope": record.scope.rawValue])
        return try existing(id: id, roots: roots)
    }

    private func codexTable(_ config: McpServerConfig) throws -> [String: Any] {
        switch config.codexTable() {
        case .success(let table): return table
        case .failure(let error): throw BridgeCommandError(code: "invalid_argument", message: error.message)
        }
    }

    private func tomlServer(_ path: String, name: String) throws -> CodexConfigTOML.Server? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return try CodexConfigTOML.servers(in: text).first { $0.name == name }
    }

    /// A config file's text, empty when it doesn't exist yet. A file that exists
    /// but can't be read fails, so a write never replaces what it couldn't read.
    private static func existingText(_ path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Playhouse can't read \(path) as text, so it left it unchanged.")
        }
        return text
    }

    /// The config.toml with the server's tables set, checked but not yet written.
    private func updatedTOML(_ path: String, name: String, table: [String: Any]) throws -> String {
        let text = try Self.existingText(path)
        do {
            return try CodexConfigTOML.setting(server: name, table: table, in: text)
        } catch let error as CodexConfigTOML.ParseError {
            throw BridgeCommandError(code: "invalid_argument", message: "\(path) is not valid TOML (\(error.localizedDescription)), so Playhouse left it unchanged.")
        }
    }

    /// What a task needs so an agent can repair conflicting or broken servers:
    /// repository files in the new task's own worktree, committed like any
    /// change, and the user's own configuration in place.
    func fixPlan(ids: [String], roots: [SkillRoot]) throws -> SkillFixPlan {
        guard !ids.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose at least one MCP server to fix.")
        }
        var seen = Set<String>()
        let records = try ids.filter { seen.insert($0).inserted }.map { id in
            // An agent can fix a server written inline, which Playhouse's own editor leaves alone.
            let record = try existing(id: id, roots: roots)
            guard record.scope != .managed else {
                throw BridgeCommandError(code: "invalid_argument", message: "Your organization manages \(record.name), so it is read-only.")
            }
            guard record.issue != nil else {
                throw BridgeCommandError(code: "invalid_argument", message: "\(record.name) has no conflict or problem to fix.")
            }
            return record
        }
        let repoServers = records.filter { $0.scope == .repo }
        let globalServers = records.filter { $0.scope == .global }
        var lines = [
            "Fix the following MCP server definitions so each server has one working definition that both Claude Code and Codex use.",
            "",
            "How MCP servers are configured:",
            "- Claude Code reads `mcpServers` in a repository's `.mcp.json` and in its user file (`~/.claude.json`, or `.claude.json` in `$CLAUDE_CONFIG_DIR`). A local server is `{\"type\": \"stdio\", \"command\": …, \"args\": […], \"env\": {…}}`; a remote one is `{\"type\": \"http\", \"url\": …, \"headers\": {…}}`. Values may use `${VAR}` to read an environment variable.",
            "- Codex reads `[mcp_servers.<name>]` tables in `$CODEX_HOME/config.toml` (usually `~/.codex/config.toml`) and in a trusted repository's `.codex/config.toml`, with `command`, `args`, `env`, `env_vars` (variables passed through), or `url`, `http_headers`, `env_http_headers` and `bearer_token_env_var`.",
            "- A conflict means two files define a server with the same name differently. Compare them and make both say the same thing in each file's own syntax, keeping the definition that works, or remove one.",
            "- Never print or commit secret values; keep them in environment variables.",
        ]
        if !repoServers.isEmpty {
            lines += ["", "Repository servers. These files are committed to Git: fix them in this task's worktree like any other code change, then commit and push so the fix goes through review. Paths are relative to the repository root."]
            for record in repoServers {
                let repository = URL(fileURLWithPath: record.repositoryPath ?? "").lastPathComponent
                let files = record.locations.map { "`" + RuleCatalogManager.relativePath(of: $0.path, inside: record.rootPath ?? "") + "`" }
                lines.append("- `\(record.name)` in \(repository): \(files.joined(separator: ", ")). Problem: \(record.issue ?? "")")
            }
        }
        if !globalServers.isEmpty {
            lines += ["", "Global servers. These live in the user's home folder and are not tracked by Git: fix them directly in place. There is nothing to commit or push for them. Change only these servers' entries and leave the rest of each file as it is."]
            for record in globalServers {
                lines.append("- `\(record.name)`: \(record.locations.map { "`\($0.path)`" }.joined(separator: ", ")). Problem: \(record.issue ?? "")")
            }
        }
        lines += ["", "When you are done, list each server and what you changed."]
        let names = records.map(\.name)
        let title = names.count == 1 ? "Fix MCP server \(names[0])" : "Fix \(names.count) MCP servers"
        var repositories: [String] = []
        for record in repoServers {
            if let path = record.repositoryPath, !repositories.contains(path) { repositories.append(path) }
        }
        var folders: [String] = []
        for record in globalServers {
            for location in record.locations {
                let folder = (location.path as NSString).deletingLastPathComponent
                if !folders.contains(folder) { folders.append(folder) }
            }
        }
        PlayhouseDiagnostics.record("mcp.fix.planned", fields: ["serverCount": String(records.count)])
        return SkillFixPlan(title: title, prompt: lines.joined(separator: "\n"), repositoryPaths: repositories, contextFolders: folders)
    }

    private func existing(id: String, roots: [SkillRoot]) throws -> McpServerRecord {
        guard let record = catalog(roots: roots).server(id: id) else {
            throw BridgeCommandError(code: "not_found", message: "No MCP server matches \(id).")
        }
        return record
    }

    private func editable(id: String, roots: [SkillRoot]) throws -> McpServerRecord {
        let record = try existing(id: id, roots: roots)
        guard record.editable else {
            if record.scope == .managed {
                throw BridgeCommandError(code: "invalid_argument", message: "Your organization manages \(record.name), so it is read-only.")
            }
            let inline = record.locations.first { !$0.editable }?.path ?? "config.toml"
            throw BridgeCommandError(code: "invalid_argument", message: "\(record.name) is written inline in \(inline), so Playhouse leaves it to you. Edit it there, or rewrite it as an [mcp_servers.\(record.name)] table.")
        }
        return record
    }

    // MARK: Bridge

    /// What a launch passes each provider so it starts the servers that are on
    /// and skips the ones that are off, where the provider allows it.
    func bridge(roots: [SkillRoot]) -> McpBridgeLaunch {
        let (entries, _) = self.entries(roots: roots)
        var launch = McpBridgeLaunch()
        let usable = { (entry: Entry) in entry.record.enabled && !entry.record.conflict && entry.record.issue == nil }

        // Claude Code: a name it already starts itself is never passed again.
        var claudeNames = Set(entries.filter { $0.nativeInLaunch.contains(.claude) }.map(\.record.name))
        var claudeServers: [String: Any] = [:]
        for entry in entries where usable(entry) && !entry.nativeInLaunch.contains(.claude) && entry.record.providers.contains(.claude) && entry.record.scope != .managed {
            guard claudeNames.insert(entry.record.name).inserted else { continue }
            claudeServers[entry.record.name] = entry.config.claudeJSON
            launch.claudeShared.append(.init(id: entry.record.id, name: entry.record.name))
        }
        if !claudeServers.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": claudeServers], options: [.sortedKeys, .withoutEscapingSlashes]) {
            launch.claudeMcpConfig = String(data: data, encoding: .utf8)
        }
        for entry in entries where entry.rootIndex == 0 && entry.record.locations.contains(where: { $0.layout == .projectJSON }) {
            if entry.record.enabled && !entry.record.conflict { launch.claudeEnabledProjectServers.append(entry.record.name) }
            else if !entry.record.enabled { launch.claudeDisabledProjectServers.append(entry.record.name) }
        }

        // Codex: the thread config merges over config.toml server by server.
        var codexNames = Set(entries.filter { $0.nativeInLaunch.contains(.codex) }.map(\.record.name))
        var codexServers: [String: Any] = [:]
        for entry in entries where entry.record.scope != .managed {
            // Codex may also read the working repository's .codex/config.toml itself
            // when it trusts the project, so a server there turned off is turned off
            // for the thread too; the override is harmless when it doesn't.
            let codexMayReadItself = entry.nativeInLaunch.contains(.codex)
                || (entry.rootIndex == 0 && entry.record.locations.contains { $0.layout == .codexProject })
            if codexMayReadItself, !entry.record.enabled {
                guard let table = entry.codexTable else { continue }
                // Only what identifies the server, so the merge keeps the rest of the user's definition.
                var off: [String: Any] = ["enabled": false]
                if let command = table["command"] { off["command"] = command } else if let url = table["url"] { off["url"] = url }
                codexServers[entry.record.name] = off
                launch.codexDisabled.append(entry.record.name)
                // The name stays taken, so a server of the same name elsewhere can't turn it back on.
                codexNames.insert(entry.record.name)
                continue
            }
            if entry.nativeInLaunch.contains(.codex) { continue }
            guard usable(entry), let table = entry.codexTable, codexNames.insert(entry.record.name).inserted else { continue }
            codexServers[entry.record.name] = table
            launch.codexShared.append(.init(id: entry.record.id, name: entry.record.name))
        }
        if !codexServers.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: codexServers, options: [.sortedKeys, .withoutEscapingSlashes]) {
            launch.codexServersJSON = String(data: data, encoding: .utf8)
        }
        return launch
    }
}
