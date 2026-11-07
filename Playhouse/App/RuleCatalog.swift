import Foundation

// MARK: - Model

/// Which instruction file a rule is. Claude Code reads `CLAUDE.md` files and
/// `.claude/rules`, and also a repository's `AGENTS.md`; Codex reads one
/// `AGENTS.md` (or `AGENTS.override.md`) per folder and one in its home.
/// Playhouse lists them as one set and shares each rule with the provider that
/// would not otherwise read it.
enum RuleLayout: String, Codable, Sendable {
    /// `<repo>/AGENTS.md`, read by Codex and, when no CLAUDE.md is beside it, by Claude Code.
    case agents
    /// `<repo>/AGENTS.override.md`, which Codex reads instead of AGENTS.md.
    case agentsOverride
    /// `<repo>/CLAUDE.md` or `<repo>/.claude/CLAUDE.md`.
    case claude
    /// `<repo>/CLAUDE.local.md`, personal and usually gitignored.
    case claudeLocal
    /// `<repo>/.claude/rules/**/*.md`, optionally scoped to `paths`.
    case claudeRule
    /// `~/.agents/AGENTS.md`, the provider-neutral global file. Neither CLI
    /// reads it on its own; Playhouse shares it with both.
    case sharedGlobal
    /// `$CODEX_HOME/AGENTS.md`.
    case codexGlobal
    /// `$CODEX_HOME/AGENTS.override.md`, which Codex reads instead of its AGENTS.md.
    case codexGlobalOverride
    /// `<claude config>/CLAUDE.md`.
    case claudeGlobal
    /// `<claude config>/rules/**/*.md`.
    case claudeGlobalRule
    /// The organization's managed CLAUDE.md, which only Claude Code reads.
    case claudeManaged

    var displayName: String {
        switch self {
        case .agents: "AGENTS.md"
        case .agentsOverride: "AGENTS.override.md"
        case .claude: "CLAUDE.md"
        case .claudeLocal: "CLAUDE.local.md"
        case .claudeRule: ".claude/rules"
        case .sharedGlobal: "~/.agents/AGENTS.md"
        case .codexGlobal: "Codex AGENTS.md"
        case .codexGlobalOverride: "Codex AGENTS.override.md"
        case .claudeGlobal: "Claude CLAUDE.md"
        case .claudeGlobalRule: "Claude rules"
        case .claudeManaged: "Managed CLAUDE.md"
        }
    }

    var isRuleFolder: Bool { self == .claudeRule || self == .claudeGlobalRule }
}

enum RuleScope: String, Codable, Sendable, CaseIterable {
    case repo
    case global
    case managed
}

struct RuleLocation: Codable, Equatable, Sendable {
    /// The file as found, which can be a symlink.
    let path: String
    let layout: RuleLayout
    let isSymlink: Bool
}

struct RuleRecord: Codable, Equatable, Identifiable, Sendable {
    /// Stable across tasks: a repo rule is keyed by its source repository and
    /// its path inside it, so its enabled state follows the repository.
    let id: String
    /// The path shown for the rule: repository-relative, or `~`-abbreviated.
    let name: String
    /// The rule's first heading or line, to tell rules apart at a glance.
    let summary: String
    let scope: RuleScope
    let repositoryPath: String?
    let rootPath: String?
    /// The resolved file that edits and deletes act on.
    let filePath: String
    let locations: [RuleLocation]
    /// Globs a path-scoped rule loads for; empty for a rule that always loads.
    let paths: [String]
    /// Providers that read the rule on their own when run in its repository,
    /// without Playhouse.
    let nativeProviders: [ConversationProvider]
    /// Providers that see the rule in sessions Playhouse launches.
    let providers: [ConversationProvider]
    /// Providers that follow the rule only because Playhouse hands it to them
    /// in this task, rather than loading it on their own.
    let sharedWith: [ConversationProvider]
    /// Providers that keep reading the file even while it is turned off,
    /// because Playhouse has no way to hide a file they load themselves.
    let alwaysOnFor: [ConversationProvider]
    let enabled: Bool
    let editable: Bool
    /// Both providers read the rule natively, so it also works outside Playhouse.
    let availableOutsidePlayhouse: Bool
    /// Symlinks can make the rule work outside Playhouse: each provider that does
    /// not read it has a place for it. False once it is already available.
    let linkable: Bool
    let byteCount: Int
    let issue: String?
}

struct RuleRepositorySection: Codable, Equatable, Sendable {
    let repositoryPath: String
    let rootPath: String
    let name: String
    let rules: [RuleRecord]
}

struct RuleCatalog: Codable, Equatable, Sendable {
    let repositories: [RuleRepositorySection]
    let global: [RuleRecord]
    let managed: [RuleRecord]

