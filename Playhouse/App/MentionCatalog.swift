import Foundation

// MARK: - Model

/// What an `@` mention in the composer can name, in the order the mention menu lists them.
enum MentionKind: String, Codable, Sendable, CaseIterable {
    case skill, mcp, agent, repository, task

    /// What a row says it is, and what the menu's section of them is called.
    var title: String {
        switch self {
        case .skill: "Skill"
        case .mcp: "MCP"
        case .agent: "Agent"
        case .repository: "Repository"
        case .task: "Task"
        }
    }

    var sectionTitle: String {
        switch self {
        case .skill: "Skills"
        case .mcp: "MCP servers"
        case .agent: "Agents"
        case .repository: "Repositories"
        case .task: "Tasks"
        }
    }
}

/// One thing the user can mention. `handle` is what follows the `@` in the message, and
/// `reference` is what the agent is told about it when the message is sent.
struct MentionItem: Codable, Equatable, Identifiable, Sendable {
    /// `<kind>:<the item's own catalog ID>`, stable across tasks.
    let id: String
    let kind: MentionKind
    /// Whitespace-free, unique in its catalog.
    let handle: String
    let title: String
    let detail: String
    let reference: String
}

/// Everything a task's composer can mention, ordered skills, MCP servers, agents,
/// repositories, then other tasks, plus the IDs of the most recently sent mentions.
struct MentionCatalog: Codable, Equatable, Sendable {
    static let recentLimit = 10

    let items: [MentionItem]
    /// Most recent first; only IDs this catalog still has.
    let recentIDs: [String]

    var recent: [MentionItem] {
        recentIDs.compactMap { id in items.first { $0.id == id } }
    }

    /// What the menu shows for `query` (the text typed after `@`): the recent mentions,
    /// or every item while nothing was mentioned yet, for an empty query; otherwise the
    /// items whose handle, title or detail contains the query, those whose handle starts
    /// with it first, each group keeping the catalog's kind order.
    func suggestions(query: String) -> [MentionItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty {
            let recent = recent
            return recent.isEmpty ? items : recent
        }
        // One pass, lowering each field at most once: the menu asks on every keystroke.
        var prefixed: [MentionItem] = []
        var containing: [MentionItem] = []
        for item in items {
            let handle = item.handle.lowercased()
            if handle.hasPrefix(needle) {
                prefixed.append(item)
            } else if handle.contains(needle) || item.title.lowercased().contains(needle) || item.detail.lowercased().contains(needle) {
                containing.append(item)
            }
        }
        return prefixed + containing
    }

