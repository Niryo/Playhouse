import Foundation

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
