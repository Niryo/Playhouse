import CryptoKit
import Foundation

// MARK: - Model

/// Where a skill folder lives. Both providers read the same `SKILL.md` format,
/// but each looks in its own folders: Codex reads the open Agent Skills layout
/// (`.agents/skills`), Claude Code reads `.claude/skills`. Playhouse treats every
/// folder as one gallery and bridges each skill to the provider that would not
/// otherwise see it.
enum SkillLayout: String, Codable, Sendable {
    /// `<repo>/.agents/skills` or `~/.agents/skills`, read natively by Codex.
    case agents
    /// `<repo>/.claude/skills` or `<claude config>/skills`, read natively by Claude Code.
    case claude
    /// `$CODEX_HOME/skills`, Codex's legacy user folder.
    case codexLegacy
    /// `$CODEX_HOME/skills/.system`, skills bundled with Codex.
    case codexSystem
    /// `<claude config>/skills/synced/*`, skills claude.ai syncs into Claude Code.
    case claudeSynced
    /// Built into the Claude Code binary, with no folder on disk.
    case claudeBundled

    var displayPath: String {
        switch self {
        case .agents: ".agents/skills"
        case .claude: ".claude/skills"
        case .codexLegacy: "Codex skills"
        case .codexSystem: "Codex built-in"
        case .claudeSynced: "claude.ai synced"
        case .claudeBundled: "Claude Code built-in"
        }
    }
}

enum SkillScope: String, Codable, Sendable, CaseIterable {
    case repo
    case global
    case builtin
}

struct SkillLocation: Codable, Equatable, Sendable {
    /// The skill folder as found, which can be a symlink.
    let path: String
    let layout: SkillLayout
    let isSymlink: Bool
}

struct SkillRecord: Codable, Equatable, Identifiable, Sendable {
    /// Stable across tasks: a repo skill is keyed by its source repository, not
    /// the task worktree, so its enabled state follows the repository.
    let id: String
    let name: String
    let description: String
    let scope: SkillScope
    let repositoryPath: String?
    /// The task root the repo skill was read from.
    let rootPath: String?
    /// The resolved skill folder that edits, moves, and deletes act on.
    let folderPath: String?
    let locations: [SkillLocation]
    /// Providers that can use the skill in sessions Playhouse launches.
    let providers: [ConversationProvider]
    let enabled: Bool
    let editable: Bool
    /// Both providers read the skill natively, so it also works outside Playhouse.
    let availableOutsidePlayhouse: Bool
    let conflict: Bool
    let issue: String?
}

struct SkillRepositorySection: Codable, Equatable, Sendable {
    let repositoryPath: String
    let rootPath: String
    let name: String
    let skills: [SkillRecord]
}

struct SkillCatalog: Codable, Equatable, Sendable {
    let repositories: [SkillRepositorySection]
    let global: [SkillRecord]
    let builtin: [SkillRecord]

    var allSkills: [SkillRecord] { repositories.flatMap(\.skills) + global + builtin }
    func skill(id: String) -> SkillRecord? { allSkills.first { $0.id == id } }

    /// The same catalog with one skill's record swapped for a newer one.
    func replacing(_ record: SkillRecord) -> SkillCatalog {
        func swap(_ skills: [SkillRecord]) -> [SkillRecord] { skills.map { $0.id == record.id ? record : $0 } }
        return SkillCatalog(
            repositories: repositories.map {
                SkillRepositorySection(repositoryPath: $0.repositoryPath, rootPath: $0.rootPath, name: $0.name, skills: swap($0.skills))
            },
            global: swap(global),
            builtin: swap(builtin)
        )
    }
}

/// The task Playhouse opens so an agent can repair broken skills.
struct SkillFixPlan: Equatable, Sendable {
    let title: String
    let prompt: String
    /// Source repositories whose skills the task fixes in its own worktrees.
    let repositoryPaths: [String]
    /// Global skill folders the agent edits in place.
    let contextFolders: [String]
}

/// A skill a message invokes, so a provider without slash commands can be
/// handed the skill directly.
struct SkillInvocation: Codable, Equatable, Sendable {
    let name: String
    let path: String
}

/// What a provider launch needs so it sees every skill in the gallery. Claude
/// Code runs one process per turn, so its part is exact per launch. Codex shares
/// one app-server across tasks, so its extra roots are the union of every
/// task's bridge folder and each thread hides the folders that are not its own.
struct SkillBridgeLaunch: Codable, Equatable, Sendable {
    struct BridgedSkill: Codable, Equatable, Sendable {
        let name: String
        let source: String
        let link: String
    }

    var claudeAddDirectories: [String] = []
    var claudeDisabledSkillNames: [String] = []
    var claudeLinks: [BridgedSkill] = []
    var codexExtraRoots: [String] = []
    var codexDisabledSkillPaths: [String] = []
    var codexLinks: [BridgedSkill] = []
    var invocations: [SkillInvocation] = []

