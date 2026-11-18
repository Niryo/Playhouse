import Foundation

// Cache-aware context compaction for Claude Code task sessions.
//
// Nearly all of a long session's spend is its cached context re-read on every
// model call, and the prompt cache (written with a one-hour TTL that refreshes
// on every hit) expires about an hour after the session's last call. So a
// session is cheapest to compact while it sits idle just before that hour runs
// out, next cheapest right before a resume once it has run out, and always
// before a model switch, which starts on a cold cache whatever the timing.
//
// Everything here is Foundation-only and pure apart from reading a session
// file, so scripts/unit/context-compaction-policy-tests.swift compiles it on
// its own.
//
// When the context fills up, each provider's own auto-compaction decides when
// to compact, at its native default: Playhouse never sets Claude Code's
// `CLAUDE_CODE_AUTO_COMPACT_WINDOW` or Codex's `model_auto_compact_token_limit`.
// Earlier builds lowered that window to 200k, which compacted busy sessions
// every few minutes and cost more than it saved.
//
// Codex's app-server exposes `thread/compact/start`. Its usage notifications
// provide the latest context size but no matching prompt-cache TTL, so Codex
// compacts only before model switches; the cache-timed warm-idle and
// expired-cache resume policies apply only to Claude.

/// The user's settings for Playhouse's own compaction triggers (warm-idle,
/// cold-resume and model-switch), shared across provider task sessions.
/// Each provider's native auto-compaction stays on whatever these say.
struct ContextCompactionSettings: Equatable {
    static let defaultIdleMinutes = 50
    static let defaultMinimumTokens = 150_000
    /// Claude's idle wait has to fire before the one-hour cache TTL runs out.
    static let idleMinutesRange = 5...55
    static let minimumTokensRange = 10_000...1_000_000
    /// How long Claude Code's prompt cache outlives the session's last call.
    static let cacheLifetime: TimeInterval = 3600

    var enabled = true
    var idleMinutes = defaultIdleMinutes
    var minimumTokens = defaultMinimumTokens

    static let defaults = ContextCompactionSettings()

    /// Accept the grouping separator displayed by the settings field, but
    /// never turn a sign, decimal point or arbitrary text into an integer.
    static func parseInteger(_ text: String, groupingSeparator: String = Locale.current.groupingSeparator ?? ",") -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = groupingSeparator.isEmpty ? [trimmed] : trimmed.components(separatedBy: groupingSeparator)
        guard groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        if groups.count > 1 {
            guard (1...3).contains(groups[0].count), groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        }
        return Int(groups.joined())
    }
}

/// Why a session's context was compacted.
enum ContextCompactionTrigger: String, Codable, CaseIterable, Equatable {
    /// The provider's own auto-compaction, at its native default. The raw
    /// value predates Playhouse leaving the window to the provider, and stays
    /// so recorded events keep decoding.
    case threshold
    /// Playhouse compacted an idle session before its prompt cache expired.
    case warmIdle = "warm-idle"
    /// Playhouse compacted a session whose cache had expired before resuming it.
    case coldResume = "cold-resume"
    /// Playhouse compacted before the turn that switches the session's model.
    case modelSwitch = "model-switch"
    /// The user or the agent ran `/compact` itself.
    case manual

    var isAutomatic: Bool { self != .manual }

    /// The label the conversation timeline and Token Stats show.
    var label: String {
        switch self {
        case .threshold: "Provider auto-compaction"
        case .warmIdle: "Idle, before the cache expired"
        case .coldResume: "Resume after the cache expired"
        case .modelSwitch: "Model switch"
        case .manual: "Manual"
        }
    }

    /// Claude Code reports Playhouse's own `/compact` as `manual`, so only a
    /// compaction Playhouse did not ask for keeps the trigger Claude Code names.
    static func reported(_ claudeTrigger: String?, requested: ContextCompactionTrigger?) -> ContextCompactionTrigger {
        if let requested { return requested }
        return claudeTrigger == "auto" ? .threshold : .manual
    }
}

/// One compaction, as the conversation timeline and Token Stats record it.
struct ContextCompactionDetails: Codable, Equatable {
    var trigger: ContextCompactionTrigger
    var preTokens: Int?
    var postTokens: Int?

    /// "Automatic · Idle, before the cache expired · 180,000 → 6,000 tokens".
    var summary: String {
        var parts = [trigger.isAutomatic ? "Automatic" : "Requested with /compact"]
        if trigger.isAutomatic { parts.append(trigger.label) }
        if let preTokens, let postTokens {
            parts.append("\(preTokens.formatted()) → \(postTokens.formatted()) tokens")
        } else if let preTokens {
            parts.append("from \(preTokens.formatted()) tokens")
        }
        return parts.joined(separator: " · ")
    }
}

