import Foundation

// Plan usage and limits for the agent CLIs: Claude Code's `get_usage` control
// reply and `rate_limit_event` stream message, and Codex's
// `account/rateLimits/*` app-server methods. This file is Foundation-only so the
// parsing and reset rules can be unit-checked on their own
// (scripts/unit/agent-usage-parsing-tests.swift).

enum AgentUsageStatus: String, Codable, Equatable {
    case allowed
    case warning
    case rejected
}

struct AgentUsageWindow: Codable, Equatable {
    var id: String
    var label: String
    /// 0...100.
    var usedPercent: Double?
    /// Seconds since 1970.
    var resetsAt: Double?
    /// Set only by `AgentUsageSnapshot.effective(now:)`, once `resetsAt` has passed.
    var isReset = false
}

struct AgentUsageCredits: Codable, Equatable {
    var hasCredits: Bool
    var unlimited: Bool
    var balance: String?
}

struct AgentUsageSnapshot: Codable, Equatable {
    var windows: [AgentUsageWindow] = []
    var status: AgentUsageStatus?
    var credits: AgentUsageCredits?
    /// Seconds since 1970.
    var updatedAt: Double

    /// The snapshot as of `now`: a window whose reset time has passed reads as
    /// reset (empty, no reset time) without asking the provider, and a limit
    /// state that only those windows held is lifted with them.
    func effective(now: Double) -> AgentUsageSnapshot {
        var result = self
        result.windows = windows.map { window in
            guard let resetsAt = window.resetsAt, resetsAt <= now else { return window }
            var reset = window
            reset.usedPercent = 0
            reset.resetsAt = nil
            reset.isReset = true
            return reset
        }
        let live = result.windows.filter { !$0.isReset }
        if live.contains(where: { ($0.usedPercent ?? 0) >= 100 }) {
            result.status = .rejected
        } else if status == .rejected || status == .warning, result.windows.contains(where: \.isReset) {
            let worstLive = live.compactMap(\.usedPercent).max() ?? 0
            result.status = worstLive >= Self.warningPercent ? .warning : .allowed
        } else if status == nil {
            let worst = live.compactMap(\.usedPercent).max() ?? 0
            result.status = worst >= Self.warningPercent ? .warning : .allowed
        }
        return result
    }

    static let warningPercent = 80.0

    /// The soonest reset still ahead of `now`, for scheduling a re-render.
    func nextReset(after now: Double) -> Double? {
        windows.compactMap(\.resetsAt).filter { $0 > now }.min()
    }
}

struct AgentProviderUsage: Codable, Equatable {
    var provider: String
    var installed = true
    /// nil until the login state has been read once.
    var loggedIn: Bool?
    var account: String?
    var plan: String?
    var snapshot: AgentUsageSnapshot?
    /// A login the user started has not finished yet.
    var loginInProgress = false
}

struct AgentUsageReport: Codable, Equatable {
    var providers: [AgentProviderUsage]
    var generatedAt: Double
}

// MARK: - Parsing