    /// `--settings` JSON that hides disabled skills from Claude Code for this run only.
    var claudeSettingsJSON: String? {
        guard !claudeDisabledSkillNames.isEmpty else { return nil }
        let overrides = Dictionary(uniqueKeysWithValues: claudeDisabledSkillNames.map { ($0, "off") })
        guard let data = try? JSONSerialization.data(withJSONObject: ["skillOverrides": overrides], options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Per-thread Codex config that hides disabled and other tasks' bridged skills
    /// without writing to the user's `config.toml`.
    var codexThreadConfig: [String: Any]? {
        guard !codexDisabledSkillPaths.isEmpty else { return nil }
        return ["skills": ["config": codexDisabledSkillPaths.map { ["path": $0, "enabled": false] }]]
    }
}

/// The folders a skill gallery reads. Production uses the user's own homes;
/// debug bridge tests point every one at isolated fixtures.
struct SkillEnvironment: Equatable, Sendable {
    /// The folder whose `.agents/skills` holds global skills.
    var homeDirectory: String
    var claudeConfigDirectory: String
    var codexHome: String
    /// Playhouse-owned folder for bridge wrappers.
    var bridgeDirectory: String

    static func resolve(
        homeOverride: String? = nil,
        claudeConfigOverride: String? = nil,
        codexHomeOverride: String? = nil,
        storeDirectory: String?
    ) -> SkillEnvironment {
        let environment = PlayhouseProcessEnvironment.current
        let home = homeOverride ?? environment["HOME"] ?? NSHomeDirectory()
        let claude = claudeConfigOverride
            ?? (homeOverride.map { $0 + "/.claude" })
            ?? environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home + "/.claude"
        let codex = codexHomeOverride
            ?? (homeOverride.map { $0 + "/.codex" })
            ?? environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home + "/.codex"
        // Beside the store, where task worktrees and other Playhouse data live.
        let data = storeDirectory
            ?? PlayhouseProcessEnvironment.current["PLAYHOUSE_DATA_DIRECTORY"]
            ?? (try? PlayhouseAppIdentity.defaultDataDirectory().path)
            ?? home + "/.playhouse"
        return SkillEnvironment(
            homeDirectory: home,
            claudeConfigDirectory: claude,
            codexHome: codex,
            bridgeDirectory: URL(fileURLWithPath: data).appendingPathComponent("skill-bridge").path
        )
    }
}

/// One task root, with the source repository that identifies its skills.
struct SkillRoot: Equatable, Sendable {
    let path: String
    let repositoryPath: String

    var name: String { URL(fileURLWithPath: repositoryPath).lastPathComponent }

    static func roots(for task: any ConversationSubject) -> [SkillRoot] {
        let worktrees = task.repositoryWorktrees
        let paths = task.workspaceRootPaths.isEmpty && task.status == .done
            ? worktrees.map(\.repositoryPath)
            : task.workspaceRootPaths
        return paths.map { path in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            let repository = worktrees.first {
                URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path == standardized
                    || URL(fileURLWithPath: $0.repositoryPath).standardizedFileURL.path == standardized
            }?.repositoryPath ?? standardized
            return SkillRoot(path: standardized, repositoryPath: URL(fileURLWithPath: repository).standardizedFileURL.path)
        }
    }
}

// MARK: - Manager

/// Reads and manages the skill gallery shared by both providers. The GUI and
/// the CLI reach it through the same bridge commands.
@MainActor
final class SkillCatalogManager {
    static let disabledSkillsKey = "disabledSkillIDs"
    private static let bridgeMarker = ".playhouse-skill-bridge"
    private static let bridgeMarkerContents = "Playhouse owns this skill bridge folder (v1).\n"
    /// Wrappers unused this long are removed; any newer one may still back a loaded Codex thread.
    private static let bridgeRetention: TimeInterval = 14 * 24 * 60 * 60

    private let environment: SkillEnvironment
    private let preferences: UserDefaults
    private let fileManager = FileManager.default

    init(environment: SkillEnvironment, preferences: UserDefaults) {
        self.environment = environment
        self.preferences = preferences
    }

    // MARK: Reading

    private struct ScannedSkill {
        let name: String
        let description: String
        let path: String
        let realPath: String
        let layout: SkillLayout
        let isSymlink: Bool
        let issue: String?
    }

    var disabledSkillIDs: Set<String> {
        Set(preferences.stringArray(forKey: Self.disabledSkillsKey) ?? [])
    }

    /// The gallery for a task's roots. `bundledClaudeSkills` are the names
    /// Claude Code reports as built in; they have no folder to scan.
    func catalog(roots: [SkillRoot], bundledClaudeSkills: [(name: String, description: String)] = []) -> SkillCatalog {
        let disabled = disabledSkillIDs
        let sections = roots.map { root in
            let scanned = scan(root.path + "/.agents/skills", layout: .agents)
                + scan(root.path + "/.claude/skills", layout: .claude)
            return SkillRepositorySection(
                repositoryPath: root.repositoryPath,
                rootPath: root.path,
                name: root.name,
                skills: records(scanned, scope: .repo, root: root, disabled: disabled)
            )
        }
        let global = records(globalSkills(), scope: .global, root: nil, disabled: disabled)
        var builtin = records(builtinSkills(), scope: .builtin, root: nil, disabled: disabled)
        let fileBacked = Set(builtin.map(\.name))
        for bundled in bundledClaudeSkills where !fileBacked.contains(bundled.name) {
            let id = Self.builtinID(provider: .claude, name: bundled.name)
            builtin.append(SkillRecord(
                id: id, name: bundled.name, description: bundled.description, scope: .builtin,
                repositoryPath: nil, rootPath: nil, folderPath: nil,
                locations: [SkillLocation(path: "", layout: .claudeBundled, isSymlink: false)],
                providers: [.claude], enabled: !disabled.contains(id), editable: false,
                availableOutsidePlayhouse: false, conflict: false, issue: nil
            ))
        }
        builtin.sort { ($0.name, $0.id) < ($1.name, $1.id) }
        return SkillCatalog(repositories: sections, global: global, builtin: builtin)
    }

    private func globalSkills() -> [ScannedSkill] {
        scan(environment.homeDirectory + "/.agents/skills", layout: .agents)
            + scan(environment.claudeConfigDirectory + "/skills", layout: .claude, excluding: ["synced"])
            + scan(environment.codexHome + "/skills", layout: .codexLegacy)
    }

    private func builtinSkills() -> [ScannedSkill] {
        var skills = scan(environment.codexHome + "/skills/.system", layout: .codexSystem)
        let synced = URL(fileURLWithPath: environment.claudeConfigDirectory + "/skills/synced")
        let buckets = (try? fileManager.contentsOfDirectory(atPath: synced.path))?.sorted() ?? []
        var seen = Set<String>()
        for bucket in buckets where !bucket.hasPrefix(".") {
            for skill in scan(synced.appendingPathComponent(bucket).path, layout: .claudeSynced) where seen.insert(skill.name).inserted {
                skills.append(skill)
            }
        }
        return skills
    }

    private func scan(_ directory: String, layout: SkillLayout, excluding: Set<String> = []) -> [ScannedSkill] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        return entries.sorted().compactMap { entry in
            guard !entry.hasPrefix("."), !excluding.contains(entry) else { return nil }
            let path = directory + "/" + entry
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let manifest = resolved + "/SKILL.md"
            guard let contents = try? String(contentsOfFile: manifest, encoding: .utf8) else { return nil }
            let isSymlink = (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
            let frontmatter = SkillFrontmatter(contents)
            var issue = frontmatter.issue
            let name = frontmatter.name ?? entry
            if issue == nil, name != entry {
                issue = "The skill's name \"\(name)\" does not match its folder \"\(entry)\"."
            }
            return ScannedSkill(
                name: name, description: frontmatter.description ?? "", path: path, realPath: resolved,
                layout: layout, isSymlink: isSymlink, issue: issue
            )
        }
    }

    private func records(_ scanned: [ScannedSkill], scope: SkillScope, root: SkillRoot?, disabled: Set<String>) -> [SkillRecord] {
        var order: [String] = []
        var groups: [String: [ScannedSkill]] = [:]
        for skill in scanned {
            if groups[skill.name] == nil { order.append(skill.name) }
            groups[skill.name, default: []].append(skill)
        }
        return order.sorted().map { name in
            let group = groups[name] ?? []
            let primary = group.first { !$0.isSymlink } ?? group[0]
            let distinctFolders = Set(group.map(\.realPath))
            let conflict = distinctFolders.count > 1
            let id: String
            let providers: [ConversationProvider]
            switch scope {
            case .repo: id = Self.repoID(repositoryPath: root?.repositoryPath ?? "", name: name)
            case .global: id = Self.globalID(name: name)
            case .builtin: id = Self.builtinID(provider: primary.layout == .codexSystem ? .codex : .claude, name: name)
            }
            switch scope {
            case .builtin: providers = [primary.layout == .codexSystem ? .codex : .claude]
            default: providers = primary.issue == nil ? [.claude, .codex] : []
            }
            let layouts = Set(group.map(\.layout))
            let issue = primary.issue ?? (conflict
                ? "Different skills named \"\(name)\" are in \(group.map(\.layout.displayPath).joined(separator: " and ")). Each provider keeps its own copy until you remove or rename one."
                : nil)
            return SkillRecord(
                id: id, name: name, description: primary.description, scope: scope,
                repositoryPath: root?.repositoryPath, rootPath: root?.path, folderPath: primary.realPath,
                locations: group.map { SkillLocation(path: $0.path, layout: $0.layout, isSymlink: $0.isSymlink) },
                providers: providers, enabled: !disabled.contains(id), editable: scope != .builtin,
                availableOutsidePlayhouse: !conflict && layouts.contains(.agents) && layouts.contains(.claude),
                conflict: conflict, issue: issue
            )
        }
    }

    static func globalID(name: String) -> String { "global:\(name)" }
    static func repoID(repositoryPath: String, name: String) -> String { "repo:\(repositoryPath)#\(name)" }
    static func builtinID(provider: ConversationProvider, name: String) -> String { "builtin:\(provider.rawValue):\(name)" }

    func content(id: String, roots: [SkillRoot]) throws -> String {
        let record = try existing(id: id, roots: roots)
        guard let folder = record.folderPath else {
            throw BridgeCommandError(code: "invalid_argument", message: "\(record.name) is built into Claude Code and has no file to show.")
        }
        return try String(contentsOfFile: folder + "/SKILL.md", encoding: .utf8)
    }

    // MARK: Managing

    static func validate(name: String) throws {
        let valid = name.count <= 64
            && name.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil
        guard valid else {
            throw BridgeCommandError(
                code: "invalid_argument",
                message: "A skill name uses lowercase letters, digits, and single hyphens, up to 64 characters."
            )
        }
    }

    static func manifest(name: String, description: String, body: String, fields: [String: String] = [:]) -> String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return SkillManifest(
            name: name, description: description, fields: fields,
            body: trimmedBody.isEmpty ? "Describe when and how to use this skill." : trimmedBody
        ).contents
    }

    private static func validate(description: String) throws {
        let summary = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Describe when the skill should be used.")
        }
        guard summary.count <= 1024 else {
            throw BridgeCommandError(code: "invalid_argument", message: "A skill description is at most 1024 characters.")
        }
    }

