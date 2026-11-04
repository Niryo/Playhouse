import Foundation
import SwiftData
import SwiftUI

enum TaskStatus: String, CaseIterable, Identifiable {
    case backlog = "Backlog"
    case inProgress = "In Progress"
    case blocked = "Blocked"
    case waitingResponse = "Waiting Response"
    case review = "Review"
    case done = "Done"

    var id: String {
        rawValue
    }

    var accessibilityKey: String {
        rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    var accent: Color {
        switch self {
        case .backlog: Color(red: 0.52, green: 0.57, blue: 0.66)
        case .inProgress: Color(red: 0.75, green: 0.48, blue: 0.20)
        case .blocked: Color(red: 0.82, green: 0.30, blue: 0.30)
        case .waitingResponse: Color(red: 0.64, green: 0.44, blue: 0.80)
        case .review: Color(red: 0.28, green: 0.51, blue: 0.82)
        case .done: Color(red: 0.20, green: 0.62, blue: 0.45)
        }
    }
}

/// The heatmap a task's token usage dot is read from: a light green at zero
/// warming through orange to red as usage approaches the configured maximum.
enum TokenUsageHeatmap {
    /// Canonical default ceiling, defined here rather than in `WorkspaceSettings`
    /// (`WorkspaceSupport.swift`) because `scripts/seed-task-pr-link.swift`
    /// compiles `BoardTask.swift` standalone as a small seeding utility and must
    /// not gain a dependency on the rest of the app module.
    static let defaultColorMax = 20_000_000

    /// Hue in SwiftUI's 0...1 space: 0.33 is green, 0.0 is red. Orange falls out
    /// of the interpolation between them, so the scale reads as one ramp.
    private static let greenHue = 0.33
    private static let redHue = 0.0

    static func color(totalTokens: Int, max: Int) -> Color {
        // Matches WorkspaceSettingsManager.tokenUsageColorMax's own fallback, so
        // a stored zero or negative value reads the same here as it does there
        // instead of this view alone forcing the dot to full red.
        let ceiling = max > 0 ? max : defaultColorMax
        let fraction = Swift.min(1, Swift.max(0, Double(totalTokens) / Double(ceiling)))
        return Color(
            hue: greenHue + (redHue - greenHue) * fraction,
            // A pale green at zero deepens as it warms, so low usage stays quiet.
            saturation: 0.45 + 0.45 * fraction,
            brightness: 0.80
        )
    }

    /// The counter's compact form: `842`, `12.4K`, `273K`, `1.2M`.
    static func compact(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000: return "\(Swift.max(0, tokens))"
        case ..<100_000: return trimmed(Double(tokens) / 1_000) + "K"
        case ..<999_500: return "\(Int((Double(tokens) / 1_000).rounded()))K"
        default: return trimmed(Double(tokens) / 1_000_000) + "M"
        }
    }

    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    static func label(totalTokens: Int) -> String {
        switch totalTokens {
        case 0: "No tokens used yet"
        case ..<1_000: "\(totalTokens) tokens used"
        case ..<1_000_000: "\(totalTokens / 1_000)K tokens used"
        default: String(format: "%.1fM tokens used", Double(totalTokens) / 1_000_000)
        }
    }
}

/// The gradient a running task's live CPU usage bar fills from the bottom:
/// green at 0%, red once a task's process tree reaches the configured
/// ceiling. Unlike `TokenUsageHeatmap`'s single interpolated color, this bar
/// is a thermometer-style gauge, so the gradient itself is fixed and only
/// the filled height (the revealed fraction) changes.
enum CPUUsageHeatmap {
    /// One fully busy core per logical CPU, matching the Activity Monitor
    /// convention where 100% == one core. See `TokenUsageHeatmap.defaultColorMax`
    /// for why this lives here rather than in `WorkspaceSettings`.
    static var defaultColorMax: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) * 100 }

    static func fraction(percent: Double, max: Int) -> Double {
        let ceiling = max > 0 ? Double(max) : Double(defaultColorMax)
        return Swift.min(1, Swift.max(0, percent / ceiling))
    }

    static let gradient = LinearGradient(
        colors: [
            Color(hue: 0.33, saturation: 0.7, brightness: 0.75),
            Color(hue: 0.0, saturation: 0.7, brightness: 0.75)
        ],
        startPoint: .bottom,
        endPoint: .top
    )

    static func label(percent: Double) -> String {
        "CPU \(Int(percent.rounded()))%"
    }
}

