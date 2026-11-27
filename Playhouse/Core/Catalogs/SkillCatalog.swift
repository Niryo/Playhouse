import Foundation

// MARK: - Model

/// Where a skill folder lives. Both providers read the same `SKILL.md` format,
/// but each looks in its own folders: Codex reads the open Agent Skills layout
/// (`.agents/skills`), Claude Code reads `.claude/skills`. Playhouse treats every
/// folder as one gallery and bridges each skill to the provider that would not
// MARK: - Manager

/// Reads and manages the skill gallery shared by both providers. The GUI and
/// the CLI reach it through the same bridge commands.
@MainActor
package final class SkillCatalogManager {
    package static let disabledSkillsKey = "disabledSkillIDs"
    private static let bridgeMarker = ".playhouse-skill-bridge"
    private static let bridgeMarkerContents = "Playhouse owns this skill bridge folder (v1).\n"
    /// Wrappers unused this long are removed; any newer one may still back a loaded Codex thread.
    private static let bridgeRetention: TimeInterval = 14 * 24 * 60 * 60

    private let environment: SkillEnvironment
    private let preferences: UserDefaults
    private let fileManager = FileManager.default

    package init(environment: SkillEnvironment, preferences: UserDefaults) {
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

    package var disabledSkillIDs: Set<String> {
        Set(preferences.stringArray(forKey: Self.disabledSkillsKey) ?? [])
    }

    /// The gallery for a task's roots. `bundledClaudeSkills` are the names
    /// Claude Code reports as built in; they have no folder to scan.
    package func catalog(roots: [SkillRoot], bundledClaudeSkills: [(name: String, description: String)] = []) -> SkillCatalog {
        let disabled = disabledSkillIDs
        var sections = roots.map { root in
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
        let builtinNames = Set(builtinSkills().map(\.name)).union(bundledClaudeSkills.map(\.name))
        // Committed repository skills and the user's own skills take precedence
        // over a private skill of the same name, so both providers use the same
        // one; a private skill another repository's private skill already named
        // is namespaced as `<repository>:<name>`.
        let shared = Set(sections.flatMap(\.skills).map(\.name)).union(global.map(\.name)).union(builtinNames)
        var privateNames = Set<String>()
        for (index, root) in roots.enumerated() {
            let scanned = scan(privateSkillsFolder(repositoryPath: root.repositoryPath), layout: .playhousePrivate)
            let privateSkills = records(scanned, scope: .privateRepo, root: root, disabled: disabled).map { record -> SkillRecord in
                if shared.contains(record.name) {
                    let owner = sections.first { $0.skills.contains { $0.name == record.name } }.map { "\($0.name)'s committed skills" }
                        ?? (global.contains { $0.name == record.name } ? "your global skills" : "the built-in skills")
                    return record.adjusted(
                        providers: [],
                        issue: .some(record.issue ?? "Not used: \(owner) also have a skill named \"\(record.name)\", and it takes precedence for both Claude and Codex. Rename or delete this private skill."),
                        shadowedBy: .some(owner)
                    )
                }
                // Only a skill the bridge passes on claims its name, the way Claude Code names them.
                guard record.issue == nil, record.enabled else { return record }
                return privateNames.insert(record.name).inserted
                    ? record
                    : record.adjusted(invocationName: .some("\(Self.wrapperFolderName(root.name)):\(record.name)"))
            }
            let section = sections[index]
            sections[index] = SkillRepositorySection(
                repositoryPath: section.repositoryPath, rootPath: section.rootPath, name: section.name,
                skills: (section.skills + privateSkills).sorted { ($0.name, $0.scope == .privateRepo ? 1 : 0) < ($1.name, $1.scope == .privateRepo ? 1 : 0) }
            )
        }
        // OpenCode's one server serves every task, so Playhouse adds no skills to it: it uses
        // the skills it finds itself, in the working folder and the home folder, on or off.
        for index in sections.indices {
            let section = sections[index]
            sections[index] = SkillRepositorySection(
                repositoryPath: section.repositoryPath, rootPath: section.rootPath, name: section.name,
                skills: section.skills.map { openCodeMarked($0, workingFolder: index == 0 ? section.name : sections[0].name, isWorking: index == 0) }
            )
        }
        let openCodeGlobal = global.map { openCodeMarked($0, workingFolder: nil, isWorking: false) }
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
        return SkillCatalog(repositories: sections, global: openCodeGlobal, builtin: builtin)
    }

    private func globalSkills() -> [ScannedSkill] {
        scan(environment.homeDirectory + "/.agents/skills", layout: .agents)
            + scan(environment.claudeConfigDirectory + "/skills", layout: .claude, excluding: ["synced"])
            + scan(environment.codexHome + "/skills", layout: .codexLegacy)
    }

    /// Adds OpenCode to a skill it finds itself: the working folder's `.agents` and `.claude`
    /// skills, and the home folder's `.agents` skills and Claude Code's own `~/.claude/skills`.
    /// `providerNote` says why OpenCode doesn't use another, or that it still uses one turned off.
    private func openCodeMarked(_ record: SkillRecord, workingFolder: String?, isWorking: Bool) -> SkillRecord {
        guard !record.providers.isEmpty else { return record }
        let layouts = Set(record.locations.map(\.layout))
        let note: String
        switch record.scope {
        case .repo where isWorking && !layouts.isDisjoint(with: [.agents, .claude]),
             .global where layouts.contains(.agents) || (layouts.contains(.claude) && environment.openCodeReadsClaudeHome):
            return record.adjusted(
                providers: record.providers + [.opencode],
                providerNote: record.enabled ? nil : .some("OpenCode still uses it: it finds this skill itself, and Playhouse can't turn it off there.")
            )
        case .repo:
            note = "Not on OpenCode: it reads skills only from the task's working folder, \(workingFolder ?? "the first repository")."
        case .privateRepo:
            note = "Not on OpenCode: it reads only skills in the repository and your home folder."
        case .global where layouts.contains(.claude):
            note = "Not on OpenCode: it reads ~/.claude/skills, not CLAUDE_CONFIG_DIR's skills."
        default:
            note = "Not on OpenCode: it doesn't read Codex's skill folder."
        }
        return record.adjusted(providerNote: .some(note))
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
            case .repo, .privateRepo, .global: id = Self.id(scope: scope, repositoryPath: root?.repositoryPath, name: name)
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

    package static func globalID(name: String) -> String { "global:\(name)" }
    package static func repoID(repositoryPath: String, name: String) -> String { "repo:\(repositoryPath)#\(name)" }
    package static func builtinID(provider: ConversationProvider, name: String) -> String { "builtin:\(provider.rawValue):\(name)" }
    package static func privateID(repositoryPath: String, name: String) -> String { "private:\(repositoryPath)#\(name)" }

    /// The ID of a user skill: built-in skills are keyed by their provider instead.
    package static func id(scope: SkillScope, repositoryPath: String?, name: String) -> String {
        switch scope {
        case .repo: repoID(repositoryPath: repositoryPath ?? "", name: name)
        case .privateRepo: privateID(repositoryPath: repositoryPath ?? "", name: name)
        case .global, .builtin: globalID(name: name)
        }
    }

    // MARK: Private store

    /// A repository's folder in the private store. A task worktree's skills are
    /// keyed by its source repository, so every worktree of that repository,
    /// and the checkout itself, shares one set of private skills. The readable
    /// name is for people browsing the folder; the hash keeps two repositories
    /// with the same name apart.
    package func privateStoreRoot(repositoryPath: String) -> String {
        let standardized = URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
        let readable = URL(fileURLWithPath: standardized).lastPathComponent
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "-", options: .regularExpression)
        let hash = Hashing.sha256(Data(standardized.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return environment.privateSkillsDirectory + "/" + readable + "-" + hash
    }

    /// Laid out as `.claude/skills`, the standard skill layout, so the folder
    /// stays a valid skills root for either provider.
    package func privateSkillsFolder(repositoryPath: String) -> String {
        privateStoreRoot(repositoryPath: repositoryPath) + "/.claude/skills"
    }

    /// Records which repository a store folder belongs to, for people browsing it.
    private func preparePrivateStore(repositoryPath: String) throws {
        let root = privateStoreRoot(repositoryPath: repositoryPath)
        try fileManager.createDirectory(atPath: root + "/.claude/skills", withIntermediateDirectories: true)
        let marker = root + "/repository"
        if !fileManager.fileExists(atPath: marker) {
            try Data((URL(fileURLWithPath: repositoryPath).standardizedFileURL.path + "\n").utf8)
                .write(to: URL(fileURLWithPath: marker), options: .atomic)
        }
    }

    package func content(id: String, roots: [SkillRoot]) throws -> String {
        let record = try existing(id: id, roots: roots)
        guard let folder = record.folderPath else {
            throw BridgeCommandError(code: "invalid_argument", message: "\(record.name) is built into Claude Code and has no file to show.")
        }
        return try String(contentsOfFile: folder + "/SKILL.md", encoding: .utf8)
    }

    // MARK: Managing

    package static func validate(name: String) throws {
        let valid = name.count <= 64
            && name.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil
        guard valid else {
            throw BridgeCommandError(
                code: "invalid_argument",
                message: "A skill name uses lowercase letters, digits, and single hyphens, up to 64 characters."
            )
        }
    }

    package static func manifest(name: String, description: String, body: String, fields: [String: String] = [:]) -> String {
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

    /// Writes a new skill in the open Agent Skills layout, which both providers
    /// then see. A private skill goes to the Playhouse store instead, so nothing
    /// is written to the repository or its worktrees.
    package func create(name: String, description: String, body: String, fields: [String: String] = [:], scope: SkillScope, root: SkillRoot?, roots: [SkillRoot]) throws -> SkillRecord {
        try Self.validate(name: name)
        try Self.validate(description: description)
        try Self.validate(fields: fields)
        let summary = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = try agentsFolder(scope: scope, root: root)
        guard !taken(name, by: nil, scope: scope, root: root, roots: roots), !fileManager.fileExists(atPath: base + "/" + name) else {
            throw BridgeCommandError(code: "already_exists", message: "A skill named \(name) already exists here.")
        }
        if scope == .privateRepo, let root { try preparePrivateStore(repositoryPath: root.repositoryPath) }
        try fileManager.createDirectory(atPath: base + "/" + name, withIntermediateDirectories: true)
        try Data(Self.manifest(name: name, description: summary, body: body, fields: fields).utf8)
            .write(to: URL(fileURLWithPath: base + "/" + name + "/SKILL.md"), options: .atomic)
        PlayhouseDiagnostics.record("skills.created", fields: ["scope": scope.rawValue, "name": name])
        return try existing(id: Self.id(scope: scope, repositoryPath: root?.repositoryPath, name: name), roots: roots)
    }

    /// Whether another skill already uses `name` where a skill of `scope` would
    /// go. A private skill also may not take a name its repository's committed
    /// skills or the user's global skills use, since those take precedence.
    private func taken(_ name: String, by id: String?, scope: SkillScope, root: SkillRoot?, roots: [SkillRoot]) -> Bool {
        let current = catalog(roots: roots)
        let section = current.repositories.first { $0.rootPath == root?.path }?.skills ?? []
        let candidates: [SkillRecord]
        switch scope {
        case .global: candidates = current.global
        case .repo: candidates = section.filter { $0.scope == .repo }
        // Committed skills of any of the task's repositories, and built-ins, would shadow it.
        case .privateRepo: candidates = section + current.repositories.flatMap(\.skills).filter { $0.scope == .repo } + current.global + current.builtin
        case .builtin: candidates = []
        }
        return candidates.contains { $0.name == name && $0.id != id }
    }

    package func update(id: String, content: String, roots: [SkillRoot]) throws -> SkillRecord {
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
    package func manifest(id: String, roots: [SkillRoot]) throws -> SkillManifest {
        let record = try existing(id: id, roots: roots)
        return SkillManifest(parsing: try content(id: id, roots: roots), fallbackName: record.name)
    }

    /// Edits a skill's description, header fields, or instructions while
    /// keeping its name and any frontmatter Playhouse does not edit.
    /// A field set to an empty string is removed.
    package func update(id: String, description: String?, body: String?, fields: [String: String], roots: [SkillRoot]) throws -> SkillRecord {
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
    package func delete(ids: [String], roots: [SkillRoot]) throws {
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
    package func fixPlan(ids: [String], roots: [SkillRoot]) throws -> SkillFixPlan {
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
        // Private skills are in Playhouse's store, outside Git, so like global skills they are fixed in place.
        let globalSkills = records.filter { $0.scope == .global || $0.scope == .privateRepo }
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
                globalSkills.contains { $0.scope == .privateRepo }
                    ? "Global and private skills. These live in the user's home folder or in Playhouse's private skill store and are not tracked by Git: fix them directly in place. There is nothing to commit or push for them, and the fix takes effect immediately."
                    : "Global skills. These live in the user's home folder and are not tracked by Git: fix them directly in place. There is nothing to commit or push for them, and the fix takes effect immediately.",
            ]
            for record in globalSkills {
                let owner = record.scope == .privateRepo ? " (private to \(URL(fileURLWithPath: record.repositoryPath ?? "").lastPathComponent))" : ""
                lines.append("- `\(record.name)`\(owner): \(record.locations.map { "`\($0.path)`" }.joined(separator: ", ")). Problem: \(problem(record))")
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

    /// Moves a skill between a repository, the global gallery and a
    /// repository's private store, keeping its enabled state. A repository
    /// skill lands in the Agent Skills layout of the task's worktree, so
    /// converting a private skill to a repository skill is a change to commit;
    /// making a repository skill private removes it from the worktree.
    package func move(id: String, to scope: SkillScope, root: SkillRoot?, roots: [SkillRoot]) throws -> SkillRecord {
        let record = try editable(id: id, roots: roots)
        guard scope != .builtin else {
            throw BridgeCommandError(code: "invalid_argument", message: "A skill can move to a repository, to the global gallery, or to a repository's private skills.")
        }
        let base = try agentsFolder(scope: scope, root: root)
        let target = base + "/" + record.name
        guard URL(fileURLWithPath: target).standardizedFileURL.path != record.folderPath else {
            throw BridgeCommandError(code: "invalid_argument", message: "\(record.name) is already there.")
        }
        guard !taken(record.name, by: record.id, scope: scope, root: root, roots: roots), !fileManager.fileExists(atPath: target) else {
            throw BridgeCommandError(code: "already_exists", message: "A skill named \(record.name) already exists there.")
        }
        for location in record.locations where location.isSymlink {
            try removeVerifiedLink(location.path, to: record.folderPath!)
        }
        if scope == .privateRepo, let root { try preparePrivateStore(repositoryPath: root.repositoryPath) }
        try fileManager.createDirectory(atPath: base, withIntermediateDirectories: true)
        try fileManager.moveItem(atPath: record.folderPath!, toPath: target)
        let newID = Self.id(scope: scope, repositoryPath: root?.repositoryPath, name: record.name)
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
    package func setEnabled(
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
    package func link(id: String, roots: [SkillRoot]) throws -> SkillRecord {
        let record = try editable(id: id, roots: roots)
        guard record.scope != .privateRepo else {
            throw BridgeCommandError(
                code: "invalid_argument",
                message: "\(record.name) is private, so Playhouse keeps it out of the repository. Convert it to a repository skill to share it outside Playhouse."
            )
        }
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

    package func unlink(id: String, roots: [SkillRoot]) throws -> SkillRecord {
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
        case .privateRepo:
            guard let root else {
                throw BridgeCommandError(code: "invalid_argument", message: "Choose one of the task's repositories for a private skill.")
            }
            return privateSkillsFolder(repositoryPath: root.repositoryPath)
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

    package static func relativePath(from directory: String, to target: String) -> String {
        let from = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let to = URL(fileURLWithPath: target).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var common = 0
        while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
        let ups = Array(repeating: "..", count: from.count - common)
        return (ups + to[common...]).joined(separator: "/")
    }

    // MARK: Bridge

    /// A skill Playhouse ships in its app bundle (`PluginRuntime/skills/<name>`),
    /// bridged into the sessions that need it and never installed anywhere.
    package static func playhouseSkillFolder(_ name: String) -> String? {
        guard let folder = PluginRuntime.bundledResources?.appendingPathComponent("skills/\(name)", isDirectory: true),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path) else { return nil }
        return folder.path
    }

    /// Builds the wrapper folders that let each provider see the skills it does
    /// not read natively, and returns what its launch must pass.
    /// `playhouseSkills` names skills from Playhouse's own bundle that this
    /// launch also gets, each through its own Playhouse-owned wrapper.
    package func bridge(roots: [SkillRoot], playhouseSkills: [String] = []) -> SkillBridgeLaunch {
        let catalog = catalog(roots: roots)
        var launch = SkillBridgeLaunch()

        func usable(_ record: SkillRecord) -> Bool {
            record.enabled && !record.conflict && record.issue == nil && record.folderPath != nil
        }
        func sources(_ record: SkillRecord, _ layouts: Set<SkillLayout>) -> Bool {
            record.locations.contains { layouts.contains($0.layout) }
        }
        let repoRecords = catalog.repositories.flatMap { section in section.skills.filter { $0.scope == .repo }.map { (section.rootPath, $0) } }
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

        // A private skill that is off is simply left out of its wrapper; a name
        // override would also turn off another skill with the same name.
        for record in catalog.allSkills where !record.enabled && record.scope != .privateRepo {
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
        var ownCodexRoots = Set([ownCodexWrapper?.root].compactMap { $0 })

        // Each repository's private skills get their own wrapper, so they reach
        // only tasks on that repository. Claude Code's wrapper is named after
        // the repository: when two of a task's repositories have private
        // skills with the same name, Claude Code calls the later one
        // `/<repository>:<name>`, which is the name the Skills page shows.
        // Codex keeps both, each under its own SKILL.md path.
        for section in catalog.repositories {
            let links = section.skills.filter { $0.scope == .privateRepo && usable($0) && !$0.providers.isEmpty }.map { ($0.name, $0.folderPath!) }
            guard !links.isEmpty else { continue }
            let folder = Self.wrapperFolderName(section.name)
            if let claude = wrapper(kind: "claude", links: links, skillsSubpath: folder + "/.claude/skills", salt: "private:" + section.repositoryPath) {
                launch.claudeAddDirectories.append(claude.root + "/" + folder)
                launch.claudeLinks += claude.links
            }
            if let codex = wrapper(kind: "codex", links: links, skillsSubpath: nil, salt: "private:" + section.repositoryPath) {
                ownCodexRoots.insert(codex.root)
                launch.codexLinks += codex.links
            }
        }
        let playhouseLinks = playhouseSkills.compactMap { name in Self.playhouseSkillFolder(name).map { (name, $0) } }
        if let claude = wrapper(kind: "claude", links: playhouseLinks, skillsSubpath: ".claude/skills", salt: "playhouse") {
            launch.claudeAddDirectories.append(claude.root)
            launch.claudeLinks += claude.links
        }
        if let codex = wrapper(kind: "codex", links: playhouseLinks, skillsSubpath: nil, salt: "playhouse") {
            ownCodexRoots.insert(codex.root)
            launch.codexLinks += codex.links
        }
        let codexWrappers = existingWrappers(kind: "codex")
        launch.codexExtraRoots = codexWrappers
        for other in codexWrappers where !ownCodexRoots.contains(other) {
            for entry in ((try? fileManager.contentsOfDirectory(atPath: other)) ?? []).sorted() where !entry.hasPrefix(".") {
                launch.codexDisabledSkillPaths.append(other + "/" + entry + "/SKILL.md")
            }
        }
        launch.codexDisabledSkillPaths = Array(Set(launch.codexDisabledSkillPaths)).sorted()
        return launch
    }

    /// Finds skills a message names as `/skill-name`, or `/<repository>:<name>`
    /// for a namespaced private skill, so Codex, which has no slash commands,
    /// can be handed each skill as a structured input.
    package func invocations(in text: String, roots: [SkillRoot]) -> [SkillInvocation] {
        let names = Self.invokedNames(in: text)
        guard !names.isEmpty else { return [] }
        let catalog = catalog(roots: roots)
        var seen = Set<String>()
        return names.compactMap { name in
            guard seen.insert(name).inserted,
                  let record = catalog.allSkills.first(where: { ($0.invocationName ?? $0.name) == name && $0.enabled && $0.providers.contains(.codex) && $0.folderPath != nil })
            else { return nil }
            return SkillInvocation(name: record.name, path: record.folderPath! + "/SKILL.md")
        }
    }

    /// The `/skill-name` (or `/<repository>:<name>`) tokens a message names.
    package static func invokedNames(in text: String) -> [String] {
        let pattern = #"(?:^|\s)/((?:[A-Za-z0-9._-]+:)?[a-z0-9]+(?:-[a-z0-9]+)*)(?=\s|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// The plugins folder beside this data directory's skill bridge, which a
    /// plugin authoring task writes to.
    package var pluginsDirectory: String {
        PluginLibrary(dataDirectory: URL(fileURLWithPath: environment.bridgeDirectory).deletingLastPathComponent().path).directory.path
    }

    /// The Playhouse skills a task's sessions get: a plugin authoring task
    /// gets the plugin skill.
    package static func playhouseSkills(for task: any ConversationSubject) -> [String] {
        task.authoringPluginPlacement == nil ? [] : [TaskThreadDeveloperInstructions.pluginSkillName]
    }

    /// Everything a launch for `task` passes: the gallery's bridge, its
    /// Playhouse skills, and the skills `message` invokes. Codex has no slash
    /// commands, so a Playhouse skill a message names is handed over directly too.
    package func bridge(for task: any ConversationSubject, message: String) -> SkillBridgeLaunch {
        let roots = SkillRoot.roots(for: task)
        let playhouseSkills = Self.playhouseSkills(for: task)
        var launch = bridge(roots: roots, playhouseSkills: playhouseSkills)
        launch.invocations = invocations(in: message, roots: roots)
        let named = Set(Self.invokedNames(in: message))
        for link in launch.codexLinks where playhouseSkills.contains(link.name) && (named.contains(link.name) || task.authoringPluginID != nil) {
            launch.invocations.append(SkillInvocation(name: link.name, path: link.source + "/SKILL.md"))
        }
        return launch
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

    /// A repository name as a single folder name, which Claude Code uses as the
    /// namespace of a clashing skill.
    package static func wrapperFolderName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "-", options: .regularExpression)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "repository" + cleaned : cleaned
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
    /// `salt` keeps a private wrapper apart from a shared one that happens to
    /// hold the same links.
    private func wrapper(kind: String, links: [(String, String)], skillsSubpath: String?, salt: String? = nil) -> (root: String, links: [SkillBridgeLaunch.BridgedSkill])? {
        guard !links.isEmpty else { return nil }
        let entries = links.map { "\($0.0)=\($0.1)" }.sorted() + (salt.map { ["salt=\($0)", "layout=\(skillsSubpath ?? "")"] } ?? [])
        let key = Hashing.sha256(Data(entries.joined(separator: "\n").utf8))
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