    private static func validate(fields: [String: String]) throws {
        if let unknown = fields.keys.sorted().first(where: { !SkillManifest.optionalKeys.contains($0) }) {
            throw BridgeCommandError(
                code: "invalid_argument",
                message: "\(unknown) is not a skill field Playhouse edits. Use \(SkillManifest.optionalKeys.joined(separator: ", "))."
            )
        }
    }

    /// Writes a new skill in the open Agent Skills layout, which both providers then see.
    func create(name: String, description: String, body: String, fields: [String: String] = [:], scope: SkillScope, root: SkillRoot?, roots: [SkillRoot]) throws -> SkillRecord {
        try Self.validate(name: name)
        try Self.validate(description: description)
        try Self.validate(fields: fields)
        let summary = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = try agentsFolder(scope: scope, root: root)
        let current = catalog(roots: roots)
        let taken = scope == .global ? current.global : current.repositories.first { $0.rootPath == root?.path }?.skills ?? []
        guard !taken.contains(where: { $0.name == name }), !fileManager.fileExists(atPath: base + "/" + name) else {
            throw BridgeCommandError(code: "already_exists", message: "A skill named \(name) already exists here.")
        }
        try fileManager.createDirectory(atPath: base + "/" + name, withIntermediateDirectories: true)
        try Data(Self.manifest(name: name, description: summary, body: body, fields: fields).utf8)
            .write(to: URL(fileURLWithPath: base + "/" + name + "/SKILL.md"), options: .atomic)
        PlayhouseDiagnostics.record("skills.created", fields: ["scope": scope.rawValue, "name": name])
        return try existing(id: scope == .global ? Self.globalID(name: name) : Self.repoID(repositoryPath: root?.repositoryPath ?? "", name: name), roots: roots)
    }