enum AgentUsageParsing {
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): return number.doubleValue
        case let string as String: return Double(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// A reset time as seconds since 1970, from epoch seconds, epoch milliseconds, or ISO 8601 text.
    static func timestamp(_ value: Any?) -> Double? {
        if let string = value as? String, Double(string) == nil {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date.timeIntervalSince1970 }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)?.timeIntervalSince1970
        }
        guard let value = number(value), value > 0 else { return nil }
        return value > 1e12 ? value / 1000 : value
    }

    static func windowLabel(minutes: Double?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        switch minutes {
        case 300: return "5h"
        case 10_080: return "Weekly"
        case 1_440: return "Daily"
        case 43_200...44_640: return "Monthly"
        default:
            if minutes < 120 { return "\(Int(minutes))m" }
            if minutes < 2_880 { return "\(Int((minutes / 60).rounded()))h" }
            return "\(Int((minutes / 1_440).rounded()))d"
        }
    }

    static func humanized(_ identifier: String) -> String {
        identifier.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// Claude Code's `rate_limit_event`. Its top-level `status`, `rateLimitType` and
/// `resetsAt` are the stable part; `utilization` and the `unifiedWindows`
/// breakdown are marked internal by the CLI, so every field is optional and an
/// unrecognised shape yields fewer windows rather than a failure.
enum ClaudeRateLimitEvent {
    struct Parsed: Equatable {
        var status: AgentUsageStatus?
        var windows: [AgentUsageWindow]
    }

    static func parse(_ message: [String: Any]) -> Parsed? {
        let info = (message["rate_limit_info"] as? [String: Any]) ?? (message["rateLimitInfo"] as? [String: Any]) ?? message
        let status = (info["status"] as? String).flatMap(statusValue)
        var windows: [String: AgentUsageWindow] = [:]

        if let type = (info["rateLimitType"] as? String) ?? (info["rate_limit_type"] as? String), !type.isEmpty {
            windows[type] = window(id: type, from: info)
        }
        // The per-window breakdown, keyed by window name or listed with a type.
        let unified = info["unifiedWindows"] ?? info["unified_windows"]
        if let byName = unified as? [String: Any] {
            for (id, value) in byName {
                guard let object = value as? [String: Any] else { continue }
                windows[id] = merged(windows[id], window(id: id, from: object))
            }
        } else if let list = unified as? [Any] {
            for case let object as [String: Any] in list {
                guard let id = (object["rateLimitType"] as? String) ?? (object["type"] as? String) ?? (object["window"] as? String) else { continue }
                windows[id] = merged(windows[id], window(id: id, from: object))
            }
        }
        if status == nil, windows.isEmpty { return nil }
        return Parsed(status: status, windows: windows.values.sorted(by: windowOrder))
    }

    static func statusValue(_ raw: String) -> AgentUsageStatus? {
        switch raw {
        case "allowed": .allowed
        case "allowed_warning": .warning
        case "rejected": .rejected
        default: nil
        }
    }

    static func label(for id: String) -> String {
        switch id {
        case "five_hour": "5h"
        case "seven_day": "Weekly"
        case "seven_day_opus": "Weekly Opus"
        case "seven_day_sonnet": "Weekly Sonnet"
        case "overage": "Spend limit"
        default: AgentUsageParsing.humanized(id)
        }
    }

    static func windowOrder(_ lhs: AgentUsageWindow, _ rhs: AgentUsageWindow) -> Bool {
        // The spend limit, which only covers the plan's own windows, comes last.
        func rank(_ id: String) -> Int { id == "five_hour" ? 0 : id == "seven_day" ? 1 : id == "overage" ? 3 : 2 }
        return (rank(lhs.id), lhs.id) < (rank(rhs.id), rhs.id)
    }

    private static func window(id: String, from object: [String: Any]) -> AgentUsageWindow {
        var utilization = AgentUsageParsing.number(object["utilization"])
        // The CLI reports utilization as a 0...1 fraction.
        if let value = utilization { utilization = max(0, value <= 1 ? value * 100 : value) }
        return AgentUsageWindow(
            id: id,
            label: label(for: id),
            usedPercent: utilization,
            resetsAt: AgentUsageParsing.timestamp(object["resetsAt"] ?? object["resets_at"])
        )
    }

    private static func merged(_ existing: AgentUsageWindow?, _ update: AgentUsageWindow) -> AgentUsageWindow {
        guard var result = existing else { return update }
        result.usedPercent = update.usedPercent ?? result.usedPercent
        result.resetsAt = update.resetsAt ?? result.resetsAt
        return result
    }
}

/// Claude Code's `get_usage` control reply (CLI 2.1.309 and later), the same data
/// `/usage` shows. Its `rate_limits` carries each subscription window as
/// `{utilization, resets_at}` with utilization already 0...100, and
/// `extra_usage`, the monthly spend that is the only limit a usage-based plan has.
/// Windows keep the ids the stream's `rate_limit_event` uses, so either source
/// updates the same rows.
enum ClaudeUsageRead {
    struct Parsed: Equatable {
        var windows: [AgentUsageWindow]
        var limitReached: Bool
    }

    static let windowIDs = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]

    /// nil when the reply has no plan usage (an API-key login, or a CLI that
    /// could not reach the usage service), so a failed read never clears the rows.
    static func parse(_ response: [String: Any]) -> Parsed? {
        guard response["rate_limits_available"] as? Bool != false,
              let limits = response["rate_limits"] as? [String: Any] else { return nil }
        var windows: [AgentUsageWindow] = windowIDs.compactMap { id in
            guard let object = limits[id] as? [String: Any],
                  let percent = AgentUsageParsing.number(object["utilization"]) else { return nil }
            return AgentUsageWindow(
                id: id,
                label: ClaudeRateLimitEvent.label(for: id),
                usedPercent: max(0, percent),
                resetsAt: AgentUsageParsing.timestamp(object["resets_at"])
            )
        }
        var limitReached = false
        if let extra = limits["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let percent = AgentUsageParsing.number(extra["utilization"]) {
            // The reply has no reset time for it; the stream's `overage` event does.
            windows.append(AgentUsageWindow(id: "overage", label: ClaudeRateLimitEvent.label(for: "overage"), usedPercent: max(0, percent)))
            limitReached = extra["spend_limit_reached"] as? Bool == true
        }
        guard !windows.isEmpty else { return nil }
        return Parsed(windows: windows.sorted(by: ClaudeRateLimitEvent.windowOrder), limitReached: limitReached)
    }
}