/// A logged compaction: what fired it, when, and how far it shrank the
/// context. `idleSeconds` is how long the session had gone without a model
/// call, so the log shows whether the idle timer fired where it should.
struct ContextCompactionEvent: Codable, Equatable, Identifiable {
    var id: String
    var recordedAt: Date
    var trigger: ContextCompactionTrigger
    var preTokens: Int?
    var postTokens: Int?
    var idleSeconds: Double?
    /// The concrete model that ran the compaction, when Playhouse chose it.
    var model: String?
    /// The last-call time this compaction answered, so an idle session is
    /// compacted at most once per quiet period even when the attempt fails.
    var lastCallAt: Date?
    var succeeded: Bool = true
    /// Provider for provider-specific timeline deduplication and reporting.
    var provider: String? = nil
    /// A provider-native compaction activity that represents this request, if available.
    var providerActivityID: String? = nil

    var summary: String {
        let details = ContextCompactionDetails(trigger: trigger, preTokens: preTokens, postTokens: postTokens).summary
        return succeeded ? details : "Compaction failed · " + details
    }
}

/// A resumed turn whose first model call rewrote the context instead of
/// reading it from the prompt cache.
struct PromptCacheMissEvent: Codable, Equatable, Identifiable {
    var id: String
    var recordedAt: Date
    var turnID: String?
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    /// How long the session had been idle before this turn, when known.
    var idleSeconds: Double?
}

/// What a Claude Code session's own file says about its prompt cache: when
/// it last called the model, how large that call's context was, and with
/// which model. A background task's notification wakes the session for a call
/// of its own, so it resets the clock like any other call.
struct ContextCompactionSessionState: Equatable {
    struct Compaction: Equatable {
        var at: Date?
        var trigger: String?
        var preTokens: Int?
        var postTokens: Int?
    }

    /// When the prompt cache was last refreshed: the newest model call, or a
    /// compaction recorded after it.
    var lastCallAt: Date?
    /// The context the next call would start from.
    var contextTokens = 0
    /// The concrete model of the newest model call.
    var model: String?
    /// The newest compaction recorded after the newest model call, if any.
    var lastCompaction: Compaction?
    /// Whether that compaction came after the newest model call, so the
    /// context is already the small post-compaction one.
    var compactedSinceLastCall = false

    static let empty = ContextCompactionSessionState()

    /// Reads the end of a session file, widening the window until it reaches
    /// a model call or the start of the file: only the newest lines matter.
    static func read(file: URL) -> ContextCompactionSessionState? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        var window = 1 << 20
        while true {
            let start = max(0, data.count - window)
            let state = parse(data[start...], startsMidLine: start > 0)
            if state.model != nil || start == 0 { return state }
            window *= 4
        }
    }

    /// Scans lines newest first until the newest main-agent model call.
    static func parse(_ data: Data.SubSequence, startsMidLine: Bool) -> ContextCompactionSessionState {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }
        var state = ContextCompactionSessionState()
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["isSidechain"] as? Bool != true else { continue }
            let timestamp = (object["timestamp"] as? String).flatMap(date)
            if object["type"] as? String == "system", object["subtype"] as? String == "compact_boundary" {
                guard state.lastCompaction == nil else { continue }
                let metadata = object["compactMetadata"] as? [String: Any] ?? object["compact_metadata"] as? [String: Any] ?? [:]
                state.lastCompaction = Compaction(
                    at: timestamp,
                    trigger: metadata["trigger"] as? String,
                    preTokens: int(metadata["preTokens"] ?? metadata["pre_tokens"]),
                    postTokens: int(metadata["postTokens"] ?? metadata["post_tokens"])
                )
                continue
            }
            guard object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  message["model"] as? String != "<synthetic>",
                  let usage = message["usage"] as? [String: Any] else { continue }
            let context = (int(usage["input_tokens"]) ?? 0) + (int(usage["cache_read_input_tokens"]) ?? 0)
                + (int(usage["cache_creation_input_tokens"]) ?? 0)
            // Synthetic entries (local command output, interruptions) carry zeros.
            guard context + (int(usage["output_tokens"]) ?? 0) > 0 else { continue }
            state.model = message["model"] as? String
            if let compaction = state.lastCompaction {
                // The compaction's own summary call is the newest one, and the
                // context it leaves is its post-compaction size.
                state.compactedSinceLastCall = true
                state.lastCallAt = compaction.at ?? timestamp
                state.contextTokens = compaction.postTokens ?? 0
            } else {
                state.lastCallAt = timestamp
                state.contextTokens = context
            }
            return state
        }
        // Only a compaction, or nothing, in what was read.
        if let compaction = state.lastCompaction {
            state.compactedSinceLastCall = true
            state.lastCallAt = compaction.at
            state.contextTokens = compaction.postTokens ?? 0
        }
        return state
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecondFormatter = ISO8601DateFormatter()

    static func date(_ text: String) -> Date? {
        fractionalFormatter.date(from: text) ?? wholeSecondFormatter.date(from: text)
    }
}