/// The agent runtime that executes a task's conversation turns.
enum ConversationProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

enum TaskProgressType: String, CaseIterable, Identifiable {
    case planning
    case searching
    case building
    case running
    case testing
    case reviewing
    case writing
    case committing

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .planning: "map"
        case .searching: "magnifyingglass"
        case .building: "hammer"
        case .running: "play.fill"
        case .testing: "checkmark.seal"
        case .reviewing: "eye"
        case .writing: "pencil.line"
        case .committing: "arrow.triangle.branch"
        }
    }
}

@Model
final class BoardTask {
    var id: UUID
    var title: String
    var statusRawValue: String
    var lifecycleRevision: Int = 0
    var statusMessage: String?
    var progressTypeRawValue: String?
    var progressLabel: String?
    var progressDetail: String?
    var createdAt: Date
    var inProgressStartedAt: Date?
    var totalInProgressSeconds: Double = 0
    var codexThreadID: String?
    var claudeSessionID: String?
    /// Nil for tasks created before provider selection; those use Codex.
    var conversationProviderRawValue: String?
    var conversationEffortRawValue: String?
    // Retained for one-time migration to the global provider model preference.
    var conversationModelIDsData: Data?
    var savedPrompt: String?
    var pendingSubmittedPrompt: String?
    var workspaceRootPathsData: Data?
    var repositoryWorktreesData: Data?
    var contextFolderPathsData: Data?
    var draftImageDataURLsData: Data?
    var conversationActivityDurationsData: Data?
    var answeredAsyncQuestionIDsData: Data?
    var viewedWorkspaceChangesData: Data?
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    var totalCacheReadTokens: Int = 0
    var totalCacheCreationTokens: Int = 0
    var callUsageSnapshotsData: Data?
    /// When true, moving this task to Review automatically creates its pull request(s)
    /// instead of waiting for the user to click the manual "PR" control.
    var autoCreatePullRequestOnReview: Bool = false
    /// When true (with `autoCreatePullRequestOnReview`), Playhouse keeps following the
    /// task's pull requests in Review and sends fix turns until checks pass and every
    /// review thread is resolved.
    var pullRequestAutopilot: Bool = false
    /// When true (with `pullRequestAutopilot`), autopilot also merges the pull
    /// requests once they're green.
    var pullRequestAutoMerge: Bool = false
    /// Autopilot fix turns sent since the pull requests were last green; bounds the loop.
    var pullRequestAutopilotFixAttempts: Int = 0
    /// The PR state the last autopilot fix turn was sent for, so an unchanged red state
    /// is not sent again.
    var pullRequestAutopilotLastFixSignature: String?
    /// Legacy marker from when the standalone chat was a hidden board task. Nothing reads it
    /// for behavior; it exists so `migrateLegacyStandaloneChatTasks()` can find those rows and
    /// convert them to `StandaloneChat`. The original column name is preserved so the migration
    /// can still see data written before the split.
    @Attribute(originalName: "isStandaloneChat") var legacyStandaloneChatMarker: Bool = false

