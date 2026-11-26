import Foundation
import Observation

/// What a board card shows: the same fields as the app's `TaskItemModel`
/// (Playhouse/App/TaskItemView.swift), but as an `@Observable` class, which
/// is how a shared app model would publish changes to either UI library.
/// Local view state (hover, expanded, menu) is NOT here; each card view owns it.
@Observable
@MainActor
public final class TaskItemModel: Identifiable {
    public struct Progress: Equatable, Sendable {
        public var label: String
        public var detail: String?
        public var symbol: String
        public init(label: String, detail: String? = nil, symbol: String) {
            self.label = label
            self.detail = detail
            self.symbol = symbol
        }
    }

    public struct Tokens: Equatable, Sendable {
        public var compact: String
        /// #RRGGBB on the token heatmap.
        public var color: String
        public var description: String
        public init(compact: String, color: String, description: String) {
            self.compact = compact
            self.color = color
            self.description = description
        }
    }

    public struct CPU: Equatable, Sendable {
        public var fraction: Double
        public var label: String
        public init(fraction: Double, label: String) {
            self.fraction = fraction
            self.label = label
        }
    }

    /// A repository chip in the card's expanded section (spike-only, see REPORT.md).
    public struct Repository: Equatable, Sendable, Identifiable {
        public var name: String
        public var branch: String
        public var pullRequest: String?
        /// open, draft or merged.
        public var pullRequestState: String
        public var id: String { name }
        public init(name: String, branch: String, pullRequest: String?, pullRequestState: String) {
            self.name = name
            self.branch = branch
            self.pullRequest = pullRequest
            self.pullRequestState = pullRequestState
        }
    }

    public nonisolated let id: String
    public var title: String
    public var progress: Progress?
    public var statusMessage: String?
    public var statusIsBlocked: Bool
    public var isWorking: Bool
    /// Seconds since 1970 at which the current working stretch began.
    public var workingSince: Double?
    public var workedSeconds: Double
    public var createdText: String
    public var tokens: Tokens?
    public var cpu: CPU?
    public var repositories: [Repository]
    public var mode: String?
    public var canMoveToDone: Bool
    public var canMoveToReview: Bool

    public init(
        id: String, title: String, progress: Progress? = nil, statusMessage: String? = nil,
        statusIsBlocked: Bool = false, isWorking: Bool = false, workingSince: Double? = nil,
        workedSeconds: Double = 0, createdText: String, tokens: Tokens? = nil, cpu: CPU? = nil,
        repositories: [Repository] = [], mode: String? = nil, canMoveToDone: Bool = true,
        canMoveToReview: Bool = false
    ) {
        self.id = id
        self.title = title
        self.progress = progress
        self.statusMessage = statusMessage
        self.statusIsBlocked = statusIsBlocked
        self.isWorking = isWorking
        self.workingSince = workingSince
        self.workedSeconds = workedSeconds
        self.createdText = createdText
        self.tokens = tokens
        self.cpu = cpu
        self.repositories = repositories
        self.mode = mode
        self.canMoveToDone = canMoveToDone
        self.canMoveToReview = canMoveToReview
    }

    /// The time row: copied from the app's `TaskItemModel.workingDuration(at:)`.
    public func workingDuration(at date: Date) -> String {
        let active = workingSince.map { max(0, date.timeIntervalSince1970 - $0) } ?? 0
        let activeText = Self.shortDuration(active)
        guard workedSeconds > 0 else { return activeText }
        return "\(activeText) (\(Self.shortDuration(workedSeconds + active)) total)"
    }

    public nonisolated static func shortDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")" }
        let days = hours / 24
        return "\(days)d\(hours % 24 == 0 ? "" : " \(hours % 24)h")"
    }

    /// A copy under another id (the identity check inserts one).
    public func withID(_ id: String) -> TaskItemModel {
        TaskItemModel(id: id, title: title, progress: progress, statusMessage: statusMessage, statusIsBlocked: statusIsBlocked,
                      isWorking: isWorking, workingSince: workingSince, workedSeconds: workedSeconds, createdText: createdText,
                      tokens: tokens, cpu: cpu, repositories: repositories, mode: mode, canMoveToDone: canMoveToDone,
                      canMoveToReview: canMoveToReview)
    }

    /// The context menu, as the app's `TaskItemView.cardProps` builds it.
    public var menu: [MenuItem] {
        var items: [MenuItem] = []
        if canMoveToDone { items.append(.init(id: "done", title: "Move to Done", icon: "checkmark.circle")) }
        if canMoveToReview { items.append(.init(id: "review", title: "Move to Review", icon: "eye")) }
        items.append(.init(id: "rename", title: "Rename…", icon: "pencil"))
        items.append(.init(id: "stats", title: "Token Stats…", icon: "chart.bar"))
        items.append(.init(id: "delete", title: "Delete Task", icon: "trash", destructive: true))
        return items
    }
}

public struct MenuItem: Equatable, Sendable {
    public var id: String
    public var title: String
    public var icon: String
    public var destructive = false
}

/// The board: its cards, which one is selected, and the clock every working
/// card's time row reads (the app uses a per-card TimelineView instead).
@Observable
@MainActor
public final class BoardModel {
    public var cards: [TaskItemModel]
    public var selectedID: String?
    public var now = Date()
    /// The last menu action or open, so the demo can show that events arrive.
    public var lastAction = "none"

    public init(cards: [TaskItemModel]) {
        self.cards = cards
    }
}
