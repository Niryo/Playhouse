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

    /// The statuses a user may move to Review by hand.
    static let manualReviewSources: Set<TaskStatus> = [.waitingResponse, .blocked]
    /// The statuses a user may move to Done by hand.
    static let manualDoneSources: Set<TaskStatus> = [.review, .waitingResponse, .blocked]

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
    /// The unsent composer draft when `hasUnsentDraft` is true; otherwise the last prompt
    /// saved or sent, which can already be in the conversation.
    var savedPrompt: String?
    var pendingSubmittedPrompt: String?
    /// True while `savedPrompt` and the draft images are the user's unsent composer draft,
    /// rather than the last prompt that was sent.
    var hasUnsentDraft: Bool = false
    var workspaceRootPathsData: Data?
    var repositoryWorktreesData: Data?
    /// Repository worktree records retired by `task repository renew` after their pull
    /// request merged. They keep the merged PR link on the card; their worktrees are gone.
    var pastRepositoryWorktreesData: Data?
    var contextFolderPathsData: Data?
    var draftImageDataURLsData: Data?
    /// Review comments the user has written but not sent, encoded as JSON. Optional so tasks
    /// stored before this field existed load unchanged.
    var pendingAnnotationsData: Data?
    /// Side chats on selected conversation text, encoded as JSON (`SavedSideChats`).
    var sideChatsData: Data?
    var conversationActivityDurationsData: Data?
    var answeredAsyncQuestionIDsData: Data?
    var viewedWorkspaceChangesData: Data?
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    var totalCacheReadTokens: Int = 0
    var totalCacheCreationTokens: Int = 0
    var callUsageSnapshotsData: Data?
    /// Legacy pull request mode columns, from before the `pull-request-mode`
    /// plugin kept each task's mode in its own state. Only the one-time import
    /// (`legacyPullRequestMode`) reads them; a new task gets the default mode's
    /// value, as tasks did before.
    var autoCreatePullRequestOnReview: Bool = false
    var pullRequestAutopilot: Bool = false
    var pullRequestAutoMerge: Bool = false
    /// The column the task was in when it last saved, while a move is unsaved;
    /// saving publishes the move to plugins as `task.statusChanged`.
    @Transient var statusBeforeSave: String? = nil
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
    /// Nil for an ordinary task; otherwise a `TaskScheduleKind`. A one-time schedule is a
    /// Backlog task whose first prompt is sent at `scheduledAt`. A recurring schedule is a
    /// template that stays off the board and starts a new task at each occurrence.
    var scheduleKindRawValue: String?
    /// When a one-time schedule fires, or a recurring schedule's next occurrence.
    var scheduledAt: Date?
    var scheduleRecurrenceData: Data?
    /// The confirmed prompt a schedule sends. Kept apart from `savedPrompt`, which the
    /// composer autosaves while the user edits, so an unconfirmed edit never fires.
    var scheduledPrompt: String?
    var scheduledImageDataURLsData: Data?
    var scheduledModeRawValue: String?
    var scheduledModelID: String?
    var schedulePaused: Bool = false
    var lastScheduledRunAt: Date?
    var lastScheduledRunTaskID: UUID?
    /// The recurring schedule that started this task, if any.
    var scheduleSourceTaskID: UUID?
    /// Set on a task started from an Add Plugin mode placeholder: the `PluginPlacement`
    /// the new plugin's entry goes in. Its conversation gets plugin authoring instructions.
    var pluginPlacement: String?
    /// Identifies the plugin being authored so its preview survives reopening.
    var authoredPluginID: String?

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

    var pastRepositoryWorktrees: [RepositoryWorktreeRecord] {
        get { guard let pastRepositoryWorktreesData else { return [] }; return (try? JSONDecoder().decode([RepositoryWorktreeRecord].self, from: pastRepositoryWorktreesData)) ?? [] }
        set { pastRepositoryWorktreesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
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
        // Reads as the default mode, so the legacy import never gives a task
        // created since the plugin owned the mode one it didn't choose.
        autoCreatePullRequestOnReview = true
        repositoryWorktreesData = nil
        contextFolderPathsData = nil
        draftImageDataURLsData = nil
        pendingAnnotationsData = nil
        sideChatsData = nil
        conversationActivityDurationsData = nil
        answeredAsyncQuestionIDsData = nil
        viewedWorkspaceChangesData = nil
    }
}

enum TaskScheduleKind: String, Codable, CaseIterable, Sendable {
    case once
    case recurring
}