    var workspaceRootPaths: [String] {
        get {
            guard let workspaceRootPathsData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: workspaceRootPathsData)) ?? []
        }
        set {
            workspaceRootPathsData = try? JSONEncoder().encode(newValue)
        }
    }

    var repositoryWorktrees: [RepositoryWorktreeRecord] {
        get { guard let repositoryWorktreesData else { return [] }; return (try? JSONDecoder().decode([RepositoryWorktreeRecord].self, from: repositoryWorktreesData)) ?? [] }
        set { repositoryWorktreesData = try? JSONEncoder().encode(newValue) }
    }

    var contextFolderPaths: [String] {
        get { guard let contextFolderPathsData else { return workspaceRootPaths }; return (try? JSONDecoder().decode([String].self, from: contextFolderPathsData)) ?? [] }
        set { contextFolderPathsData = try? JSONEncoder().encode(newValue) }
    }

    init(title: String, status: TaskStatus = .backlog, workspaceRootPaths: [String] = [], conversationProvider: ConversationProvider = .codex) {
        id = UUID()
        self.title = title
        statusRawValue = status.rawValue
        statusMessage = nil
        progressTypeRawValue = nil
        progressLabel = nil
        progressDetail = nil
        createdAt = .now
        inProgressStartedAt = status == .inProgress ? .now : nil
        totalInProgressSeconds = 0
        codexThreadID = nil
        claudeSessionID = nil
        conversationProviderRawValue = conversationProvider.rawValue
        conversationEffortRawValue = "medium"
        conversationModelIDsData = nil
        savedPrompt = nil
        pendingSubmittedPrompt = nil
        workspaceRootPathsData = try? JSONEncoder().encode(workspaceRootPaths)
        repositoryWorktreesData = nil
        contextFolderPathsData = nil
        draftImageDataURLsData = nil
        conversationActivityDurationsData = nil
        answeredAsyncQuestionIDsData = nil
        viewedWorkspaceChangesData = nil
    }
}

/// What reaching Review does with a task's pull requests: nothing (the user creates
/// them), create them, or create them and keep fixing them until they're green.
enum PullRequestMode: String, CaseIterable, Codable, Sendable {
    case manual
    case pullRequest = "pr"
    case autopilot
    case merge

    var label: String {
        switch self {
        case .manual: "Manual"
        case .pullRequest: "PR"
        case .autopilot: "Green"
        case .merge: "Merge"
        }
    }

    var helpText: String {
        switch self {
        case .manual: "Manual: you open the pull request yourself"
        case .pullRequest: "PR: open the pull request when the task reaches Review"
        case .autopilot: "Green: open the PR, then fix failing checks and review comments until it's green"
        case .merge: "Merge: like Green, then merge the PR once it's green"
        }
    }
}

extension BoardTask {
    var pullRequestMode: PullRequestMode {
        if pullRequestAutopilot { return pullRequestAutoMerge ? .merge : .autopilot }
        return autoCreatePullRequestOnReview ? .pullRequest : .manual
    }
}

struct RepositoryWorktreeSpec: Codable, Equatable, Sendable {
    var repositoryPath: String
    var branch: String?
    var branchFrom: String?
    var mergeTarget: String? = nil
}

struct RepositoryWorktreeRecord: Codable, Equatable, Sendable {
    var repositoryPath: String
    var branch: String
    var worktreePath: String
    var branchFrom: String
    var createdByPlayhouse: Bool
    var mergeTarget: String? = nil
    var isPending: Bool = false
    var pullRequestNumber: Int? = nil
    var pullRequestURL: String? = nil

    private enum CodingKeys: String, CodingKey {
        case repositoryPath, branch, worktreePath, branchFrom, createdByPlayhouse
        case mergeTarget, isPending, pullRequestNumber, pullRequestURL
    }

    init(
        repositoryPath: String,
        branch: String,
        worktreePath: String,
        branchFrom: String,
        createdByPlayhouse: Bool,
        mergeTarget: String? = nil,
        isPending: Bool = false,
        pullRequestNumber: Int? = nil,
        pullRequestURL: String? = nil
    ) {
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.worktreePath = worktreePath
        self.branchFrom = branchFrom
        self.createdByPlayhouse = createdByPlayhouse
        self.mergeTarget = mergeTarget
        self.isPending = isPending
        self.pullRequestNumber = pullRequestNumber
        self.pullRequestURL = pullRequestURL
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        repositoryPath = try values.decode(String.self, forKey: .repositoryPath)
        branch = try values.decode(String.self, forKey: .branch)
        worktreePath = try values.decode(String.self, forKey: .worktreePath)
        branchFrom = try values.decode(String.self, forKey: .branchFrom)
        createdByPlayhouse = try values.decode(Bool.self, forKey: .createdByPlayhouse)
        mergeTarget = try values.decodeIfPresent(String.self, forKey: .mergeTarget)
        isPending = try values.decodeIfPresent(Bool.self, forKey: .isPending) ?? false
        pullRequestNumber = try values.decodeIfPresent(Int.self, forKey: .pullRequestNumber)
        pullRequestURL = try values.decodeIfPresent(String.self, forKey: .pullRequestURL)
    }
}
