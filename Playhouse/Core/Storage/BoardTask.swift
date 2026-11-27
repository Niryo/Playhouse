import Foundation
import Observation

package enum TaskStatus: String, CaseIterable, Identifiable {
    case backlog = "Backlog"
    case inProgress = "In Progress"
    case blocked = "Blocked"
    case waitingResponse = "Waiting Response"
    case review = "Review"
    case done = "Done"

    package var id: String {
        rawValue
    }

    package var accessibilityKey: String {
        rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// The statuses a user may move to Review by hand.
    package static let manualReviewSources: Set<TaskStatus> = [.waitingResponse, .blocked]
    /// The statuses a user may move to Done by hand.
    package static let manualDoneSources: Set<TaskStatus> = [.review, .waitingResponse, .blocked]

    /// The column's accent as sRGB components; the views build their color from it.
    package var accentRGB: (red: Double, green: Double, blue: Double) {
        switch self {
        case .backlog: (0.52, 0.57, 0.66)
        case .inProgress: (0.75, 0.48, 0.20)
        case .blocked: (0.82, 0.30, 0.30)
        case .waitingResponse: (0.64, 0.44, 0.80)
        case .review: (0.28, 0.51, 0.82)
        case .done: (0.20, 0.62, 0.45)
        }
    }
}

/// The heatmap a task's token usage dot is read from: a light green at zero
/// warming through orange to red as usage approaches the configured maximum.
package enum TokenUsageHeatmap {
    /// Canonical default ceiling, defined here rather than in `WorkspaceSettings`
    /// (`WorkspaceSupport.swift`) because `scripts/seed-task-pr-link.swift`
    /// compiles `BoardTask.swift` standalone as a small seeding utility and must
    /// not gain a dependency on the rest of the app module.
    package static let defaultColorMax = 20_000_000

    /// Hue in SwiftUI's 0...1 space: 0.33 is green, 0.0 is red. Orange falls out
    /// of the interpolation between them, so the scale reads as one ramp.
    private static let greenHue = 0.33
    private static let redHue = 0.0

    /// The dot's color as hue, saturation and brightness; the views build their color from it.
    package static func hsb(totalTokens: Int, max: Int) -> (hue: Double, saturation: Double, brightness: Double) {
        // Matches WorkspaceSettingsManager.tokenUsageColorMax's own fallback, so
        // a stored zero or negative value reads the same here as it does there
        // instead of this view alone forcing the dot to full red.
        let ceiling = max > 0 ? max : defaultColorMax
        let fraction = Swift.min(1, Swift.max(0, Double(totalTokens) / Double(ceiling)))
        return (
            hue: greenHue + (redHue - greenHue) * fraction,
            // A pale green at zero deepens as it warms, so low usage stays quiet.
            saturation: 0.45 + 0.45 * fraction,
            brightness: 0.80
        )
    }

    /// The counter's compact form: `842`, `12.4K`, `273K`, `1.2M`.
    package static func compact(_ tokens: Int) -> String {
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

    package static func label(totalTokens: Int) -> String {
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
package enum CPUUsageHeatmap {
    /// One fully busy core per logical CPU, matching the Activity Monitor
    /// convention where 100% == one core. See `TokenUsageHeatmap.defaultColorMax`
    /// for why this lives here rather than in `WorkspaceSettings`.
    package static var defaultColorMax: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) * 100 }

    package static func fraction(percent: Double, max: Int) -> Double {
        let ceiling = max > 0 ? Double(max) : Double(defaultColorMax)
        return Swift.min(1, Swift.max(0, percent / ceiling))
    }

    /// The bar's gradient from bottom to top, as hue, saturation and brightness stops.
    package static let gradientStops: [(hue: Double, saturation: Double, brightness: Double)] = [
        (0.33, 0.7, 0.75),
        (0.0, 0.7, 0.75)
    ]

    package static func label(percent: Double) -> String {
        "CPU \(Int(percent.rounded()))%"
    }
}

/// The agent runtime that executes a task's conversation turns.
package enum ConversationProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case opencode

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .opencode: "OpenCode"
        }
    }

    /// Providers' names as one phrase: "Codex", "Claude and Codex", "Claude, Codex and OpenCode".
    package static func names(_ providers: [ConversationProvider]) -> String {
        let names = providers.map(\.displayName)
        guard let last = names.last else { return "" }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
    }
}

