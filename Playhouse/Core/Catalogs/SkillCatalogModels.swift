import Foundation

/// otherwise see it.
package enum SkillLayout: String, Codable, Sendable {
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
    /// `<Playhouse data>/private-skills/<repository key>/.claude/skills`: a
    /// repository's private skills, which Playhouse keeps out of the repository
    /// and bridges into both providers' sessions for that repository only.
    case playhousePrivate

    package var displayPath: String {
        switch self {
        case .agents: ".agents/skills"
        case .claude: ".claude/skills"
        case .codexLegacy: "Codex skills"
        case .codexSystem: "Codex built-in"
        case .claudeSynced: "claude.ai synced"
        case .claudeBundled: "Claude Code built-in"
        case .playhousePrivate: "Private, stored by Playhouse"
        }
    }
}

package enum SkillScope: String, Codable, Sendable, CaseIterable {
    case repo
    case global
    case builtin
    /// Belongs to one repository but is never written into it or its worktrees.
    case privateRepo = "private"
}

package struct SkillLocation: Codable, Equatable, Sendable {
    /// The skill folder as found, which can be a symlink.
    package let path: String
    package let layout: SkillLayout
    package let isSymlink: Bool

    package init(path: String, layout: SkillLayout, isSymlink: Bool) {
        self.path = path
        self.layout = layout
        self.isSymlink = isSymlink
    }
}

package struct SkillRecord: Codable, Equatable, Identifiable, Sendable {
    /// Stable across tasks: a repo skill is keyed by its source repository, not
    /// the task worktree, so its enabled state follows the repository.
    package let id: String
    package let name: String
    package let description: String
    package let scope: SkillScope
    package let repositoryPath: String?
    /// The task root the repo skill was read from.
    package let rootPath: String?
    /// The resolved skill folder that edits, moves, and deletes act on.
    package let folderPath: String?
    package let locations: [SkillLocation]
    /// Providers that can use the skill in sessions Playhouse launches.
    package let providers: [ConversationProvider]
    package let enabled: Bool
    package let editable: Bool
    /// Both providers read the skill natively, so it also works outside Playhouse.
    package let availableOutsidePlayhouse: Bool
    package let conflict: Bool
    package let issue: String?
    /// What to type after `/` when it differs from `name`: a private skill whose
    /// name an earlier repository's private skill of the task already uses is
    /// namespaced as `<repository>:<name>`, the way Claude Code names it.
    package var invocationName: String? = nil
    /// For a private skill no provider uses: where the skill with the same
    /// name that takes precedence lives.
    package var shadowedBy: String? = nil
    /// What differs on OpenCode: why it doesn't use the skill, or that it still uses one turned off.
    package var providerNote: String? = nil

    /// `/name`, or `/<repository>:<name>` for a namespaced private skill.
    package var invocationToken: String { "/" + (invocationName ?? name) }

    package func adjusted(
        providers: [ConversationProvider]? = nil, issue: String?? = nil, invocationName: String?? = nil, shadowedBy: String?? = nil,
        providerNote: String?? = nil
    ) -> SkillRecord {
        var copy = SkillRecord(
            id: id, name: name, description: description, scope: scope, repositoryPath: repositoryPath, rootPath: rootPath,
            folderPath: folderPath, locations: locations, providers: providers ?? self.providers, enabled: enabled, editable: editable,
            availableOutsidePlayhouse: availableOutsidePlayhouse, conflict: conflict, issue: issue ?? self.issue
        )
        copy.invocationName = invocationName ?? self.invocationName
        copy.shadowedBy = shadowedBy ?? self.shadowedBy
        copy.providerNote = providerNote ?? self.providerNote
        return copy
    }

    package init(id: String, name: String, description: String, scope: SkillScope, repositoryPath: String?, rootPath: String?, folderPath: String?, locations: [SkillLocation], providers: [ConversationProvider], enabled: Bool, editable: Bool, availableOutsidePlayhouse: Bool, conflict: Bool, issue: String?, invocationName: String? = nil, shadowedBy: String? = nil, providerNote: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.scope = scope
        self.repositoryPath = repositoryPath
        self.rootPath = rootPath
        self.folderPath = folderPath
        self.locations = locations
        self.providers = providers
        self.enabled = enabled
        self.editable = editable
        self.availableOutsidePlayhouse = availableOutsidePlayhouse
        self.conflict = conflict
        self.issue = issue
        self.invocationName = invocationName
        self.shadowedBy = shadowedBy
        self.providerNote = providerNote
    }
}