    /// The items `text` mentions, in order of first mention, each once.
    func mentioned(in text: String) -> [MentionItem] {
        let byHandle = Dictionary(items.map { ($0.handle, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return MentionText.handles(in: text, known: Set(byHandle.keys)).compactMap { match in
            guard seen.insert(match.handle).inserted else { return nil }
            return byHandle[match.handle]
        }
    }
}

/// How mentions live in message text: the `@handle` tokens the user sees, and the context
/// block that tells the agent what each one refers to. The block is part of the sent text,
/// so it survives in the transcript, where the conversation view hides it.
enum MentionText {
    static let contextStart = "<playhouse-mentions>"
    static let contextEnd = "</playhouse-mentions>"
    /// Ends a token that is otherwise a known handle, so `@repo,` still mentions `repo`.
    private static let trailingPunctuation = Set(".,;:!?)]}'\"")

    /// `text` followed by the context block for `items`, or `text` unchanged without any.
    static func expand(_ text: String, mentioning items: [MentionItem]) -> String {
        guard !items.isEmpty else { return text }
        let lines = items.map { "- @\($0.handle) (\($0.kind.title.lowercased())): \($0.reference)" }
        let block = [contextStart,
                     "The user's message mentions these items with @. Each line says what the mention refers to; use it to act on the message.",
                     lines.joined(separator: "\n"),
                     contextEnd].joined(separator: "\n")
        return text + "\n\n" + block
    }

    /// `text` without its context block, as the conversation shows it.
    static func displayText(_ text: String) -> String {
        guard let start = text.range(of: contextStart),
              let end = text.range(of: contextEnd, range: start.upperBound..<text.endIndex) else { return text }
        return (String(text[..<start.lowerBound]) + String(text[end.upperBound...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether two user messages read the same once any context block is set aside, as a typed
    /// message and the copy sent with its block do.
    static func sameUserText(_ lhs: String, _ rhs: String) -> Bool {
        displayText(lhs).trimmingCharacters(in: .whitespacesAndNewlines)
            == displayText(rhs).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The handles `text`'s context block lists, so a sent message colors exactly what it mentioned.
    static func contextHandles(in text: String) -> Set<String> {
        guard let start = text.range(of: contextStart),
              let end = text.range(of: contextEnd, range: start.upperBound..<text.endIndex) else { return [] }
        var handles = Set<String>()
        for line in text[start.upperBound..<end.lowerBound].split(separator: "\n") where line.hasPrefix("- @") {
            let rest = line.dropFirst(3)
            if let space = rest.firstIndex(of: " ") { handles.insert(String(rest[..<space])) }
        }
        return handles
    }

    /// The `@` tokens of `text` that name one of `known`, with their UTF-16 ranges (the `@` included).
    /// A token starts the text or follows whitespace, so an email address never mentions anything.
    static func handles(in text: String, known: Set<String>) -> [(handle: String, range: NSRange)] {
        guard !known.isEmpty else { return [] }
        let utf16 = Array(text.utf16)
        var results: [(handle: String, range: NSRange)] = []
        var index = 0
        while index < utf16.count {
            let isStart = index == 0 || isWhitespace(utf16[index - 1])
            guard utf16[index] == 0x40, isStart else { index += 1; continue }
            var end = index + 1
            while end < utf16.count, !isWhitespace(utf16[end]) { end += 1 }
            var tokenEnd = end
            while tokenEnd > index + 1 {
                let token = String(utf16CodeUnits: Array(utf16[(index + 1)..<tokenEnd]), count: tokenEnd - index - 1)
                if known.contains(token) {
                    results.append((handle: token, range: NSRange(location: index, length: tokenEnd - index)))
                    break
                }
                guard let last = token.last, trailingPunctuation.contains(last) else { break }
                tokenEnd -= String(last).utf16.count
            }
            index = end
        }
        return results
    }

    /// The query of a mention being typed: the text between an `@` that starts a word and
    /// the caret, with the `@`'s UTF-16 location. Nil when the caret is not in such a word.
    static func activeQuery(in text: String, caret: Int) -> (location: Int, query: String)? {
        let utf16 = Array(text.utf16)
        guard caret >= 1, caret <= utf16.count else { return nil }
        var index = caret - 1
        while index >= 0 {
            let unit = utf16[index]
            if unit == 0x40 {
                guard index == 0 || isWhitespace(utf16[index - 1]) else { return nil }
                let query = String(utf16CodeUnits: Array(utf16[(index + 1)..<caret]), count: caret - index - 1)
                return (index, query)
            }
            if isWhitespace(unit) { return nil }
            index -= 1
        }
        return nil
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D || unit == 0xA0
    }
}

// MARK: - Manager

/// Builds a task's mention catalog from the same skill and MCP catalogs the Skills page
/// shows, the agents both providers define, the repositories under the repository root and the
/// other board tasks; expands a sent message's mentions; and remembers the recent ones. The GUI
/// and the CLI reach it through the same bridge command, and every send goes through `expand`.
@MainActor
final class MentionCatalogManager {
    static let recentMentionIDsKey = "recentMentionIDs"

    private let environment: SkillEnvironment
    private let preferences: UserDefaults
    private let skills: SkillCatalogManager
    private let mcp: McpCatalogManager
    private let fileManager = FileManager.default

    init(environment: SkillEnvironment, preferences: UserDefaults, skills: SkillCatalogManager, mcp: McpCatalogManager) {
        self.environment = environment
        self.preferences = preferences
        self.skills = skills
        self.mcp = mcp
    }

    var recentIDs: [String] { preferences.stringArray(forKey: Self.recentMentionIDsKey) ?? [] }

    /// Moves `items` to the front of the recent mentions, keeping the newest ten.
    func recordRecent(_ items: [MentionItem]) {
        guard !items.isEmpty else { return }
        let ids = items.map(\.id)
        let updated = ids + recentIDs.filter { !ids.contains($0) }
        preferences.set(Array(updated.prefix(MentionCatalog.recentLimit)), forKey: Self.recentMentionIDsKey)
    }

    func catalog(for task: any ConversationSubject, tasks: BoardTaskManager, settings: WorkspaceSettingsManager) async -> MentionCatalog {
        let roots = SkillRoot.roots(for: task)
        var items: [MentionItem] = []
        items += skillItems(skills.catalog(roots: roots))
        items += mcpItems(mcp.catalog(roots: roots))
        items += agentItems(roots: roots, provider: task.conversationProvider)
        items += await repositoryItems(task: task, settings: settings)
        items += taskItems(excluding: task.id, tasks: tasks)
        let unique = Self.uniqueHandles(items)
        let known = Set(unique.map(\.id))
        return MentionCatalog(items: unique, recentIDs: recentIDs.filter(known.contains))
    }

    /// `text` with a context block for every item it mentions, which also become the recent mentions.
    func expand(_ text: String, for task: any ConversationSubject, tasks: BoardTaskManager, settings: WorkspaceSettingsManager) async -> String {
        // Most messages mention nothing; skip building the catalog for them.
        guard text.contains("@"), !text.contains(MentionText.contextStart) else { return text }
        let mentioned = await catalog(for: task, tasks: tasks, settings: settings).mentioned(in: text)
        recordRecent(mentioned)
        return MentionText.expand(text, mentioning: mentioned)
    }

    // MARK: Sources

    private func skillItems(_ catalog: SkillCatalog) -> [MentionItem] {
        catalog.allSkills.filter { $0.enabled && !$0.providers.isEmpty }.map { skill in
            let name = skill.invocationName ?? skill.name
            let reference = skill.folderPath.map { "the skill `\(name)`; read `\($0)/SKILL.md` and follow its instructions." }
                ?? "the built-in skill `\(name)`; invoke it as `/\(name)`."
            return MentionItem(id: "skill:" + skill.id, kind: .skill, handle: Self.handle(name), title: name, detail: skill.description, reference: reference)
        }
    }

    private func mcpItems(_ catalog: McpCatalog) -> [MentionItem] {
        catalog.allServers.filter(\.enabled).map { server in
            MentionItem(
                id: "mcp:" + server.id, kind: .mcp, handle: Self.handle(server.name), title: server.name, detail: server.summary,
                reference: "the MCP server `\(server.name)` (\(server.transport.rawValue): \(server.summary)); use the tools it provides."
            )
        }
    }

    /// Claude Code's subagents (`.claude/agents/*.md`) and Codex's agent roles (`.codex/agents/*.toml`),
    /// in the task's repositories and the user's homes. An agent both define is one item naming each file,
    /// the running provider's first.
    private func agentItems(roots: [SkillRoot], provider: ConversationProvider) -> [MentionItem] {
        struct Definition { let provider: ConversationProvider; let name: String; let description: String; let path: String; let scope: String }
        var definitions: [Definition] = []
        func read(_ folder: String, provider: ConversationProvider, scope: String) {
            let entries = ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            for entry in entries where !entry.hasPrefix(".") {
                let path = folder + "/" + entry
                guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let parsed: (name: String?, description: String?)
                switch provider {
                case .claude:
                    guard entry.hasSuffix(".md") else { continue }
                    parsed = Self.frontmatter(contents)
                case .codex:
                    guard entry.hasSuffix(".toml") else { continue }
                    parsed = Self.tomlFields(contents)
                }
                let fallback = URL(fileURLWithPath: entry).deletingPathExtension().lastPathComponent
                definitions.append(Definition(provider: provider, name: parsed.name ?? fallback, description: parsed.description ?? "", path: path, scope: scope))
            }
        }
        for root in roots {
            read(root.path + "/.claude/agents", provider: .claude, scope: root.name)
            read(root.path + "/.codex/agents", provider: .codex, scope: root.name)
        }
        read(environment.claudeConfigDirectory + "/agents", provider: .claude, scope: "global")
        read(environment.codexHome + "/agents", provider: .codex, scope: "global")
        // Codex names roles with underscores where Claude uses dashes; one agent defined for both is one item.
        func key(_ name: String) -> String { name.lowercased().replacingOccurrences(of: "_", with: "-") }
        var order: [String] = []
        var grouped: [String: [Definition]] = [:]
        for definition in definitions {
            let name = key(definition.name)
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(definition)
        }
        return order.map { name in
            let group = grouped[name]!.sorted { ($0.provider == provider ? 0 : 1) < ($1.provider == provider ? 0 : 1) }
            let parts = group.map { definition in
                definition.provider == .claude
                    ? "the Claude Code subagent `\(definition.name)` defined in `\(definition.path)`"
                    : "the Codex agent `\(definition.name)` defined in `\(definition.path)`"
            }
            let first = group[0]
            return MentionItem(
                id: "agent:" + name, kind: .agent, handle: Self.handle(first.name), title: first.name,
                detail: first.description.isEmpty ? first.scope : first.description,
                reference: parts.joined(separator: "; also ") + ". Delegate to it, or read its definition and follow it if you cannot."
            )
        }
    }

    private func repositoryItems(task: any ConversationSubject, settings: WorkspaceSettingsManager) async -> [MentionItem] {
        var paths = task.repositoryWorktrees.map(\.repositoryPath)
        if let root = settings.defaultParentFolderURL {
            paths += await RepositoryScanner.scan(parent: root).map(\.path)
        }
        var seen = Set<String>()
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }.filter { seen.insert($0).inserted }.map { path in
            var reference = "the Git repository at `\(path)`"
            if let worktree = task.repositoryWorktrees.first(where: { URL(fileURLWithPath: $0.repositoryPath).standardizedFileURL.path == path }) {
                reference += "; this task works on it in its worktree `\(worktree.worktreePath)` (branch `\(worktree.branch)`), where its changes belong"
            }
            return MentionItem(
                id: "repository:" + path, kind: .repository, handle: Self.handle(URL(fileURLWithPath: path).lastPathComponent),
                title: URL(fileURLWithPath: path).lastPathComponent, detail: (path as NSString).abbreviatingWithTildeInPath, reference: reference + "."
            )
        }
    }

    private func taskItems(excluding taskID: UUID, tasks: BoardTaskManager) -> [MentionItem] {
        ((try? tasks.list()) ?? []).filter { $0.id != taskID }.sorted { $0.createdAt > $1.createdAt }.map { record in
            var reference = "the Playhouse board task \"\(record.title)\" (ID \(record.id.uuidString), status \(record.status))"
            let worktrees = record.repositoryWorktrees.map { "`\($0.worktreePath)`" }
            if !worktrees.isEmpty { reference += ", whose worktrees are " + worktrees.joined(separator: ", ") }
            return MentionItem(
                id: "task:" + record.id.uuidString, kind: .task, handle: Self.handle(record.title), title: record.title,
                detail: record.status, reference: reference + ". Read it with the Playhouse CLI's `task get \(record.id.uuidString)`."
            )
        }
    }

    // MARK: Helpers

    /// A handle has no whitespace: runs of it become a dash.
    static func handle(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
    }

    /// Keeps the first item of each handle as it is; a later item with the same handle is
    /// prefixed with its kind, and numbered if that is taken too.
    static func uniqueHandles(_ items: [MentionItem]) -> [MentionItem] {
        var taken = Set<String>()
        var ids = Set<String>()
        var result: [MentionItem] = []
        for item in items where !item.handle.isEmpty && ids.insert(item.id).inserted {
            var handle = item.handle
            if taken.contains(handle) { handle = item.kind.rawValue + ":" + item.handle }
            var number = 2
            let base = handle
            while taken.contains(handle) { handle = base + "-\(number)"; number += 1 }
            taken.insert(handle)
            result.append(MentionItem(id: item.id, kind: item.kind, handle: handle, title: item.title, detail: item.detail, reference: item.reference))
        }
        return result
    }

    /// `name` and `description` from a Markdown file's YAML frontmatter.
    static func frontmatter(_ contents: String) -> (name: String?, description: String?) {
        let lines = contents.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            fields[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] = unquoted(String(line[line.index(after: colon)...]))
        }
        return (fields["name"].flatMap { $0.isEmpty ? nil : $0 }, fields["description"])
    }

    /// Top-level `name` and `description` strings of a TOML file.
    static func tomlFields(_ contents: String) -> (name: String?, description: String?) {
        var fields: [String: String] = [:]
        for line in contents.components(separatedBy: "\n") {
            if line.hasPrefix("[") { break }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard key == "name" || key == "description", fields[key] == nil else { continue }
            fields[key] = unquoted(String(line[line.index(after: equals)...]))
        }
        return (fields["name"].flatMap { $0.isEmpty ? nil : $0 }, fields["description"])
    }

    private static func unquoted(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, let first = trimmed.first, first == "\"" || first == "'", trimmed.last == first else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }
}