package enum TaskProgressType: String, CaseIterable, Identifiable {
    case planning
    case searching
    case building
    case running
    case testing
    case reviewing
    case writing
    case committing

    package var id: String { rawValue }

    package var label: String { rawValue.capitalized }

}

@Observable
package final class BoardTask: PersistentModel {
    @ObservationIgnored package let persistenceState = ModelPersistenceState()
    package var id: UUID
    package var title: String
    package var statusRawValue: String
    package var lifecycleRevision: Int = 0
    package var statusMessage: String?
    package var progressTypeRawValue: String?
    package var progressLabel: String?
    package var progressDetail: String?
    package var createdAt: Date
    package var inProgressStartedAt: Date?
    package var totalInProgressSeconds: Double = 0
    package var codexThreadID: String?
    package var claudeSessionID: String?
    package var openCodeSessionID: String?
    /// Nil for tasks created before provider selection; those use Codex.
    package var conversationProviderRawValue: String?
    package var conversationEffortRawValue: String?
    /// Nil for tasks that never chose; those resume their full conversation. Choosing in
    /// one task sets it on every board task and as the default new tasks copy.
    package var conversationContextModeRawValue: String?
    // Retained for one-time migration to the global provider model preference.
    package var conversationModelIDsData: Data?
    /// The unsent composer draft when `hasUnsentDraft` is true; otherwise the last prompt
    /// saved or sent, which can already be in the conversation.
    package var savedPrompt: String?
    package var pendingSubmittedPrompt: String?
    /// True while `savedPrompt` and the draft images are the user's unsent composer draft,
    /// rather than the last prompt that was sent.
    package var hasUnsentDraft: Bool = false
    /// When the composer last saved the unsent draft. Nil for a draft nobody typed, such as
    /// a task's description that hasn't been sent.
    package var draftEditedAt: Date?
    package var workspaceRootPathsData: Data?
    package var repositoryWorktreesData: Data?
    /// Repository worktree records retired by `task repository renew` after their pull
    /// request merged. They keep the merged PR link on the card; their worktrees are gone.
    package var pastRepositoryWorktreesData: Data?
    package var contextFolderPathsData: Data?
    package var draftImageDataURLsData: Data?
    /// Review comments the user has written but not sent, encoded as JSON. Optional so tasks
    /// stored before this field existed load unchanged.
    package var pendingAnnotationsData: Data?
    /// Side chats on selected conversation text, encoded as JSON (`SavedSideChats`).
    package var sideChatsData: Data?
    package var conversationActivityDurationsData: Data?
    package var answeredAsyncQuestionIDsData: Data?
    package var viewedWorkspaceChangesData: Data?
    package var totalInputTokens: Int = 0
    package var totalOutputTokens: Int = 0
    package var totalCacheReadTokens: Int = 0
    package var totalCacheCreationTokens: Int = 0
    package var callUsageSnapshotsData: Data?
    /// Legacy pull request mode columns, from before the `pull-request-mode`
    /// plugin kept each task's mode in its own state. Only the one-time import
    /// (`legacyPullRequestMode`) reads them; a new task gets PR's value, which
    /// the import skips.
    package var autoCreatePullRequestOnReview: Bool = false
    package var pullRequestAutopilot: Bool = false
    package var pullRequestAutoMerge: Bool = false
    /// The column the task was in when it last saved, while a move is unsaved;
    /// saving publishes the move to plugins as `task.statusChanged`.
    @ObservationIgnored package var statusBeforeSave: String? = nil
    /// Autopilot fix turns sent since the pull requests were last green; bounds the loop.
    package var pullRequestAutopilotFixAttempts: Int = 0
    /// The PR state the last autopilot fix turn was sent for, so an unchanged red state
    /// is not sent again.
    package var pullRequestAutopilotLastFixSignature: String?
    /// Legacy marker from when the standalone chat was a hidden board task. Nothing reads it
    /// for behavior; it exists so `migrateLegacyStandaloneChatTasks()` can find those rows and
    /// convert them to `StandaloneChat` in stores still holding rows written before the split.
    package var legacyStandaloneChatMarker: Bool = false
    /// Nil for an ordinary task; otherwise a `TaskScheduleKind`. A one-time schedule is a
    /// Backlog task whose first prompt is sent at `scheduledAt`. A recurring schedule is a
    /// template that stays off the board and starts a new task at each occurrence.
    package var scheduleKindRawValue: String?
    /// When a one-time schedule fires, or a recurring schedule's next occurrence.
    package var scheduledAt: Date?
    package var scheduleRecurrenceData: Data?
    /// The confirmed prompt a schedule sends. Kept apart from `savedPrompt`, which the
    /// composer autosaves while the user edits, so an unconfirmed edit never fires.
    package var scheduledPrompt: String?
    package var scheduledImageDataURLsData: Data?
    package var scheduledModeRawValue: String?
    package var scheduledModelID: String?
    package var schedulePaused: Bool = false
    package var lastScheduledRunAt: Date?
    package var lastScheduledRunTaskID: UUID?
    /// The recurring schedule that started this task, if any.
    package var scheduleSourceTaskID: UUID?

    package var workspaceRootPaths: [String] {
        get {
            guard let workspaceRootPathsData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: workspaceRootPathsData)) ?? []
        }
        set {
            workspaceRootPathsData = try? JSONEncoder().encode(newValue)
        }
    }

    package var repositoryWorktrees: [RepositoryWorktreeRecord] {
        get { guard let repositoryWorktreesData else { return [] }; return (try? JSONDecoder().decode([RepositoryWorktreeRecord].self, from: repositoryWorktreesData)) ?? [] }
        set { repositoryWorktreesData = try? JSONEncoder().encode(newValue) }
    }

    package var pastRepositoryWorktrees: [RepositoryWorktreeRecord] {
        get { guard let pastRepositoryWorktreesData else { return [] }; return (try? JSONDecoder().decode([RepositoryWorktreeRecord].self, from: pastRepositoryWorktreesData)) ?? [] }
        set { pastRepositoryWorktreesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    package var contextFolderPaths: [String] {
        get { guard let contextFolderPathsData else { return workspaceRootPaths }; return (try? JSONDecoder().decode([String].self, from: contextFolderPathsData)) ?? [] }
        set { contextFolderPathsData = try? JSONEncoder().encode(newValue) }
    }

    package init(title: String, status: TaskStatus = .backlog, workspaceRootPaths: [String] = [], conversationProvider: ConversationProvider = .codex) {
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
        openCodeSessionID = nil
        conversationProviderRawValue = conversationProvider.rawValue
        conversationEffortRawValue = "medium"
        conversationModelIDsData = nil
        savedPrompt = nil
        pendingSubmittedPrompt = nil
        workspaceRootPathsData = try? JSONEncoder().encode(workspaceRootPaths)
        // Reads as PR, which the legacy import skips, so it never gives a task
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

    package static let tableName = "board_tasks"
    package static let persistedProperties: [PersistedProperty<BoardTask>] = [
        PersistedProperty("id", \.id),
        PersistedProperty("title", \.title),
        PersistedProperty("statusRawValue", \.statusRawValue),
        PersistedProperty("lifecycleRevision", \.lifecycleRevision),
        PersistedProperty("statusMessage", \.statusMessage),
        PersistedProperty("progressTypeRawValue", \.progressTypeRawValue),
        PersistedProperty("progressLabel", \.progressLabel),
        PersistedProperty("progressDetail", \.progressDetail),
        PersistedProperty("createdAt", \.createdAt),
        PersistedProperty("inProgressStartedAt", \.inProgressStartedAt),
        PersistedProperty("totalInProgressSeconds", \.totalInProgressSeconds),
        PersistedProperty("codexThreadID", \.codexThreadID),
        PersistedProperty("claudeSessionID", \.claudeSessionID),
        PersistedProperty("openCodeSessionID", \.openCodeSessionID),
        PersistedProperty("conversationProviderRawValue", \.conversationProviderRawValue),
        PersistedProperty("conversationEffortRawValue", \.conversationEffortRawValue),
        PersistedProperty("conversationContextModeRawValue", \.conversationContextModeRawValue),
        PersistedProperty("conversationModelIDsData", \.conversationModelIDsData),
        PersistedProperty("savedPrompt", \.savedPrompt),
        PersistedProperty("pendingSubmittedPrompt", \.pendingSubmittedPrompt),
        PersistedProperty("hasUnsentDraft", \.hasUnsentDraft),
        PersistedProperty("draftEditedAt", \.draftEditedAt),
        PersistedProperty("workspaceRootPathsData", \.workspaceRootPathsData),
        PersistedProperty("repositoryWorktreesData", \.repositoryWorktreesData),
        PersistedProperty("pastRepositoryWorktreesData", \.pastRepositoryWorktreesData),
        PersistedProperty("contextFolderPathsData", \.contextFolderPathsData),
        PersistedProperty("draftImageDataURLsData", \.draftImageDataURLsData),
        PersistedProperty("pendingAnnotationsData", \.pendingAnnotationsData),
        PersistedProperty("sideChatsData", \.sideChatsData),
        PersistedProperty("conversationActivityDurationsData", \.conversationActivityDurationsData),
        PersistedProperty("answeredAsyncQuestionIDsData", \.answeredAsyncQuestionIDsData),
        PersistedProperty("viewedWorkspaceChangesData", \.viewedWorkspaceChangesData),
        PersistedProperty("totalInputTokens", \.totalInputTokens),
        PersistedProperty("totalOutputTokens", \.totalOutputTokens),
        PersistedProperty("totalCacheReadTokens", \.totalCacheReadTokens),
        PersistedProperty("totalCacheCreationTokens", \.totalCacheCreationTokens),
        PersistedProperty("callUsageSnapshotsData", \.callUsageSnapshotsData),
        PersistedProperty("autoCreatePullRequestOnReview", \.autoCreatePullRequestOnReview),
        PersistedProperty("pullRequestAutopilot", \.pullRequestAutopilot),
        PersistedProperty("pullRequestAutoMerge", \.pullRequestAutoMerge),
        PersistedProperty("pullRequestAutopilotFixAttempts", \.pullRequestAutopilotFixAttempts),
        PersistedProperty("pullRequestAutopilotLastFixSignature", \.pullRequestAutopilotLastFixSignature),
        PersistedProperty("legacyStandaloneChatMarker", \.legacyStandaloneChatMarker),
        PersistedProperty("scheduleKindRawValue", \.scheduleKindRawValue),
        PersistedProperty("scheduledAt", \.scheduledAt),
        PersistedProperty("scheduleRecurrenceData", \.scheduleRecurrenceData),
        PersistedProperty("scheduledPrompt", \.scheduledPrompt),
        PersistedProperty("scheduledImageDataURLsData", \.scheduledImageDataURLsData),
        PersistedProperty("scheduledModeRawValue", \.scheduledModeRawValue),
        PersistedProperty("scheduledModelID", \.scheduledModelID),
        PersistedProperty("schedulePaused", \.schedulePaused),
        PersistedProperty("lastScheduledRunAt", \.lastScheduledRunAt),
        PersistedProperty("lastScheduledRunTaskID", \.lastScheduledRunTaskID),
        PersistedProperty("scheduleSourceTaskID", \.scheduleSourceTaskID),
    ]

    package required init(storedID: UUID) {
        id = storedID
        title = ""
        statusRawValue = TaskStatus.backlog.rawValue
        createdAt = Date(timeIntervalSinceReferenceDate: 0)
    }
}

package enum TaskScheduleKind: String, Codable, CaseIterable, Sendable {
    case once
    case recurring
}

/// A recurring schedule's preset. Times are wall-clock times in the user's calendar, so a
/// daily run stays at 09:00 across daylight-saving changes.
package struct TaskRecurrence: Codable, Equatable, Sendable {
    package enum Preset: String, Codable, CaseIterable, Sendable {
        case hourly
        case daily
        case weekdays
        case weekly

        package var label: String {
            switch self {
            case .hourly: "Every hour"
            case .daily: "Every day"
            case .weekdays: "Weekdays"
            case .weekly: "Weekly"
            }
        }
    }

    package var preset: Preset
    package var hour: Int
    package var minute: Int
    /// `Calendar` weekday (1 = Sunday … 7 = Saturday); used by `.weekly`.
    package var weekday: Int?

    package init(preset: Preset, hour: Int = 9, minute: Int = 0, weekday: Int? = nil) {
        self.preset = preset
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
    }

    package var isValid: Bool {
        (0...23).contains(hour) && (0...59).contains(minute)
            && (preset != .weekly || (weekday.map { (1...7).contains($0) } ?? false))
    }

    /// The first occurrence strictly after `date`.
    package func nextOccurrence(after date: Date, calendar: Calendar = .current) -> Date {
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
    package func latestOccurrence(atOrBefore date: Date, notBefore floor: Date, calendar: Calendar = .current) -> Date? {
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

    package func summary(calendar: Calendar = .current) -> String {
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
    package var scheduleKind: TaskScheduleKind? {
        get { scheduleKindRawValue.flatMap(TaskScheduleKind.init(rawValue:)) }
        set { scheduleKindRawValue = newValue?.rawValue }
    }

    package var isRecurringScheduleTemplate: Bool { scheduleKind == .recurring }

    package var scheduleRecurrence: TaskRecurrence? {
        get { scheduleRecurrenceData.flatMap { try? JSONDecoder().decode(TaskRecurrence.self, from: $0) } }
        set { scheduleRecurrenceData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    package var scheduledImageDataURLs: [String] {
        get { scheduledImageDataURLsData.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
        set { scheduledImageDataURLsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }
}

package struct RepositoryWorktreeSpec: Codable, Equatable, Sendable {
    package var repositoryPath: String
    package var branch: String?
    package var branchFrom: String?
    package var mergeTarget: String? = nil

    package init(repositoryPath: String, branch: String? = nil, branchFrom: String? = nil, mergeTarget: String? = nil) {
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.branchFrom = branchFrom
        self.mergeTarget = mergeTarget
    }
}

/// Which of a task's worktrees a command targets: the worktree path names one
/// exactly; a repository path is enough while the task has one worktree of it.
/// A branch tells apart pending worktrees of one repository, which share its path.
package struct RepositoryWorktreeSelector: Equatable, Sendable {
    package var repositoryPath: String?
    package var worktreePath: String?
    package var branch: String?

    package static func repository(_ path: String) -> Self { Self(repositoryPath: path) }

    package static func record(_ record: RepositoryWorktreeRecord) -> Self {
        Self(repositoryPath: record.repositoryPath, worktreePath: record.worktreePath, branch: record.isPending ? record.branch : nil)
    }

    package init(repositoryPath: String? = nil, worktreePath: String? = nil, branch: String? = nil) {
        self.repositoryPath = repositoryPath
        self.worktreePath = worktreePath
        self.branch = branch
    }
}

package struct RepositoryWorktreeRecord: Codable, Equatable, Sendable {
    package var repositoryPath: String
    package var branch: String
    package var worktreePath: String
    package var branchFrom: String
    package var createdByPlayhouse: Bool
    package var mergeTarget: String? = nil
    package var isPending: Bool = false
    package var pullRequestNumber: Int? = nil
    package var pullRequestURL: String? = nil
    /// Set once Playhouse confirms the linked pull request merged.
    package var isPullRequestMerged: Bool = false
    /// Set when GitHub reports the linked pull request closed without merging.
    /// Such a worktree waits for a new pull request again.
    package var isPullRequestClosed: Bool = false
    /// The branch head when pull request creation last found nothing here to
    /// propose. The review gate clears it once the task changes the repository.
    package var pullRequestSkippedHead: String? = nil

    private enum CodingKeys: String, CodingKey {
        case repositoryPath, branch, worktreePath, branchFrom, createdByPlayhouse
        case mergeTarget, isPending, pullRequestNumber, pullRequestURL, isPullRequestMerged, isPullRequestClosed, pullRequestSkippedHead
    }

    /// Whether a pull request is linked to this worktree.
    package var hasPullRequest: Bool { pullRequestNumber != nil && pullRequestURL != nil }

    /// A pending worktree added without a branch-from or merge target leaves them empty
    /// rather than asking Git for the repository's defaults, which takes a noticeable
    /// moment. Opening its settings or starting the task works them out.
    package var hasUndecidedDefaults: Bool { isPending && (branchFrom.isEmpty || mergeTarget == nil) }

    /// Whether `other` is this record with only its undecided defaults since worked out,
    /// which an edit read before them can still apply to.
    package func isUndecidedForm(of other: RepositoryWorktreeRecord) -> Bool {
        guard hasUndecidedDefaults else { return false }
        var decided = other
        if branchFrom.isEmpty { decided.branchFrom = "" }
        if mergeTarget == nil { decided.mergeTarget = nil }
        return decided == self
    }

    /// The ref the record's changes are measured against: its branch-from, or HEAD while undecided.
    package var comparisonBase: String { branchFrom.isEmpty ? "HEAD" : branchFrom }

    /// The linked pull request's state as the card shows it: open, merged or closed.
    package var pullRequestState: String? {
        guard hasPullRequest else { return nil }
        return isPullRequestMerged ? "merged" : (isPullRequestClosed ? "closed" : "open")
    }

    /// A started repository with no open or merged pull request that is not known
    /// to be unchanged, so its PR controls still offer to open one.
    package var awaitsPullRequest: Bool {
        !isPending && (!hasPullRequest || (isPullRequestClosed && !isPullRequestMerged)) && pullRequestSkippedHead == nil
    }

    /// Whether `branch` stands for a branch named when the task starts: "auto", or the
    /// "auto 2", "auto 3"… a repository's further automatic worktrees wait under. The
    /// space keeps those from ever being a real Git branch name.
    package static func isAutomaticBranch(_ branch: String) -> Bool {
        branch == "auto" || (branch.hasPrefix("auto ") && Int(branch.dropFirst(5)).map { $0 > 1 } == true)
    }

    /// The automatic branch a new pending worktree of `repositoryPath` waits under: "auto",
    /// or the first free "auto N" when another of the repository's records already waits,
    /// so each pending worktree keeps a branch of its own to be told apart by.
    package static func automaticBranch(for repositoryPath: String, among records: [RepositoryWorktreeRecord]) -> String {
        let taken = Set(records.filter { $0.isPending && $0.repositoryPath == repositoryPath }.map(\.branch))
        guard taken.contains("auto") else { return "auto" }
        return (2...).lazy.map { "auto \($0)" }.first { !taken.contains($0) }!
    }

    /// Whether `other` is this same worktree, possibly with other PR fields. A started
    /// worktree is its path; pending records share the repository path until the task
    /// starts, so a pending record is also told apart by its branch.
    package func isSameWorktree(as other: RepositoryWorktreeRecord) -> Bool {
        let standard = { (path: String) in URL(fileURLWithPath: path).standardizedFileURL.path }
        guard standard(repositoryPath) == standard(other.repositoryPath),
              standard(worktreePath) == standard(other.worktreePath),
              isPending == other.isPending else { return false }
        return !isPending || branch == other.branch
    }

    package init(
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
        isPullRequestClosed: Bool = false,
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
        self.isPullRequestClosed = isPullRequestClosed
        self.pullRequestSkippedHead = pullRequestSkippedHead
    }

    package init(from decoder: Decoder) throws {
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
        isPullRequestClosed = try values.decodeIfPresent(Bool.self, forKey: .isPullRequestClosed) ?? false
        pullRequestSkippedHead = try values.decodeIfPresent(String.self, forKey: .pullRequestSkippedHead)
    }
}