/// The decisions, as pure functions of a session's state, its task's status
/// and busy state, the clock, and the settings.
enum ContextCompactionPolicy {
    /// The board statuses whose tasks are likely to resume. A Backlog or Done
    /// task may never run again, so compacting it would be wasted spend.
    static let idleEligibleStatuses: Set<String> = ["In Progress", "Waiting Response", "Review"]

    enum IdleDecision: Equatable {
        case compact
        case skip(IdleSkipReason)
    }

    enum IdleSkipReason: String, Equatable {
        case disabled, ineligibleStatus, busy, noSession, alreadyCompacted, belowMinimum, notIdleYet, cacheExpired, alreadyAttempted
    }

    /// Whether an idle task's session should be compacted now, against the
    /// still-warm cache. `busy` covers a turn in flight (which also holds the
    /// turn open while background tasks run), a pending question, and queued
    /// messages; `lastAttemptedCallAt` is the last-call time a previous idle
    /// compaction already answered.
    static func idleDecision(
        status: String,
        isBusy: Bool,
        state: ContextCompactionSessionState?,
        lastAttemptedCallAt: Date?,
        now: Date,
        settings: ContextCompactionSettings
    ) -> IdleDecision {
        guard settings.enabled else { return .skip(.disabled) }
        guard idleEligibleStatuses.contains(status) else { return .skip(.ineligibleStatus) }
        guard !isBusy else { return .skip(.busy) }
        guard let state, let lastCallAt = state.lastCallAt else { return .skip(.noSession) }
        guard !state.compactedSinceLastCall else { return .skip(.alreadyCompacted) }
        guard state.contextTokens >= settings.minimumTokens else { return .skip(.belowMinimum) }
        let idle = now.timeIntervalSince(lastCallAt)
        guard idle >= TimeInterval(settings.idleMinutes * 60) else { return .skip(.notIdleYet) }
        // Past the TTL the cache is cold and an idle compaction saves nothing
        // over compacting when the task resumes, which may be never.
        guard idle < ContextCompactionSettings.cacheLifetime else { return .skip(.cacheExpired) }
        guard lastAttemptedCallAt != lastCallAt else { return .skip(.alreadyAttempted) }
        return .compact
    }

    /// The compaction to run before a turn on an existing session, if any:
    /// after the cache has expired, or before the turn that changes the model.
    /// `requestedModel` is the model ID Playhouse is about to launch with.
    static func beforeTurnTrigger(
        state: ContextCompactionSessionState?,
        requestedModel: String,
        provider: String = "claude",
        now: Date,
        settings: ContextCompactionSettings
    ) -> ContextCompactionTrigger? {
        guard settings.enabled, let state, let lastCallAt = state.lastCallAt,
              !state.compactedSinceLastCall else { return nil }
        if provider == "codex" {
            // Codex app-server provides context usage and a manual compact RPC,
            // but no cache TTL signal, so the idle and cold-cache rules are
            // Claude-specific. A large context is left to Codex's own
            // auto-compaction, which can also compact mid-turn.
            if state.contextTokens >= settings.minimumTokens,
               let model = state.model, isModelSwitch(from: model, to: requestedModel) { return .modelSwitch }
            return nil
        }
        guard state.contextTokens >= settings.minimumTokens else { return nil }
        if now.timeIntervalSince(lastCallAt) >= ContextCompactionSettings.cacheLifetime { return .coldResume }
        if let model = state.model, isModelSwitch(from: model, to: requestedModel) { return .modelSwitch }
        return nil
    }

    /// Whether launching `requested` (a Playhouse model ID: `default`, a family
    /// alias such as `sonnet` or `opus[1m]`, or a concrete ID) would run a
    /// different model than `previous` (the concrete model the session's last
    /// call ran). `default` resolves on the provider's side, so it never counts
    /// as a switch: an unnecessary compaction would cost more than it saves.
    static func isModelSwitch(from previous: String, to requested: String) -> Bool {
        let requested = requested.lowercased().replacingOccurrences(of: "[1m]", with: "")
        let previous = previous.lowercased().replacingOccurrences(of: "[1m]", with: "")
        guard !requested.isEmpty, requested != "default", !previous.isEmpty else { return false }
        if requested == previous { return false }
        if requested.hasPrefix("claude-") {
            return !(previous.hasPrefix(requested) || requested.hasPrefix(previous))
        }
        // A family alias names whichever release of that family is current.
        return !previous.contains("-\(requested)-") && !previous.hasSuffix("-\(requested)")
    }

    /// Whether a resumed turn's first model call missed the prompt cache: it
    /// read next to nothing from the cache and wrote a large context instead.
    static func isCacheMiss(cacheReadTokens: Int, cacheWriteTokens: Int) -> Bool {
        cacheWriteTokens >= 20_000 && cacheReadTokens * 10 < cacheWriteTokens
    }
}

/// Backward-compatible name for Claude session-file parsing and its policy tests.
typealias ClaudeSessionCacheState = ContextCompactionSessionState