    var allRules: [RuleRecord] { repositories.flatMap(\.rules) + global + managed }
    func rule(id: String) -> RuleRecord? { allRules.first { $0.id == id } }

    /// The same catalog with one rule's record swapped for a newer one.
    func replacing(_ record: RuleRecord) -> RuleCatalog {
        func swap(_ rules: [RuleRecord]) -> [RuleRecord] { rules.map { $0.id == record.id ? record : $0 } }
        return RuleCatalog(
            repositories: repositories.map {
                RuleRepositorySection(repositoryPath: $0.repositoryPath, rootPath: $0.rootPath, name: $0.name, rules: swap($0.rules))
            },
            global: swap(global),
            managed: swap(managed)
        )
    }
}

/// What a provider launch needs so it follows every rule in the set. The text
/// goes into Claude Code's appended system prompt or Codex's thread developer
/// instructions; nothing is written to the user's files or settings.
struct RuleBridgeLaunch: Codable, Equatable, Sendable {
    struct SharedRule: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let path: String
        /// Set for a path-scoped rule, which is shared as a pointer to its file.
        let paths: [String]
    }

    var claudeShared: [SharedRule] = []
    /// `claudeMdExcludes` for this run: the turned-off files Claude Code reads itself.
    var claudeExcludes: [String] = []
    /// The working repository has both AGENTS.md and a CLAUDE.md, so Claude Code
    /// is told to read both rather than skip AGENTS.md.
    var claudeReadsAgentsAlongsideClaude = false
    var claudeInstructions: String?
    var codexShared: [SharedRule] = []
    var codexInstructions: String?

    /// The `--settings` entries rules need for one Claude Code run.
    var claudeSettings: [String: Any] {
        var settings: [String: Any] = [:]
        if !claudeExcludes.isEmpty { settings["claudeMdExcludes"] = claudeExcludes }
        if claudeReadsAgentsAlongsideClaude {
            settings["pluginConfigs"] = [
                "cc-plugin-agents-md@builtin": ["options": ["instructionFiles": "claude-md-and-agents-md"]],
            ]
        }
        return settings
    }

    /// One `--settings` JSON for a Claude Code run, joining what skills and
    /// rules each need, or nil when neither needs any.
    static func claudeSettingsJSON(skills: SkillBridgeLaunch?, rules: RuleBridgeLaunch?) -> String? {
        var settings = skills?.claudeSettings ?? [:]
        settings.merge(rules?.claudeSettings ?? [:]) { _, new in new }
        guard !settings.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Task instructions followed by the rules Playhouse shares, as one block.
    static func combined(_ instructions: String?, _ rules: String?) -> String? {
        let parts = [instructions, rules].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

// MARK: - Manager

/// Reads and manages the agent rules shared by both providers. The GUI and the
/// CLI reach it through the same bridge commands.
@MainActor
final class RuleCatalogManager {
    static let disabledRulesKey = "disabledRuleIDs"
    /// Codex stops reading project instructions past this size (`project_doc_max_bytes`).
    static let codexProjectDocLimit = 32 * 1024
    private static let importDepth = 4

    private let environment: SkillEnvironment
    private let preferences: UserDefaults
    private let fileManager = FileManager.default

    init(environment: SkillEnvironment, preferences: UserDefaults) {
        self.environment = environment
        self.preferences = preferences
    }

    var disabledRuleIDs: Set<String> {
        Set(preferences.stringArray(forKey: Self.disabledRulesKey) ?? [])
    }

    // MARK: Reading

    private struct ScannedFile {
        let path: String
        let realPath: String
        let layout: RuleLayout
        let isSymlink: Bool
    }

    /// One rule as found, with what decides who reads it in a launch.
    private struct Entry {
        var record: RuleRecord
        let contents: String
        /// Providers that load the file themselves in this Playhouse launch.
        let nativeInLaunch: Set<ConversationProvider>
        /// Providers that deliberately do not get the rule, such as Claude Code
        /// for Codex's AGENTS.override.md.
        let withheld: Set<ConversationProvider>
        let rootIndex: Int?
        let repositoryName: String?
    }

    func catalog(roots: [SkillRoot]) -> RuleCatalog {
        let entries = self.entries(roots: roots)
        let sections = roots.enumerated().map { index, root in
            RuleRepositorySection(
                repositoryPath: root.repositoryPath, rootPath: root.path, name: root.name,
                rules: entries.filter { $0.rootIndex == index }.map(\.record)
            )
        }
        return RuleCatalog(
            repositories: sections,
            global: entries.filter { $0.record.scope == .global }.map(\.record),
            managed: entries.filter { $0.record.scope == .managed }.map(\.record)
        )
    }

    private func entries(roots: [SkillRoot]) -> [Entry] {
        let disabled = disabledRuleIDs
        var result: [Entry] = []

        let globalFiles = [
            file(environment.homeDirectory + "/.agents/AGENTS.md", layout: .sharedGlobal),
            file(environment.codexHome + "/AGENTS.override.md", layout: .codexGlobalOverride),
            file(environment.codexHome + "/AGENTS.md", layout: .codexGlobal),
            file(environment.claudeConfigDirectory + "/CLAUDE.md", layout: .claudeGlobal),
        ].compactMap { $0 } + ruleFolder(environment.claudeConfigDirectory + "/rules", layout: .claudeGlobalRule)
        let codexOverrideInUse = globalFiles.contains { $0.layout == .codexGlobalOverride && !isEmpty($0.realPath) }
        for group in grouped(globalFiles) {
            result.append(entry(group, scope: .global, root: nil, rootIndex: nil, disabled: disabled) { layout in
                switch layout {
                case .codexGlobalOverride: return ([.codex], [.codex], [])
                case .codexGlobal: return codexOverrideInUse ? ([], [], [.claude, .codex]) : ([.codex], [.codex], [])
                case .claudeGlobal, .claudeGlobalRule: return ([.claude], [.claude], [])
                default: return ([], [], [])
                }
            })
        }

        for (index, root) in roots.enumerated() {
            let files = [
                file(root.path + "/AGENTS.override.md", layout: .agentsOverride),
                file(root.path + "/AGENTS.md", layout: .agents),
                file(root.path + "/CLAUDE.md", layout: .claude),
                file(root.path + "/.claude/CLAUDE.md", layout: .claude),
                file(root.path + "/CLAUDE.local.md", layout: .claudeLocal),
            ].compactMap { $0 } + ruleFolder(root.path + "/.claude/rules", layout: .claudeRule)
            let layouts = Set(files.map(\.layout))
            let hasOverride = layouts.contains(.agentsOverride)
            // Claude Code reads AGENTS.md on its own only when no CLAUDE.md is beside it.
            let hasClaudeFile = layouts.contains(.claude) || layouts.contains(.claudeLocal)
            // Claude Code loads the working repository's files; an --add-dir root's
            // are not loaded, and Codex reads only the working repository's.
            let isWorking = index == 0
            for group in grouped(files) {
                result.append(entry(group, scope: .repo, root: root, rootIndex: index, disabled: disabled) { layout in
                    switch layout {
                    case .agentsOverride:
                        return ([.codex], isWorking ? [.codex] : [], [.claude])
                    case .agents:
                        // Playhouse has Claude Code read AGENTS.md alongside a CLAUDE.md.
                        let native: Set<ConversationProvider> = hasOverride ? (hasClaudeFile ? [] : [.claude]) : (hasClaudeFile ? [.codex] : [.claude, .codex])
                        let inLaunch: Set<ConversationProvider> = isWorking ? (hasOverride ? [.claude] : [.claude, .codex]) : []
                        return (native, inLaunch, hasOverride ? [.codex] : [])
                    case .claude, .claudeLocal, .claudeRule:
                        return ([.claude], isWorking ? [.claude] : [], [])
                    default:
                        return ([], [], [])
                    }
                })
            }
        }

        let managed = [file(environment.managedClaudeDirectory + "/CLAUDE.md", layout: .claudeManaged)].compactMap { $0 }
        for group in grouped(managed) {
            result.append(entry(group, scope: .managed, root: nil, rootIndex: nil, disabled: disabled) { _ in ([.claude], [.claude], [.codex]) })
        }
        return result
    }

    private func file(_ path: String, layout: RuleLayout) -> ScannedFile? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let isSymlink = (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
        return ScannedFile(path: path, realPath: resolved, layout: layout, isSymlink: isSymlink)
    }

    /// Every `.md` file under a rules folder, following symlinked folders once.
    private func ruleFolder(_ directory: String, layout: RuleLayout) -> [ScannedFile] {
        var found: [ScannedFile] = []
        var visited = Set<String>()
        func walk(_ folder: String, depth: Int) {
            let real = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
            guard depth < 8, visited.insert(real).inserted,
                  let entries = try? fileManager.contentsOfDirectory(atPath: folder) else { return }
            for entry in entries.sorted() where !entry.hasPrefix(".") {
                let path = folder + "/" + entry
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    walk(path, depth: depth + 1)
                } else if entry.lowercased().hasSuffix(".md"), let scanned = file(path, layout: layout) {
                    found.append(scanned)
                }
            }
        }
        walk(directory, depth: 0)
        return found
    }

    /// Files that resolve to the same file are one rule, in scan order.
    private func grouped(_ files: [ScannedFile]) -> [[ScannedFile]] {
        var order: [String] = []
        var groups: [String: [ScannedFile]] = [:]
        for file in files {
            if groups[file.realPath] == nil { order.append(file.realPath) }
            groups[file.realPath, default: []].append(file)
        }
        return order.compactMap { groups[$0] }
    }

    private func isEmpty(_ path: String) -> Bool {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `readers` gives, for one location's layout, the providers that read it
    /// outside Playhouse, the ones that load it themselves in this launch, and
    /// the ones withheld from it.
    private func entry(
        _ group: [ScannedFile], scope: RuleScope, root: SkillRoot?, rootIndex: Int?, disabled: Set<String>,
        readers: (RuleLayout) -> (native: Set<ConversationProvider>, inLaunch: Set<ConversationProvider>, withheld: Set<ConversationProvider>)
    ) -> Entry {
        let primary = group.first { !$0.isSymlink } ?? group[0]
        let contents = (try? String(contentsOfFile: primary.realPath, encoding: .utf8)) ?? ""
        var native = Set<ConversationProvider>()
        var inLaunch = Set<ConversationProvider>()
        var withheld = Set(ConversationProvider.allCases)
        for location in group {
            let readers = readers(location.layout)
            native.formUnion(readers.native)
            inLaunch.formUnion(readers.inLaunch)
            withheld.formIntersection(readers.withheld)
        }
        withheld.subtract(inLaunch)
        let id: String
        let name: String
        switch scope {
        case .repo:
            let relative = Self.relativePath(of: primary.path, inside: root?.path ?? "")
            id = Self.repoID(repositoryPath: root?.repositoryPath ?? "", path: relative)
            name = relative
        case .global:
            id = "global:" + globalKey(primary)
            name = abbreviated(primary.path)
        case .managed:
            id = "managed:claude/CLAUDE.md"
            name = primary.path
        }
        let enabled = scope == .managed || !disabled.contains(id)
        let alwaysOn = scope == .managed ? inLaunch : inLaunch.intersection([.codex])
        let reaching = Set(ConversationProvider.allCases).subtracting(withheld)
        let paths = primary.layout.isRuleFolder ? Self.pathGlobs(contents) : []
        let record = RuleRecord(
            id: id, name: name, summary: Self.summary(contents), scope: scope,
            repositoryPath: root?.repositoryPath, rootPath: root?.path, filePath: primary.realPath,
            locations: group.map { RuleLocation(path: $0.path, layout: $0.layout, isSymlink: $0.isSymlink) },
            paths: paths,
            nativeProviders: Self.ordered(native),
            providers: Self.ordered(enabled ? reaching : alwaysOn),
            sharedWith: Self.ordered(enabled ? reaching.subtracting(inLaunch.intersection(native)) : []),
            alwaysOnFor: Self.ordered(alwaysOn),
            enabled: enabled,
            editable: scope != .managed,
            availableOutsidePlayhouse: native.isSuperset(of: ConversationProvider.allCases),
            linkable: scope != .managed && !native.isSuperset(of: ConversationProvider.allCases)
                && linkTargets(layouts: Set(group.map(\.layout)), native: native, rootPath: root?.path) != nil,
            byteCount: contents.utf8.count,
            issue: issue(for: primary, contents: contents, nativeToCodex: native.contains(.codex) && scope == .repo)
        )
        return Entry(record: record, contents: contents, nativeInLaunch: inLaunch, withheld: withheld,
                     rootIndex: rootIndex, repositoryName: root?.name)
    }

    private func globalKey(_ file: ScannedFile) -> String {
        switch file.layout {
        case .sharedGlobal: return "agents/AGENTS.md"
        case .codexGlobal: return "codex/AGENTS.md"
        case .codexGlobalOverride: return "codex/AGENTS.override.md"
        case .claudeGlobal: return "claude/CLAUDE.md"
        default: return "claude/rules/" + Self.relativePath(of: file.path, inside: environment.claudeConfigDirectory + "/rules")
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = environment.homeDirectory
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func issue(for file: ScannedFile, contents: String, nativeToCodex: Bool) -> String? {
        if file.layout.isRuleFolder, contents.hasPrefix("---"), SkillFrontmatter.split(contents) == nil {
            return "The frontmatter has no closing --- line, so Claude Code reads it as instructions."
        }
        if let missing = Self.imports(in: contents).first(where: { resolveImport($0, from: file.realPath) == nil }) {
            return "It imports @\(missing), which doesn't exist."
        }
        if nativeToCodex, contents.utf8.count > Self.codexProjectDocLimit {
            return "Codex reads only the first 32 KiB of project instructions, and this file is \(contents.utf8.count / 1024) KiB."
        }
        return nil
    }

    static func ordered(_ providers: Set<ConversationProvider>) -> [ConversationProvider] {
        [.claude, .codex].filter(providers.contains)
    }

    static func repoID(repositoryPath: String, path: String) -> String { "repo:\(repositoryPath)#\(path)" }

    static func relativePath(of path: String, inside root: String) -> String {
        let prefix = URL(fileURLWithPath: root).standardizedFileURL.path + "/"
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.hasPrefix(prefix) ? String(standardized.dropFirst(prefix.count)) : standardized
    }

    /// The first heading or line of the instructions, without frontmatter.
    static func summary(_ contents: String) -> String {
        let lines = SkillFrontmatter.split(contents).map { Array($0.lines[$0.bodyStart...]) }
            ?? contents.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("@"), !text.hasPrefix("<!--") else { continue }
            let plain = text.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return String(plain.prefix(140))
        }
        return ""
    }

    /// The `paths` globs from a rule file's frontmatter, as a YAML list, a
    /// flow list, or one value.
    static func pathGlobs(_ contents: String) -> [String] {
        guard let header = SkillFrontmatter.split(contents)?.header,
              let index = header.firstIndex(where: { $0.hasPrefix("paths:") }) else { return [] }
        let inline = header[index].dropFirst("paths:".count).trimmingCharacters(in: .whitespaces)
        if inline.hasPrefix("["), inline.hasSuffix("]") {
            return inline.dropFirst().dropLast().split(separator: ",")
                .map { SkillFrontmatter.unquoted($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
        }
        if !inline.isEmpty { return [SkillFrontmatter.unquoted(inline)] }
        var globs: [String] = []
        for line in header[(index + 1)...] {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(" ") || line.hasPrefix("\t") || text.isEmpty else { break }
            if text.hasPrefix("- ") { globs.append(SkillFrontmatter.unquoted(String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces))) }
        }
        return globs
    }

    /// The `@path` imports a file makes on lines of their own, outside code blocks.
    static func imports(in contents: String) -> [String] {
        var inFence = false
        var found: [String] = []
        for line in contents.components(separatedBy: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("```") || text.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, text.hasPrefix("@"), text.count > 1, !text.contains(" "), !text.contains("`") else { continue }
            found.append(String(text.dropFirst()))
        }
        return found
    }

    private func resolveImport(_ reference: String, from file: String) -> String? {
        let expanded = reference.hasPrefix("~/") ? environment.homeDirectory + reference.dropFirst(1) : reference
        let path = expanded.hasPrefix("/")
            ? expanded
            : URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent(expanded).path
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory) && !isDirectory.boolValue ? resolved : nil
    }

    func content(id: String, roots: [SkillRoot]) throws -> String {
        try String(contentsOfFile: existing(id: id, roots: roots).filePath, encoding: .utf8)
    }

    // MARK: Managing

    private static func validate(content: String) throws {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "A rule needs instructions. Delete the rule to remove it.")
        }
    }

    private static func validate(name: String) throws {
        guard name.count <= 64, name.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
            throw BridgeCommandError(code: "invalid_argument", message: "A rule name uses lowercase letters, digits, and single hyphens, up to 64 characters.")
        }
    }

    static func ruleFile(paths: [String], body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paths.isEmpty else { return trimmed + "\n" }
        let header = ["---", "paths:"] + paths.map { "  - " + SkillFrontmatter.quoted($0) } + ["---"]
        return header.joined(separator: "\n") + "\n\n" + trimmed + "\n"
    }

    /// Writes a new rule. Without a name it is the shared AGENTS.md (the
    /// repository's, or `~/.agents/AGENTS.md`); with one it is a topic file in
    /// `.claude/rules`, which can be scoped to `paths`.
    func create(name: String?, paths: [String], body: String, scope: RuleScope, root: SkillRoot?, roots: [SkillRoot]) throws -> RuleRecord {
        let globs = paths.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let trimmedName = name?.trimmingCharacters(in: .whitespaces) ?? ""
        try Self.validate(content: body)
        if !trimmedName.isEmpty { try Self.validate(name: trimmedName) }
        if trimmedName.isEmpty, !globs.isEmpty {
            throw BridgeCommandError(code: "invalid_argument", message: "A path-scoped rule needs a name, since it is saved as its own file in .claude/rules.")
        }
        let target: String
        switch (scope, trimmedName.isEmpty) {
        case (.global, true): target = environment.homeDirectory + "/.agents/AGENTS.md"
        case (.global, false): target = environment.claudeConfigDirectory + "/rules/\(trimmedName).md"
        case (.repo, _):
            guard let root else {
                throw BridgeCommandError(code: "invalid_argument", message: "Choose one of the task's repositories for a repository rule.")
            }
            target = trimmedName.isEmpty ? root.path + "/AGENTS.md" : root.path + "/.claude/rules/\(trimmedName).md"
        case (.managed, _):
            throw BridgeCommandError(code: "invalid_argument", message: "Your organization manages its CLAUDE.md; Playhouse can't create one.")
        }
        guard !fileManager.fileExists(atPath: target), (try? fileManager.destinationOfSymbolicLink(atPath: target)) == nil else {
            throw BridgeCommandError(code: "already_exists", message: "\(abbreviated(target)) already exists. Open it to edit it instead.")
        }
        try fileManager.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(Self.ruleFile(paths: globs, body: body).utf8).write(to: URL(fileURLWithPath: target), options: .atomic)
        PlayhouseDiagnostics.record("rules.created", fields: ["scope": scope.rawValue, "scoped": String(!globs.isEmpty)])
        let resolved = URL(fileURLWithPath: target).resolvingSymlinksInPath().path
        guard let record = catalog(roots: roots).allRules.first(where: { $0.filePath == resolved }) else {
            throw BridgeCommandError(code: "not_found", message: "The new rule could not be read back.")
        }
        return record
    }

    func update(id: String, content: String, roots: [SkillRoot]) throws -> RuleRecord {
        let record = try editable(id: id, roots: roots)
        try Self.validate(content: content)
        if record.locations.contains(where: \.layout.isRuleFolder), content.hasPrefix("---"), SkillFrontmatter.split(content) == nil {
            throw BridgeCommandError(code: "invalid_argument", message: "Close the frontmatter with a --- line.")
        }
        try Data(content.utf8).write(to: URL(fileURLWithPath: record.filePath), options: .atomic)
        PlayhouseDiagnostics.record("rules.updated", fields: ["scope": record.scope.rawValue])
        return try existing(id: id, roots: roots)
    }

    /// Removes each rule file and every link to it that Playhouse can verify.
    /// Every rule is checked first, so one read-only or missing rule deletes nothing.
    func delete(ids: [String], roots: [SkillRoot]) throws {
        guard !ids.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose at least one rule to delete.")
        }
        let records = try Array(Set(ids)).sorted().map { try editable(id: $0, roots: roots) }
        var disabled = disabledRuleIDs
        defer { preferences.set(Array(disabled).sorted(), forKey: Self.disabledRulesKey) }
        for record in records {
            for location in record.locations where location.isSymlink {
                try removeVerifiedLink(location.path, to: record.filePath)
            }
            try fileManager.removeItem(atPath: record.filePath)
            disabled.remove(record.id)
            PlayhouseDiagnostics.record("rules.deleted", fields: ["scope": record.scope.rawValue])
        }
    }

    func setEnabled(id: String, enabled: Bool, roots: [SkillRoot]) throws -> RuleRecord {
        let record = try existing(id: id, roots: roots)
        guard record.scope != .managed else {
            throw BridgeCommandError(code: "invalid_argument", message: "Your organization's managed CLAUDE.md always applies to Claude Code.")
        }
        var disabled = disabledRuleIDs
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        preferences.set(Array(disabled).sorted(), forKey: Self.disabledRulesKey)
        PlayhouseDiagnostics.record("rules.enabled.changed", fields: ["id": id, "enabled": String(enabled)])
        return try existing(id: id, roots: roots)
    }

    /// Writes real symlinks so the provider that does not read the rule's file
    /// natively finds it outside Playhouse too.
    func link(id: String, roots: [SkillRoot]) throws -> RuleRecord {
        let record = try editable(id: id, roots: roots)
        guard !record.availableOutsidePlayhouse else { return record }
        guard let targets = linkTargets(layouts: Set(record.locations.map(\.layout)), native: Set(record.nativeProviders), rootPath: record.rootPath) else {
            throw BridgeCommandError(code: "invalid_argument", message: Self.unlinkableReason(record))
        }
        for target in targets where fileManager.fileExists(atPath: target) || (try? fileManager.destinationOfSymbolicLink(atPath: target)) != nil {
            throw BridgeCommandError(code: "already_exists", message: "\(abbreviated(target)) already exists, so Playhouse left it unchanged. Merge the two files to share one.")
        }
        for target in targets {
            let folder = (target as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let destination = record.scope == .repo ? SkillCatalogManager.relativePath(from: folder, to: record.filePath) : record.filePath
            try fileManager.createSymbolicLink(atPath: target, withDestinationPath: destination)
            PlayhouseDiagnostics.record("rules.linked", fields: ["scope": record.scope.rawValue])
        }
        return try existing(id: id, roots: roots)
    }

    /// Where symlinks would let each provider that does not read the rule find
    /// it on its own, or nil when one of them has no place for it.
    private func linkTargets(layouts: Set<RuleLayout>, native: Set<ConversationProvider>, rootPath: String?) -> [String]? {
        var targets: [String] = []
        if !native.contains(.codex) {
            if layouts.contains(.claude), let rootPath {
                targets.append(rootPath + "/AGENTS.md")
            } else if layouts.contains(.claudeGlobal) || layouts.contains(.sharedGlobal) {
                targets.append(environment.codexHome + "/AGENTS.md")
            }
        }
        if !native.contains(.claude),
           layouts.contains(.codexGlobal) || layouts.contains(.codexGlobalOverride) || layouts.contains(.sharedGlobal) {
            targets.append(environment.claudeConfigDirectory + "/CLAUDE.md")
        }
        let missing = Set(ConversationProvider.allCases).subtracting(native)
        return targets.count == missing.count && !targets.isEmpty ? targets : nil
    }

    private static func unlinkableReason(_ record: RuleRecord) -> String {
        let layouts = Set(record.locations.map(\.layout))
        if layouts.contains(.agents) {
            return "Claude Code reads CLAUDE.md here instead of AGENTS.md. Add a line with @AGENTS.md to CLAUDE.md so it reads both."
        }
        if layouts.contains(.agentsOverride) { return "AGENTS.override.md is Codex's own override; Claude Code has no equivalent." }
        if layouts.contains(.claudeLocal) { return "CLAUDE.local.md is personal; linking it to the shared AGENTS.md would publish it." }
        return "Codex reads one AGENTS.md per folder, so it has no place for a separate rule file."
    }

    func unlink(id: String, roots: [SkillRoot]) throws -> RuleRecord {
        let record = try editable(id: id, roots: roots)
        let links = record.locations.filter(\.isSymlink)
        guard !links.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "\(record.name) has no link that Playhouse can remove.")
        }
        for link in links { try removeVerifiedLink(link.path, to: record.filePath) }
        PlayhouseDiagnostics.record("rules.unlinked", fields: ["scope": record.scope.rawValue])
        return try existing(id: id, roots: roots)
    }

    /// What a task needs so an agent can repair problem rules: repository rules
    /// in the new task's own worktree, committed like any change, and global
    /// rules in place.
    func fixPlan(ids: [String], roots: [SkillRoot]) throws -> SkillFixPlan {
        guard !ids.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose at least one rule to fix.")
        }
        var seen = Set<String>()
        let records = try ids.filter { seen.insert($0).inserted }.map { id in
            let record = try editable(id: id, roots: roots)
            guard record.issue != nil else {
                throw BridgeCommandError(code: "invalid_argument", message: "\(record.name) has no problem to fix.")
            }
            return record
        }
        let repoRules = records.filter { $0.scope == .repo }
        let globalRules = records.filter { $0.scope == .global }
        var lines = [
            "Fix the following agent rule files so both Claude Code and Codex can follow them.",
            "",
            "How rules work:",
            "- Codex reads AGENTS.md (or AGENTS.override.md) in each folder from the repository root down, up to 32 KiB in total, and one AGENTS.md in its home folder.",
            "- Claude Code reads CLAUDE.md, .claude/CLAUDE.md, CLAUDE.local.md and .claude/rules/*.md, and AGENTS.md when no CLAUDE.md is beside it. A line holding only @path imports that file.",
            "- A file in .claude/rules may start with frontmatter between --- lines whose `paths` list limits it to matching files.",
            "- Keep rules short and specific, and remove instructions that contradict each other.",
        ]
        if !repoRules.isEmpty {
            lines += ["", "Repository rules. These are committed to Git: fix them in this task's worktree like any other code change, then commit and push so the fix goes through review. Paths are relative to the repository root."]
            for record in repoRules {
                let repository = URL(fileURLWithPath: record.repositoryPath ?? "").lastPathComponent
                lines.append("- `\(record.name)` in \(repository). Problem: \(record.issue ?? "")")
            }
        }
        if !globalRules.isEmpty {
            lines += ["", "Global rules. These live in the user's home folder and are not tracked by Git: fix them directly in place. There is nothing to commit or push for them."]
            for record in globalRules {
                lines.append("- `\(record.filePath)`. Problem: \(record.issue ?? "")")
            }
        }
        lines += ["", "When you are done, list each rule and what you changed."]
        let names = records.map(\.name)
        let title = names.count == 1 ? "Fix rule \(names[0])" : "Fix \(names.count) rules"
        var repositories: [String] = []
        for record in repoRules {
            if let path = record.repositoryPath, !repositories.contains(path) { repositories.append(path) }
        }
        var folders: [String] = []
        for record in globalRules {
            let folder = (record.filePath as NSString).deletingLastPathComponent
            if !folders.contains(folder) { folders.append(folder) }
        }
        PlayhouseDiagnostics.record("rules.fix.planned", fields: ["ruleCount": String(records.count)])
        return SkillFixPlan(title: title, prompt: lines.joined(separator: "\n"), repositoryPaths: repositories, contextFolders: folders)
    }

    private func existing(id: String, roots: [SkillRoot]) throws -> RuleRecord {
        guard let record = catalog(roots: roots).rule(id: id) else {
            throw BridgeCommandError(code: "not_found", message: "No rule matches \(id).")
        }
        return record
    }

    private func editable(id: String, roots: [SkillRoot]) throws -> RuleRecord {
        let record = try existing(id: id, roots: roots)
        guard record.editable else {
            throw BridgeCommandError(code: "invalid_argument", message: "Your organization manages \(record.name), so it is read-only.")
        }
        return record
    }

    private func removeVerifiedLink(_ path: String, to file: String) throws {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == file else {
            throw BridgeCommandError(code: "invalid_argument", message: "\(path) is not a link to this rule, so Playhouse left it unchanged.")
        }
        try fileManager.removeItem(atPath: path)
    }

    // MARK: Bridge

    /// What a launch passes each provider so it follows the rules it would not
    /// read on its own, and hides the turned-off rules Claude Code reads itself.
    func bridge(roots: [SkillRoot]) -> RuleBridgeLaunch {
        let entries = self.entries(roots: roots)
        var launch = RuleBridgeLaunch()
        for entry in entries where !entry.record.enabled && entry.nativeInLaunch.contains(.claude) && entry.record.scope != .managed {
            launch.claudeExcludes += entry.record.locations.map(\.path) + [entry.record.filePath]
        }
        launch.claudeExcludes = Array(Set(launch.claudeExcludes)).sorted()
        // The working repository's AGENTS.md is skipped by Claude Code when a
        // CLAUDE.md is beside it, unless told to read both.
        if let working = entries.first(where: { $0.rootIndex == 0 && $0.record.locations.contains { $0.layout == .agents } }),
           working.record.enabled,
           entries.contains(where: { $0.rootIndex == 0 && $0.record.id != working.record.id && $0.record.locations.contains { [RuleLayout.claude, .claudeLocal].contains($0.layout) } }) {
            launch.claudeReadsAgentsAlongsideClaude = true
        }
        for provider in [ConversationProvider.claude, .codex] {
            let shared = entries.filter {
                $0.record.enabled && !$0.nativeInLaunch.contains(provider) && !$0.withheld.contains(provider)
                    && !$0.contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let native = Set(entries.filter { $0.nativeInLaunch.contains(provider) }.map(\.record.filePath))
            let records = shared.map { RuleBridgeLaunch.SharedRule(id: $0.record.id, name: $0.record.name, path: $0.record.filePath, paths: $0.record.paths) }
            let text = instructions(shared, provider: provider, alreadyLoaded: native)
            switch provider {
            case .claude: launch.claudeShared = records; launch.claudeInstructions = text
            case .codex: launch.codexShared = records; launch.codexInstructions = text
            }
        }
        return launch
    }

    private func instructions(_ entries: [Entry], provider: ConversationProvider, alreadyLoaded: Set<String>) -> String? {
        guard !entries.isEmpty else { return nil }
        let always = entries.filter { $0.record.paths.isEmpty }
        let scoped = entries.filter { !$0.record.paths.isEmpty }
        var included = alreadyLoaded.union(always.map(\.record.filePath))
        var lines = [
            "# Rules Playhouse shares with you",
            "",
            "\(provider.displayName) does not load these instruction files on its own in this workspace, so Playhouse includes them. Follow them as you follow the instruction files you load yourself; a later, more specific file wins over an earlier one.",
        ]
        for entry in always {
            let heading = entry.repositoryName.map { "\($0): \(entry.record.name)" } ?? entry.record.name
            lines += ["", "## \(heading)", "", expandingImports(entry.contents, file: entry.record.filePath, included: &included, depth: 0)
                .trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        if !scoped.isEmpty {
            lines += ["", "## Path-scoped rules", "", "Before you read or edit a file matching one of these patterns, read the rule file it names and follow it:"]
            for entry in scoped {
                let place = entry.repositoryName.map { " in \($0)" } ?? ""
                lines.append("- \(entry.record.paths.map { "`\($0)`" }.joined(separator: ", "))\(place): \(entry.record.filePath)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Inlines `@path` imports, which neither provider expands in injected
    /// text. A file already loaded or included is left out rather than repeated.
    private func expandingImports(_ contents: String, file: String, included: inout Set<String>, depth: Int) -> String {
        var inFence = false
        var output: [String] = []
        for line in contents.components(separatedBy: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("```") || text.hasPrefix("~~~") { inFence.toggle() }
            guard !inFence, Self.imports(in: text).count == 1, let target = resolveImport(String(text.dropFirst()), from: file) else {
                output.append(line)
                continue
            }
            guard depth < Self.importDepth, included.insert(target).inserted,
                  let imported = try? String(contentsOfFile: target, encoding: .utf8) else { continue }
            output.append(expandingImports(imported, file: target, included: &included, depth: depth + 1)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output.joined(separator: "\n")
    }
}