    func update(id: String, content: String, roots: [SkillRoot]) throws -> SkillRecord {
        let record = try editable(id: id, roots: roots)
        let frontmatter = SkillFrontmatter(content)
        if let issue = frontmatter.issue {
            throw BridgeCommandError(code: "invalid_argument", message: issue)
        }
        guard frontmatter.name == record.name else {
            throw BridgeCommandError(
                code: "invalid_argument",
                message: "The skill's name must stay \"\(record.name)\". Create a new skill to use another name."
            )
        }
        guard !(frontmatter.description ?? "").isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Describe when the skill should be used.")
        }
        try Data(content.utf8).write(to: URL(fileURLWithPath: record.folderPath! + "/SKILL.md"), options: .atomic)
        PlayhouseDiagnostics.record("skills.updated", fields: ["name": record.name])
        return try existing(id: id, roots: roots)
    }

    /// The skill's SKILL.md split into its header fields and its instructions.
    /// A file without frontmatter keeps its whole text as the instructions, so
    /// saving it from the editor writes the frontmatter it was missing.
    func manifest(id: String, roots: [SkillRoot]) throws -> SkillManifest {
        let record = try existing(id: id, roots: roots)
        return SkillManifest(parsing: try content(id: id, roots: roots), fallbackName: record.name)
    }

    /// Edits a skill's description, header fields, or instructions while
    /// keeping its name and any frontmatter Playhouse does not edit.
    /// A field set to an empty string is removed.
    func update(id: String, description: String?, body: String?, fields: [String: String], roots: [SkillRoot]) throws -> SkillRecord {
        try Self.validate(fields: fields)
        var manifest = try manifest(id: id, roots: roots)
        if let description {
            try Self.validate(description: description)
            manifest.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let body { manifest.body = body }
        for (key, value) in fields {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            manifest.fields[key] = trimmed.isEmpty ? nil : trimmed
        }
        return try update(id: id, content: manifest.contents, roots: roots)
    }

    /// Removes each skill folder and every link to it that Playhouse can verify.
    /// Every skill is checked before any is removed, so one read-only or
    /// missing skill deletes nothing.
    func delete(ids: [String], roots: [SkillRoot]) throws {
        guard !ids.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose at least one skill to delete.")
        }
        let records = try Array(Set(ids)).sorted().map { try editable(id: $0, roots: roots) }
        var disabled = disabledSkillIDs
        // Forget the off state of every skill removed, even if a later one fails.
        defer { preferences.set(Array(disabled).sorted(), forKey: Self.disabledSkillsKey) }
        for record in records {
            for location in record.locations where location.isSymlink {
                try removeVerifiedLink(location.path, to: record.folderPath!)
            }
            try fileManager.removeItem(atPath: record.folderPath!)
            disabled.remove(record.id)
            PlayhouseDiagnostics.record("skills.deleted", fields: ["name": record.name])
        }
    }

    /// What a task needs so an agent can repair conflicting or invalid skills:
    /// repository skills are fixed in the new task's own worktree and go through
    /// its commit, push, and review like any code change; global skills are not
    /// tracked by Git, so the agent edits them in place.
    func fixPlan(ids: [String], roots: [SkillRoot]) throws -> SkillFixPlan {
        guard !ids.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose at least one skill to fix.")
        }
        var seen = Set<String>()
        let records = try ids.filter { seen.insert($0).inserted }.map { id in
            let record = try editable(id: id, roots: roots)
            guard record.conflict || record.issue != nil else {
                throw BridgeCommandError(code: "invalid_argument", message: "\(record.name) has no conflict or problem to fix.")
            }
            return record
        }
        let repoSkills = records.filter { $0.scope == .repo }
        let globalSkills = records.filter { $0.scope == .global }
        func problem(_ record: SkillRecord) -> String { record.issue ?? "The skill is not valid." }

        var lines = [
            "Fix the following agent skills so each one is valid and has exactly one definition that both Claude Code and Codex use.",
            "",
            "How skills work:",
            "- A skill is a folder named after the skill that holds a SKILL.md file.",
            "- SKILL.md starts with YAML frontmatter between --- lines. It sets `name` (lowercase letters, digits, and single hyphens, matching the folder name) and `description` (when an agent should use the skill), followed by the skill's instructions.",
            "- Codex reads `.agents/skills` and Claude Code reads `.claude/skills`, in a repository and in the home folder. A skill for both lives in `.agents/skills`; `.claude/skills` may hold a relative symlink to it.",
            "- A conflict means two different folders define a skill with the same name. Compare them and merge them into one skill in `.agents/skills`, keeping the most complete instructions, then remove the other copy or replace it with a symlink to the merged one. If they are really different skills, rename one of them (its folder and its `name`).",
            "- An invalid skill is missing its frontmatter, `name`, or `description`, or its `name` does not match its folder. Fix the SKILL.md so it is valid.",
        ]
        if !repoSkills.isEmpty {
            lines += [
                "",
                "Repository skills. These are committed to Git: fix them in this task's worktree like any other code change, then commit and push so the fix goes through review. Paths are relative to the repository root.",
            ]
            for record in repoSkills {
                let repository = URL(fileURLWithPath: record.repositoryPath ?? "").lastPathComponent
                let paths = record.locations.map { Self.relativePath(of: $0.path, inside: record.rootPath ?? "") }
                lines.append("- `\(record.name)` in \(repository): \(paths.map { "`\($0)`" }.joined(separator: ", ")). Problem: \(problem(record))")
            }
        }
        if !globalSkills.isEmpty {
            lines += [
                "",
                "Global skills. These live in the user's home folder and are not tracked by Git: fix them directly in place. There is nothing to commit or push for them, and the fix takes effect immediately.",
            ]
            for record in globalSkills {
                lines.append("- `\(record.name)`: \(record.locations.map { "`\($0.path)`" }.joined(separator: ", ")). Problem: \(problem(record))")
            }
        }
        lines += ["", "When you are done, list each skill and what you changed."]

        let names = records.map(\.name)
        let title = names.count == 1 ? "Fix skill \(names[0])" : names.count <= 3
            ? "Fix skills \(names.joined(separator: ", "))"
            : "Fix \(names.count) skills"
        var repositories: [String] = []
        for record in repoSkills {
            if let path = record.repositoryPath, !repositories.contains(path) { repositories.append(path) }
        }
        var folders: [String] = []
        for record in globalSkills {
            for location in record.locations {
                let folder = (location.path as NSString).deletingLastPathComponent
                if !folders.contains(folder) { folders.append(folder) }
            }
        }
        PlayhouseDiagnostics.record("skills.fix.planned", fields: [
            "skillCount": String(records.count), "repositoryCount": String(repositories.count), "globalCount": String(globalSkills.count),
        ])
        return SkillFixPlan(title: title, prompt: lines.joined(separator: "\n"), repositoryPaths: repositories, contextFolders: folders)
    }

    private static func relativePath(of path: String, inside root: String) -> String {
        let prefix = URL(fileURLWithPath: root).standardizedFileURL.path + "/"
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.hasPrefix(prefix) ? String(standardized.dropFirst(prefix.count)) : standardized
    }

    /// Moves a skill between a repository and the global gallery, into the
    /// Agent Skills layout, keeping its enabled state.
    func move(id: String, to scope: SkillScope, root: SkillRoot?, roots: [SkillRoot]) throws -> SkillRecord {
        let record = try editable(id: id, roots: roots)
        guard scope != .builtin else {
            throw BridgeCommandError(code: "invalid_argument", message: "A skill can move to a repository or to the global gallery.")
        }
        let base = try agentsFolder(scope: scope, root: root)
        let target = base + "/" + record.name
        guard URL(fileURLWithPath: target).standardizedFileURL.path != record.folderPath else {
            throw BridgeCommandError(code: "invalid_argument", message: "\(record.name) is already there.")
        }
        let current = catalog(roots: roots)
        let taken = scope == .global ? current.global : current.repositories.first { $0.rootPath == root?.path }?.skills ?? []
        guard !taken.contains(where: { $0.name == record.name }), !fileManager.fileExists(atPath: target) else {
            throw BridgeCommandError(code: "already_exists", message: "A skill named \(record.name) already exists there.")
        }
        for location in record.locations where location.isSymlink {
            try removeVerifiedLink(location.path, to: record.folderPath!)
        }
        try fileManager.createDirectory(atPath: base, withIntermediateDirectories: true)
        try fileManager.moveItem(atPath: record.folderPath!, toPath: target)
        let newID = scope == .global ? Self.globalID(name: record.name) : Self.repoID(repositoryPath: root?.repositoryPath ?? "", name: record.name)
        var disabled = disabledSkillIDs
        if disabled.remove(id) != nil {
            disabled.insert(newID)
            preferences.set(Array(disabled).sorted(), forKey: Self.disabledSkillsKey)
        }
        PlayhouseDiagnostics.record("skills.moved", fields: ["name": record.name, "scope": scope.rawValue])
        return try existing(id: newID, roots: roots)
    }

    /// Claude Code's own built-ins are known only from a provider session, so
    /// `bundledClaudeSkills` is asked for only when the ID names one of them.
    /// Every other skill is found on disk, which keeps a toggle instant.
    func setEnabled(
        id: String, enabled: Bool, roots: [SkillRoot],
        bundledClaudeSkills: () async -> [(name: String, description: String)] = { [] }
    ) async throws -> SkillRecord {
        var bundled: [(name: String, description: String)] = []
        if catalog(roots: roots).skill(id: id) == nil, id.hasPrefix(Self.builtinID(provider: .claude, name: "")) {
            bundled = await bundledClaudeSkills()
        }
        guard catalog(roots: roots, bundledClaudeSkills: bundled).skill(id: id) != nil else {
            throw BridgeCommandError(code: "not_found", message: "No skill matches \(id).")
        }
        var disabled = disabledSkillIDs
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        preferences.set(Array(disabled).sorted(), forKey: Self.disabledSkillsKey)
        PlayhouseDiagnostics.record("skills.enabled.changed", fields: ["id": id, "enabled": String(enabled)])
        return catalog(roots: roots, bundledClaudeSkills: bundled).skill(id: id)!
    }

    /// Writes a real symlink so the provider that does not read the skill's
    /// folder natively finds it outside Playhouse too.
    func link(id: String, roots: [SkillRoot]) throws -> SkillRecord {
        let record = try editable(id: id, roots: roots)
        guard !record.conflict else {
            throw BridgeCommandError(code: "invalid_argument", message: record.issue ?? "Resolve the conflict first.")
        }
        guard !record.availableOutsidePlayhouse else { return record }
        let target = try mirrorPath(for: record)
        if fileManager.fileExists(atPath: target) || (try? fileManager.destinationOfSymbolicLink(atPath: target)) != nil {
            throw BridgeCommandError(code: "already_exists", message: "\(target) already exists, so Playhouse left it unchanged.")
        }
        try fileManager.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let destination = record.scope == .repo
            ? Self.relativePath(from: (target as NSString).deletingLastPathComponent, to: record.folderPath!)
            : record.folderPath!
        try fileManager.createSymbolicLink(atPath: target, withDestinationPath: destination)
        PlayhouseDiagnostics.record("skills.linked", fields: ["name": record.name, "link": target])
        return try existing(id: id, roots: roots)
    }

    func unlink(id: String, roots: [SkillRoot]) throws -> SkillRecord {
        let record = try editable(id: id, roots: roots)
        let links = record.locations.filter(\.isSymlink)
        guard !links.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "\(record.name) has no link that Playhouse can remove.")
        }
        for link in links { try removeVerifiedLink(link.path, to: record.folderPath!) }
        PlayhouseDiagnostics.record("skills.unlinked", fields: ["name": record.name])
        return try existing(id: id, roots: roots)
    }

    private func existing(id: String, roots: [SkillRoot]) throws -> SkillRecord {
        guard let record = catalog(roots: roots).skill(id: id) else {
            throw BridgeCommandError(code: "not_found", message: "No skill matches \(id).")
        }
        return record
    }

    private func editable(id: String, roots: [SkillRoot]) throws -> SkillRecord {
        let record = try existing(id: id, roots: roots)
        guard record.editable, record.folderPath != nil else {
            throw BridgeCommandError(code: "invalid_argument", message: "\(record.name) comes with its provider and is read-only.")
        }
        return record
    }

    private func agentsFolder(scope: SkillScope, root: SkillRoot?) throws -> String {
        switch scope {
        case .global:
            return environment.homeDirectory + "/.agents/skills"
        case .repo:
            guard let root else {
                throw BridgeCommandError(code: "invalid_argument", message: "Choose one of the task's repositories for a repository skill.")
            }
            return root.path + "/.agents/skills"
        case .builtin:
            throw BridgeCommandError(code: "invalid_argument", message: "Built-in skills come with their provider.")
        }
    }

    private func mirrorPath(for record: SkillRecord) throws -> String {
        let real = record.locations.first { !$0.isSymlink } ?? record.locations[0]
        let base: String
        switch (record.scope, real.layout) {
        case (.repo, .agents): base = record.rootPath! + "/.claude/skills"
        case (.repo, _): base = record.rootPath! + "/.agents/skills"
        case (.global, .agents): base = environment.claudeConfigDirectory + "/skills"
        case (.global, _): base = environment.homeDirectory + "/.agents/skills"
        default: throw BridgeCommandError(code: "invalid_argument", message: "Built-in skills come with their provider.")
        }
        return base + "/" + record.name
    }

    private func removeVerifiedLink(_ path: String, to folder: String) throws {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == folder else {
            throw BridgeCommandError(code: "invalid_argument", message: "\(path) is not a link to this skill, so Playhouse left it unchanged.")
        }
        try fileManager.removeItem(atPath: path)
    }

    static func relativePath(from directory: String, to target: String) -> String {
        let from = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let to = URL(fileURLWithPath: target).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var common = 0
        while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
        let ups = Array(repeating: "..", count: from.count - common)
        return (ups + to[common...]).joined(separator: "/")
    }

    // MARK: Bridge

    /// Builds the wrapper folders that let each provider see the skills it does
    /// not read natively, and returns what its launch must pass.
    func bridge(roots: [SkillRoot]) -> SkillBridgeLaunch {
        let catalog = catalog(roots: roots)
        var launch = SkillBridgeLaunch()

        func usable(_ record: SkillRecord) -> Bool {
            record.enabled && !record.conflict && record.issue == nil && record.folderPath != nil
        }
        func sources(_ record: SkillRecord, _ layouts: Set<SkillLayout>) -> Bool {
            record.locations.contains { layouts.contains($0.layout) }
        }
        let repoRecords = catalog.repositories.flatMap { section in section.skills.map { (section.rootPath, $0) } }
        let firstRoot = roots.first?.path

        // Claude Code reads every root's `.claude/skills` (the cwd and each --add-dir).
        var claudeNames = Set<String>()
        for (_, record) in repoRecords where sources(record, [.claude]) { claudeNames.insert(record.name) }
        for record in catalog.global where sources(record, [.claude]) { claudeNames.insert(record.name) }
        for record in catalog.builtin where record.providers == [.claude] { claudeNames.insert(record.name) }
        var claudeLinks: [(String, String)] = []
        for record in repoRecords.map(\.1) + catalog.global where usable(record) && !claudeNames.contains(record.name) {
            claudeNames.insert(record.name)
            claudeLinks.append((record.name, record.folderPath!))
        }

        // Codex reads only the cwd repository's `.agents/skills` and its own user folders.
        var codexNames = Set<String>()
        for (root, record) in repoRecords where root == firstRoot && sources(record, [.agents]) { codexNames.insert(record.name) }
        for record in catalog.global where sources(record, [.agents, .codexLegacy]) { codexNames.insert(record.name) }
        for record in catalog.builtin where record.providers == [.codex] { codexNames.insert(record.name) }
        var codexLinks: [(String, String)] = []
        for record in repoRecords.map(\.1) + catalog.global where usable(record) && !codexNames.contains(record.name) {
            codexNames.insert(record.name)
            codexLinks.append((record.name, record.folderPath!))
        }

        for record in catalog.allSkills where !record.enabled {
            if record.scope != .builtin || record.providers.contains(.claude) { launch.claudeDisabledSkillNames.append(record.name) }
            for location in record.locations where !location.path.isEmpty && [.agents, .codexLegacy, .codexSystem].contains(location.layout) {
                launch.codexDisabledSkillPaths.append(location.path + "/SKILL.md")
            }
        }
        // Claude Code's own built-ins have no folder to scan, so they are known
        // here only by the IDs a user turned off.
        let bundledPrefix = Self.builtinID(provider: .claude, name: "")
        for id in disabledSkillIDs where id.hasPrefix(bundledPrefix) {
            launch.claudeDisabledSkillNames.append(String(id.dropFirst(bundledPrefix.count)))
        }
        launch.claudeDisabledSkillNames = Array(Set(launch.claudeDisabledSkillNames)).sorted()

        prepareBridgeDirectory()
        if let wrapper = wrapper(kind: "claude", links: claudeLinks, skillsSubpath: ".claude/skills") {
            launch.claudeAddDirectories = [wrapper.root]
            launch.claudeLinks = wrapper.links
        }
        let ownCodexWrapper = wrapper(kind: "codex", links: codexLinks, skillsSubpath: nil)
        launch.codexLinks = ownCodexWrapper?.links ?? []
        let codexWrappers = existingWrappers(kind: "codex")
        launch.codexExtraRoots = codexWrappers
        for other in codexWrappers where other != ownCodexWrapper?.root {
            for entry in ((try? fileManager.contentsOfDirectory(atPath: other)) ?? []).sorted() where !entry.hasPrefix(".") {
                launch.codexDisabledSkillPaths.append(other + "/" + entry + "/SKILL.md")
            }
        }
        launch.codexDisabledSkillPaths = Array(Set(launch.codexDisabledSkillPaths)).sorted()
        return launch
    }

    /// Finds skills a message names as `/skill-name`, so Codex, which has no
    /// slash commands, can be handed each skill as a structured input.
    func invocations(in text: String, roots: [SkillRoot]) -> [SkillInvocation] {
        let pattern = #"(?:^|\s)/([a-z0-9]+(?:-[a-z0-9]+)*)(?=\s|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let names = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
        guard !names.isEmpty else { return [] }
        let catalog = catalog(roots: roots)
        var seen = Set<String>()
        return names.compactMap { name in
            guard seen.insert(name).inserted,
                  let record = catalog.allSkills.first(where: { $0.name == name && $0.enabled && $0.providers.contains(.codex) && $0.folderPath != nil })
            else { return nil }
            return SkillInvocation(name: name, path: record.folderPath! + "/SKILL.md")
        }
    }

    private func prepareBridgeDirectory() {
        let marker = environment.bridgeDirectory + "/" + Self.bridgeMarker
        if !fileManager.fileExists(atPath: marker) {
            try? fileManager.createDirectory(atPath: environment.bridgeDirectory, withIntermediateDirectories: true)
            try? Data(Self.bridgeMarkerContents.utf8).write(to: URL(fileURLWithPath: marker))
        }
        guard (try? String(contentsOfFile: marker, encoding: .utf8)) == Self.bridgeMarkerContents else { return }
        let cutoff = Date().addingTimeInterval(-Self.bridgeRetention)
        for kind in ["claude", "codex"] {
            let base = environment.bridgeDirectory + "/" + kind
            // Staging folders belong to a wrapper still being written.
            for entry in (try? fileManager.contentsOfDirectory(atPath: base)) ?? [] where !entry.hasPrefix(".") {
                let path = base + "/" + entry
                let used = (try? fileManager.attributesOfItem(atPath: path + "/" + Self.bridgeMarker)[.modificationDate] as? Date) ?? .distantPast
                if used < cutoff { try? fileManager.removeItem(atPath: path) }
            }
        }
    }

    private func existingWrappers(kind: String) -> [String] {
        let base = environment.bridgeDirectory + "/" + kind
        return ((try? fileManager.contentsOfDirectory(atPath: base)) ?? []).sorted()
            .filter { !$0.hasPrefix(".") }
            .map { base + "/" + $0 }
    }

    /// A content-addressed wrapper: the same set of links always maps to the
    /// same folder, which is never changed once written, so concurrent
    /// launches can share it.
    private func wrapper(kind: String, links: [(String, String)], skillsSubpath: String?) -> (root: String, links: [SkillBridgeLaunch.BridgedSkill])? {
        guard !links.isEmpty else { return nil }
        let key = SHA256.hash(data: Data(links.map { "\($0.0)=\($0.1)" }.sorted().joined(separator: "\n").utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        let root = environment.bridgeDirectory + "/" + kind + "/" + key
        let skillsFolder = skillsSubpath.map { root + "/" + $0 } ?? root
        let result = links.map { SkillBridgeLaunch.BridgedSkill(name: $0.0, source: $0.1, link: skillsFolder + "/" + $0.0) }
        let marker = root + "/" + Self.bridgeMarker
        if fileManager.fileExists(atPath: marker) {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: marker)
            return (root, result)
        }
        let staging = environment.bridgeDirectory + "/" + kind + "/.staging-" + UUID().uuidString
        do {
            let stagedSkills = skillsSubpath.map { staging + "/" + $0 } ?? staging
            try fileManager.createDirectory(atPath: stagedSkills, withIntermediateDirectories: true)
            for (name, source) in links {
                try fileManager.createSymbolicLink(atPath: stagedSkills + "/" + name, withDestinationPath: source)
            }
            try Data(Self.bridgeMarkerContents.utf8).write(to: URL(fileURLWithPath: staging + "/" + Self.bridgeMarker))
            try fileManager.moveItem(atPath: staging, toPath: root)
        } catch {
            try? fileManager.removeItem(atPath: staging)
            // Another launch wrote the same wrapper first.
            guard fileManager.fileExists(atPath: marker) else {
                PlayhouseDiagnostics.record("skills.bridge.failed", fields: ["kind": kind, "error": error.localizedDescription])
                return nil
            }
        }
        return (root, result)
    }
}