package struct SkillRepositorySection: Codable, Equatable, Sendable {
    package let repositoryPath: String
    package let rootPath: String
    package let name: String
    package let skills: [SkillRecord]

    package init(repositoryPath: String, rootPath: String, name: String, skills: [SkillRecord]) {
        self.repositoryPath = repositoryPath
        self.rootPath = rootPath
        self.name = name
        self.skills = skills
    }
}

package struct SkillCatalog: Codable, Equatable, Sendable {
    package let repositories: [SkillRepositorySection]
    package let global: [SkillRecord]
    package let builtin: [SkillRecord]

    package var allSkills: [SkillRecord] { repositories.flatMap(\.skills) + global + builtin }
    package func skill(id: String) -> SkillRecord? { allSkills.first { $0.id == id } }

    /// The same catalog with one skill's record swapped for a newer one.
    package func replacing(_ record: SkillRecord) -> SkillCatalog {
        func swap(_ skills: [SkillRecord]) -> [SkillRecord] { skills.map { $0.id == record.id ? record : $0 } }
        return SkillCatalog(
            repositories: repositories.map {
                SkillRepositorySection(repositoryPath: $0.repositoryPath, rootPath: $0.rootPath, name: $0.name, skills: swap($0.skills))
            },
            global: swap(global),
            builtin: swap(builtin)
        )
    }

    package init(repositories: [SkillRepositorySection], global: [SkillRecord], builtin: [SkillRecord]) {
        self.repositories = repositories
        self.global = global
        self.builtin = builtin
    }
}

/// The task Playhouse opens so an agent can repair broken skills.
package struct SkillFixPlan: Equatable, Sendable {
    package let title: String
    package let prompt: String
    /// Source repositories whose skills the task fixes in its own worktrees.
    package let repositoryPaths: [String]
    /// Global skill folders the agent edits in place.
    package let contextFolders: [String]

    package init(title: String, prompt: String, repositoryPaths: [String], contextFolders: [String]) {
        self.title = title
        self.prompt = prompt
        self.repositoryPaths = repositoryPaths
        self.contextFolders = contextFolders
    }
}

