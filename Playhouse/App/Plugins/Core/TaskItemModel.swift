import Foundation

/// What a board card shows, already derived from its task: plain values a
/// native card and a plugin (as `Playhouse.props.task`) compose the same way.
struct TaskItemModel: Codable, Equatable {
    struct Progress: Codable, Equatable {
        var label: String
        var detail: String?
        var symbol: String
    }

    struct Tokens: Codable, Equatable {
        var compact: String
        /// #RRGGBB on the token heatmap.
        var color: String
        var description: String
    }

    struct CPU: Codable, Equatable {
        var fraction: Double
        var label: String
    }

    var id: String
    var title: String
    var titleSpinner: Bool
    var progress: Progress?
    var schedule: String?
    var statusMessage: String?
    var statusIsBlocked: Bool
    /// In progress: the time row counts up from `workingSince` (seconds since
    /// 1970) plus `workedSeconds`; otherwise it shows `createdText`.
    var isWorking: Bool
    var workingSince: Double?
    var workedSeconds: Double
    var createdText: String
    var tokens: Tokens?
    var cpu: CPU?
    /// Whether the card keeps a bottom row for its task card plugins (the
    /// built-in pull request controls and mode pill among them): once the task
    /// has started and has a repository.
    var hasPluginRow: Bool
    var canMoveToDone: Bool
    var canMoveToReview: Bool

    func workingDuration(at date: Date) -> String {
        let active = workingSince.map { max(0, date.timeIntervalSince1970 - $0) } ?? 0
        let activeText = Self.shortDuration(active)
        guard workedSeconds > 0 else { return activeText }
        return "\(activeText) (\(Self.shortDuration(workedSeconds + active)) total)"
    }

    static func shortDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")" }
        let days = hours / 24
        return "\(days)d\(hours % 24 == 0 ? "" : " \(hours % 24)h")"
    }
}