// MARK: - Frontmatter

/// The subset of YAML frontmatter skills use: `name` and `description`, with
/// plain, quoted, or folded (`>`, `|`) values.
struct SkillFrontmatter {
    var name: String?
    var description: String?
    var issue: String?

    /// One top-level frontmatter key, its value, and the lines it was read from.
    struct Entry {
        let key: String
        let value: String
        let lines: [String]
    }

    /// The lines between the opening and closing `---`, and the line index
    /// where the instructions start, or nil when there is no frontmatter.
    static func split(_ contents: String) -> (header: [String], bodyStart: Int, lines: [String])? {
        let lines = contents.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        return (Array(lines[1..<end]), end + 1, lines)
    }

    static func entries(_ header: [String]) -> [Entry] {
        var entries: [Entry] = []
        var index = 0
        while index < header.count {
            let line = header[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            var raw = [line]
            if [">", "|", ">-", "|-", ">+", "|+", ""].contains(value) {
                var parts: [String] = []
                while index < header.count, header[index].hasPrefix(" ") || header[index].hasPrefix("\t") || header[index].isEmpty {
                    let part = header[index].trimmingCharacters(in: .whitespaces)
                    if !part.isEmpty { parts.append(part) }
                    raw.append(header[index])
                    index += 1
                }
                // A YAML list, such as allowed-tools given one tool per line.
                if value.isEmpty, !parts.isEmpty, parts.allSatisfy({ $0.hasPrefix("- ") }) {
                    value = parts.map { unquoted(String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }.joined(separator: ", ")
                } else {
                    value = parts.joined(separator: value.hasPrefix("|") ? "\n" : " ")
                }
            } else {
                value = Self.unquoted(value)
            }
            entries.append(Entry(key: key, value: value, lines: raw))
        }
        return entries
    }

    init(_ contents: String) {
        guard let header = Self.split(contents)?.header else {
            issue = "SKILL.md must start with frontmatter between --- lines that sets name and description."
            return
        }
        for entry in Self.entries(header) {
            switch entry.key {
            case "name": name = entry.value
            case "description": description = entry.value
            default: break
            }
        }
        if name?.isEmpty != false {
            issue = "SKILL.md frontmatter must set a name."
        } else if description?.isEmpty != false {
            issue = "SKILL.md frontmatter must set a description."
        }
    }

    static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        let inner = String(value.dropFirst().dropLast())
        return first == "'"
            ? inner.replacingOccurrences(of: "''", with: "'")
            : inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Structured SKILL.md

/// A SKILL.md split into the header fields the Skills page edits and the
/// instructions below them. Frontmatter Playhouse does not edit is kept as
/// written, so a structured edit never drops a provider's own keys.
struct SkillManifest: Codable, Equatable, Sendable {
    /// Optional fields of the open Agent Skills format. Both Claude Code and
    /// Codex accept them, and each ignores the ones it does not use.
    static let optionalKeys = ["license", "compatibility", "allowed-tools"]

    var name: String
    var description: String
    var fields: [String: String]
    var body: String
    /// Other frontmatter entries, verbatim and in order.
    var preservedFrontmatter: [String] = []

    init(name: String, description: String, fields: [String: String] = [:], body: String, preservedFrontmatter: [String] = []) {
        self.name = name
        self.description = description
        self.fields = fields
        self.body = body
        self.preservedFrontmatter = preservedFrontmatter
    }

    /// A file without frontmatter is all instructions, named after its folder.
    init(parsing contents: String, fallbackName: String) {
        guard let split = SkillFrontmatter.split(contents) else {
            self.init(name: fallbackName, description: "", body: contents.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        var name: String?
        var description = ""
        var fields: [String: String] = [:]
        var preserved: [String] = []
        for entry in SkillFrontmatter.entries(split.header) {
            switch entry.key {
            case "name": name = entry.value
            case "description": description = entry.value
            case let key where Self.optionalKeys.contains(key): fields[key] = entry.value
            default: preserved += entry.lines
            }
        }
        let body = split.lines[split.bodyStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(name: name.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName, description: description,
                  fields: fields, body: body, preservedFrontmatter: preserved)
    }

    var contents: String {
        let summary = description.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        var lines = ["---", "name: \(name)", "description: \(SkillFrontmatter.quoted(summary))"]
        for key in Self.optionalKeys {
            let value = fields[key]?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) ?? ""
            if !value.isEmpty { lines.append("\(key): \(SkillFrontmatter.quoted(value))") }
        }
        lines += preservedFrontmatter
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