/// Codex's `RateLimitSnapshot`, from `account/rateLimits/read` (`rateLimits`,
/// `rateLimitsByLimitId`) and the sparse `account/rateLimits/updated` push.
enum CodexRateLimits {
    struct Parsed: Equatable {
        var windows: [AgentUsageWindow]
        var credits: AgentUsageCredits?
        var plan: String?
        var limitReached: Bool
        /// Window ids this payload speaks for, so a sparse update replaces only those.
        var coveredPrefix: String
    }

    static func parse(_ snapshot: [String: Any]) -> Parsed {
        let limitID = snapshot["limitId"] as? String
        // The main bucket keeps bare ids; any other metered bucket is namespaced.
        let isMain = limitID == nil || limitID == "codex"
        let prefix = isMain ? "" : "\(limitID ?? "")."
        let name = (snapshot["limitName"] as? String) ?? limitID.map(AgentUsageParsing.humanized)
        var windows: [AgentUsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let object = snapshot[key] as? [String: Any], let used = AgentUsageParsing.number(object["usedPercent"]) else { continue }
            let label = AgentUsageParsing.windowLabel(minutes: AgentUsageParsing.number(object["windowDurationMins"]))
                ?? (key == "primary" ? "Primary" : "Secondary")
            windows.append(AgentUsageWindow(
                id: prefix + key,
                label: isMain ? label : "\(name ?? "") \(label)",
                usedPercent: min(100, max(0, used)),
                resetsAt: AgentUsageParsing.timestamp(object["resetsAt"])
            ))
        }
        // A spend-controlled account reports one limit instead of rolling windows.
        if let limit = snapshot["individualLimit"] as? [String: Any],
           let remaining = AgentUsageParsing.number(limit["remainingPercent"]) {
            windows.append(AgentUsageWindow(
                id: prefix + "individualLimit",
                label: isMain ? "Spend limit" : "\(name ?? "") spend limit",
                usedPercent: min(100, max(0, 100 - remaining)),
                resetsAt: AgentUsageParsing.timestamp(limit["resetsAt"])
            ))
        }
        var credits: AgentUsageCredits?
        if let object = snapshot["credits"] as? [String: Any] {
            credits = AgentUsageCredits(
                hasCredits: object["hasCredits"] as? Bool ?? false,
                unlimited: object["unlimited"] as? Bool ?? false,
                balance: (object["balance"] as? String) ?? AgentUsageParsing.number(object["balance"]).map { String($0) }
            )
        }
        let reached = snapshot["rateLimitReachedType"] is String || snapshot["spendControlReached"] as? Bool == true
        return Parsed(windows: windows, credits: credits, plan: snapshot["planType"] as? String, limitReached: reached, coveredPrefix: prefix)
    }

    /// Every bucket of an `account/rateLimits/read` result, the main one first.
    static func parseRead(_ result: [String: Any]) -> [Parsed] {
        var snapshots: [[String: Any]] = []
        if let main = result["rateLimits"] as? [String: Any] { snapshots.append(main) }
        let mainID = (result["rateLimits"] as? [String: Any])?["limitId"] as? String
        if let byID = result["rateLimitsByLimitId"] as? [String: Any] {
            for (id, value) in byID.sorted(by: { $0.key < $1.key }) {
                guard let object = value as? [String: Any], id != mainID, id != "codex" || mainID == nil else { continue }
                var bucket = object
                if bucket["limitId"] == nil { bucket["limitId"] = id }
                snapshots.append(bucket)
            }
        }
        return snapshots.map(parse)
    }

    static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw != "unknown" else { return nil }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