/// A recurring schedule's preset. Times are wall-clock times in the user's calendar, so a
/// daily run stays at 09:00 across daylight-saving changes.
struct TaskRecurrence: Codable, Equatable, Sendable {
    enum Preset: String, Codable, CaseIterable, Sendable {
        case hourly
        case daily
        case weekdays
        case weekly

        var label: String {
            switch self {
            case .hourly: "Every hour"
            case .daily: "Every day"
            case .weekdays: "Weekdays"
            case .weekly: "Weekly"
            }
        }
    }

    var preset: Preset
    var hour: Int
    var minute: Int
    /// `Calendar` weekday (1 = Sunday … 7 = Saturday); used by `.weekly`.
    var weekday: Int?

    init(preset: Preset, hour: Int = 9, minute: Int = 0, weekday: Int? = nil) {
        self.preset = preset
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
    }

    var isValid: Bool {
        (0...23).contains(hour) && (0...59).contains(minute)
            && (preset != .weekly || (weekday.map { (1...7).contains($0) } ?? false))
    }

    /// The first occurrence strictly after `date`.
    func nextOccurrence(after date: Date, calendar: Calendar = .current) -> Date {
        let candidates: [DateComponents]
        switch preset {
        case .hourly:
            candidates = [DateComponents(minute: minute, second: 0)]
        case .daily:
            candidates = [DateComponents(hour: hour, minute: minute, second: 0)]
        case .weekdays:
            candidates = (2...6).map { DateComponents(hour: hour, minute: minute, second: 0, weekday: $0) }
        case .weekly:
            candidates = [DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday ?? 2)]
        }
        return candidates
            .compactMap { calendar.nextDate(after: date, matching: $0, matchingPolicy: .nextTime) }
            .min() ?? date.addingTimeInterval(3600)
    }

    /// The latest occurrence at or before `date`, searched no further back than `floor`.
    func latestOccurrence(atOrBefore date: Date, notBefore floor: Date, calendar: Calendar = .current) -> Date? {
        var latest: Date?
        var cursor = floor.addingTimeInterval(-1)
        // A week of hourly runs is the most a sleeping Mac can owe; stop well past that.
        for _ in 0..<2000 {
            let next = nextOccurrence(after: cursor, calendar: calendar)
            guard next <= date else { break }
            latest = next
            cursor = next
        }
        return latest
    }

    func summary(calendar: Calendar = .current) -> String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch preset {
        case .hourly: return String(format: "Every hour at :%02d", minute)
        case .daily: return "Every day at \(time)"
        case .weekdays: return "Weekdays at \(time)"
        case .weekly:
            let names = calendar.weekdaySymbols
            let index = max(1, min(7, weekday ?? 2)) - 1
            return "\(names[index])s at \(time)"
        }
    }
}

extension BoardTask {
    var scheduleKind: TaskScheduleKind? {
        get { scheduleKindRawValue.flatMap(TaskScheduleKind.init(rawValue:)) }
        set { scheduleKindRawValue = newValue?.rawValue }
    }

    var isRecurringScheduleTemplate: Bool { scheduleKind == .recurring }

    var scheduleRecurrence: TaskRecurrence? {
        get { scheduleRecurrenceData.flatMap { try? JSONDecoder().decode(TaskRecurrence.self, from: $0) } }
        set { scheduleRecurrenceData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var scheduledImageDataURLs: [String] {
        get { scheduledImageDataURLsData.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
        set { scheduledImageDataURLsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
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
    /// Set once Playhouse confirms the linked pull request merged.
    var isPullRequestMerged: Bool = false
    /// The branch head when pull request creation last found nothing here to
    /// propose. The review gate clears it once the task changes the repository.
    var pullRequestSkippedHead: String? = nil

    private enum CodingKeys: String, CodingKey {
        case repositoryPath, branch, worktreePath, branchFrom, createdByPlayhouse
        case mergeTarget, isPending, pullRequestNumber, pullRequestURL, isPullRequestMerged, pullRequestSkippedHead
    }

    /// A started repository with no linked pull request that is not known to
    /// be unchanged, so its PR controls still offer to open one.
    var awaitsPullRequest: Bool {
        !isPending && (pullRequestNumber == nil || pullRequestURL == nil) && pullRequestSkippedHead == nil
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
        pullRequestURL: String? = nil,
        isPullRequestMerged: Bool = false,
        pullRequestSkippedHead: String? = nil
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
        self.isPullRequestMerged = isPullRequestMerged
        self.pullRequestSkippedHead = pullRequestSkippedHead
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
        isPullRequestMerged = try values.decodeIfPresent(Bool.self, forKey: .isPullRequestMerged) ?? false
        pullRequestSkippedHead = try values.decodeIfPresent(String.self, forKey: .pullRequestSkippedHead)
    }
}