/// A skill a message invokes, so a provider without slash commands can be
/// handed the skill directly.
package struct SkillInvocation: Codable, Equatable, Sendable {
    package let name: String
    package let path: String

    package init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// What a provider launch needs so it sees every skill in the gallery. Claude
/// Code runs one process per turn, so its part is exact per launch. Codex shares
/// one app-server across tasks, so its extra roots are the union of every
/// task's bridge folder and each thread hides the folders that are not its own.
package struct SkillBridgeLaunch: Codable, Equatable, Sendable {
    package struct BridgedSkill: Codable, Equatable, Sendable {
        package let name: String
        package let source: String
        package let link: String

        package init(name: String, source: String, link: String) {
            self.name = name
            self.source = source
            self.link = link
        }
    }

    package var claudeAddDirectories: [String] = []
    package var claudeDisabledSkillNames: [String] = []
    package var claudeLinks: [BridgedSkill] = []
    package var codexExtraRoots: [String] = []
    package var codexDisabledSkillPaths: [String] = []
    package var codexLinks: [BridgedSkill] = []
    package var invocations: [SkillInvocation] = []

    /// `--settings` entries that hide disabled skills from Claude Code for this run only.
    package var claudeSettings: [String: Any] {
        guard !claudeDisabledSkillNames.isEmpty else { return [:] }
        return ["skillOverrides": Dictionary(uniqueKeysWithValues: claudeDisabledSkillNames.map { ($0, "off") })]
    }

    /// Per-thread Codex config that hides disabled and other tasks' bridged skills
    /// without writing to the user's `config.toml`.
    package var codexThreadConfig: [String: Any]? {
        guard !codexDisabledSkillPaths.isEmpty else { return nil }
        return ["skills": ["config": codexDisabledSkillPaths.map { ["path": $0, "enabled": false] }]]
    }

    package init(claudeAddDirectories: [String] = [], claudeDisabledSkillNames: [String] = [], claudeLinks: [BridgedSkill] = [], codexExtraRoots: [String] = [], codexDisabledSkillPaths: [String] = [], codexLinks: [BridgedSkill] = [], invocations: [SkillInvocation] = []) {
        self.claudeAddDirectories = claudeAddDirectories
        self.claudeDisabledSkillNames = claudeDisabledSkillNames
        self.claudeLinks = claudeLinks
        self.codexExtraRoots = codexExtraRoots
        self.codexDisabledSkillPaths = codexDisabledSkillPaths
        self.codexLinks = codexLinks
        self.invocations = invocations
    }
}

/// The folders the skill gallery and the rule set read. Production uses the
/// user's own homes; debug bridge tests point every one at isolated fixtures.
package struct SkillEnvironment: Equatable, Sendable {
    /// The folder whose `.agents/skills` holds global skills.
    package var homeDirectory: String
    package var claudeConfigDirectory: String
    /// Claude Code's state file, which holds its user MCP servers: `~/.claude.json`,
    /// or `.claude.json` inside a configured `CLAUDE_CONFIG_DIR`.
    package var claudeStateFile: String
    package var codexHome: String
    /// OpenCode's global configuration folder (`$XDG_CONFIG_HOME/opencode`, else `~/.config/opencode`),
    /// which holds its own agents and global AGENTS.md.
    package var openCodeConfigDirectory: String = NSHomeDirectory() + "/.config/opencode"

    /// OpenCode's Claude Code compatibility reads `~/.claude` of the home it runs with, which is
    /// Claude Code's own folder unless `CLAUDE_CONFIG_DIR` moved it.
    package var openCodeReadsClaudeHome: Bool {
        URL(fileURLWithPath: claudeConfigDirectory).standardizedFileURL.path
            == URL(fileURLWithPath: homeDirectory + "/.claude").standardizedFileURL.path
    }
    /// Where an organization deploys Claude Code's managed CLAUDE.md and managed-mcp.json.
    package var managedClaudeDirectory: String
    /// Playhouse-owned folder for bridge wrappers.
    package var bridgeDirectory: String
    /// Playhouse-owned store of private repository skills, one folder per repository.
    package var privateSkillsDirectory: String

    package static func resolve(
        homeOverride: String? = nil,
        claudeConfigOverride: String? = nil,
        codexHomeOverride: String? = nil,
        storeDirectory: String?
    ) -> SkillEnvironment {
        let environment = PlayhouseProcessEnvironment.current
        let home = homeOverride ?? environment["HOME"] ?? NSHomeDirectory()
        let configuredClaude = claudeConfigOverride
            ?? (homeOverride == nil ? environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } : nil)
        let claude = configuredClaude ?? home + "/.claude"
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
            claudeStateFile: configuredClaude.map { $0 + "/.claude.json" } ?? home + "/.claude.json",
            codexHome: codex,
            openCodeConfigDirectory: homeOverride.map { $0 + "/.config/opencode" }
                ?? (environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config") + "/opencode",
            managedClaudeDirectory: homeOverride.map { $0 + "/managed/ClaudeCode" } ?? "/Library/Application Support/ClaudeCode",
            bridgeDirectory: URL(fileURLWithPath: data).appendingPathComponent("skill-bridge").path,
            privateSkillsDirectory: URL(fileURLWithPath: data).appendingPathComponent("private-skills").path
        )
    }

    package init(homeDirectory: String, claudeConfigDirectory: String, claudeStateFile: String, codexHome: String, openCodeConfigDirectory: String = NSHomeDirectory() + "/.config/opencode", managedClaudeDirectory: String, bridgeDirectory: String, privateSkillsDirectory: String) {
        self.homeDirectory = homeDirectory
        self.claudeConfigDirectory = claudeConfigDirectory
        self.claudeStateFile = claudeStateFile
        self.codexHome = codexHome
        self.openCodeConfigDirectory = openCodeConfigDirectory
        self.managedClaudeDirectory = managedClaudeDirectory
        self.bridgeDirectory = bridgeDirectory
        self.privateSkillsDirectory = privateSkillsDirectory
    }
}

/// One task root, with the source repository that identifies its skills.
package struct SkillRoot: Equatable, Sendable {
    package let path: String
    package let repositoryPath: String

    package var name: String { URL(fileURLWithPath: repositoryPath).lastPathComponent }

    package static func roots(for task: any ConversationSubject) -> [SkillRoot] {
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

    package init(path: String, repositoryPath: String) {
        self.path = path
        self.repositoryPath = repositoryPath
    }
}

