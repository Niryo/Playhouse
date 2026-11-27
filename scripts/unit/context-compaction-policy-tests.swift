import Foundation

// Pure-logic checks of the compaction decisions and the session state reader
// in Playhouse/Core/Conversation/ContextCompaction.swift, compiled with it and run by
// scripts/test-e2e.sh before the bridge suite. The bridge cases
// `test_claude_idle_session_compacts_before_cache_expires` and
// `test_claude_resume_compacts_after_cache_expires_or_model_switch` cover the
// same decisions end to end.

@main
struct ContextCompactionPolicyTests {
    static var failures: [String] = []
    static var checks = 0

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        checks += 1
        if actual != expected { failures.append("\(message): expected \(expected), got \(actual)") }
    }

    static let now = Date(timeIntervalSince1970: 1_900_000_000)
    static let settings = ContextCompactionSettings.defaults

    static func state(context: Int, idleMinutes: Double, model: String = "claude-opus-5-5", compacted: Bool = false) -> ClaudeSessionCacheState {
        var state = ClaudeSessionCacheState()
        state.lastCallAt = now.addingTimeInterval(-idleMinutes * 60)
        state.contextTokens = context
        state.model = model
        state.compactedSinceLastCall = compacted
        return state
    }

    static func idle(_ status: String, busy: Bool = false, _ state: ClaudeSessionCacheState?, attempted: Date? = nil, settings: ContextCompactionSettings = settings) -> ContextCompactionPolicy.IdleDecision {
        ContextCompactionPolicy.idleDecision(status: status, isBusy: busy, state: state, lastAttemptedCallAt: attempted, now: now, settings: settings)
    }

    static func main() {
        // Defaults.
        expect(settings.enabled, true, "automatic compaction defaults on")
        expect(settings.idleMinutes, 50, "idle wait defaults to 50 minutes")
        expect(settings.minimumTokens, 150_000, "minimum defaults to 150k tokens")
        var off = settings
        off.enabled = false
        expect(ContextCompactionSettings.idleMinutesRange.upperBound < 60, true, "the idle wait stays under the one-hour TTL")

        // Idle decisions: status.
        let large = state(context: 180_000, idleMinutes: 51)
        for status in ["In Progress", "Waiting Response", "Review"] {
            expect(idle(status, large), .compact, "\(status) idle past 50 minutes with a large context compacts")
        }
        for status in ["Backlog", "Done", "Blocked"] {
            expect(idle(status, large), .skip(.ineligibleStatus), "\(status) never compacts while idle")
        }
        // Busy, setting, and session.
        expect(idle("Review", busy: true, large), .skip(.busy), "a turn in flight, background task or pending question blocks it")
        expect(idle("Review", large, settings: off), .skip(.disabled), "disabled restores the old behavior")
        expect(idle("Review", nil), .skip(.noSession), "no session file, nothing to compact")
        expect(idle("Review", ClaudeSessionCacheState()), .skip(.noSession), "no model call yet")
        // Size and timing.
        expect(idle("Review", state(context: 149_999, idleMinutes: 51)), .skip(.belowMinimum), "a context under the minimum is left alone")
        expect(idle("Review", state(context: 150_000, idleMinutes: 51)), .compact, "the minimum itself qualifies")
        expect(idle("Review", state(context: 180_000, idleMinutes: 49.9)), .skip(.notIdleYet), "not yet 50 minutes idle")
        expect(idle("Review", state(context: 180_000, idleMinutes: 50)), .compact, "exactly 50 minutes idle")
        expect(idle("Review", state(context: 180_000, idleMinutes: 60)), .skip(.cacheExpired), "the cache has already expired")
        expect(idle("Review", state(context: 180_000, idleMinutes: 51, compacted: true)), .skip(.alreadyCompacted), "already compacted since the last call")
        expect(idle("Review", large, attempted: large.lastCallAt), .skip(.alreadyAttempted), "one attempt per quiet period")
        expect(idle("Review", large, attempted: large.lastCallAt!.addingTimeInterval(-600)), .compact, "an attempt for an earlier quiet period doesn't count")
        var quick = settings
        quick.idleMinutes = 20
        expect(idle("Review", state(context: 180_000, idleMinutes: 21), settings: quick), .compact, "the idle wait is configurable")

        // Before a turn.
        func before(_ state: ClaudeSessionCacheState?, model: String = "opus", provider: String = "claude", settings: ContextCompactionSettings = settings) -> ContextCompactionTrigger? {
            ContextCompactionPolicy.beforeTurnTrigger(state: state, requestedModel: model, provider: provider, now: now, settings: settings)
        }
        expect(before(state(context: 180_000, idleMinutes: 61)), .coldResume, "resuming after the TTL compacts first")
        expect(before(state(context: 180_000, idleMinutes: 59)), nil, "a warm cache resumes as is")
        expect(before(state(context: 100_000, idleMinutes: 120)), nil, "a small context resumes as is")
        expect(before(state(context: 180_000, idleMinutes: 61, compacted: true)), nil, "a compacted session resumes as is")
        expect(before(state(context: 180_000, idleMinutes: 61), settings: off), nil, "disabled never compacts before a turn")
        expect(before(state(context: 180_000, idleMinutes: 5), model: "sonnet"), .modelSwitch, "switching model compacts first")
        expect(before(state(context: 100_000, idleMinutes: 5), model: "sonnet"), nil, "a small context switches model as is")
        expect(before(state(context: 180_000, idleMinutes: 5), model: "default"), nil, "the provider default is not a known switch")
        for context in [220_000, 450_000, 900_000] {
            expect(before(state(context: context, idleMinutes: 5, model: "gpt-6-sol"), model: "gpt-6-sol", provider: "codex"), nil,
                   "Codex at \(context) tokens with no model switch is left to its native auto-compaction")
        }
        expect(before(state(context: 900_000, idleMinutes: 5)), nil, "a large warm Claude context is left to Claude Code's native auto-compaction")
        expect(before(state(context: 180_000, idleMinutes: 61, model: "gpt-6-luna"), model: "gpt-6-luna", provider: "codex"), nil, "Codex has no Claude prompt-cache expiry signal")
        expect(before(state(context: 180_000, idleMinutes: 5, model: "gpt-6-luna"), model: "gpt-6-sol", provider: "codex"), .modelSwitch, "Codex compacts before changing models")
        expect(before(state(context: 220_000, idleMinutes: 5, compacted: true), model: "gpt-6-sol", provider: "codex"), nil, "Codex does not repeat a compaction after the same context call")
        expect(before(nil), nil, "no session, no compaction")

        // Model switch matching.
        expect(ContextCompactionPolicy.isModelSwitch(from: "claude-opus-5-5", to: "opus"), false, "the family alias of the same model")
        expect(ContextCompactionPolicy.isModelSwitch(from: "claude-opus-5-5", to: "opus[1m]"), false, "the 1M alias of the same family")
        expect(ContextCompactionPolicy.isModelSwitch(from: "claude-opus-5-5", to: "sonnet"), true, "another family")
        expect(ContextCompactionPolicy.isModelSwitch(from: "claude-opus-5-5", to: "claude-opus-5-5"), false, "the same concrete model")
        expect(ContextCompactionPolicy.isModelSwitch(from: "claude-opus-5-5-20251001", to: "claude-opus-5-5"), false, "a dated release of the same model")
        expect(ContextCompactionPolicy.isModelSwitch(from: "claude-opus-5-5", to: "claude-opus-4-8"), true, "another release")
        expect(ContextCompactionPolicy.isModelSwitch(from: "claude-sonnet-5-5", to: "Default"), false, "default resolves on the provider's side")

        // Cache misses.
        expect(ContextCompactionPolicy.isCacheMiss(cacheReadTokens: 0, cacheWriteTokens: 357_000), true, "a full rewrite is a miss")
        expect(ContextCompactionPolicy.isCacheMiss(cacheReadTokens: 350_000, cacheWriteTokens: 7_000), false, "a hit with a small write")
        expect(ContextCompactionPolicy.isCacheMiss(cacheReadTokens: 0, cacheWriteTokens: 5_000), false, "a small new session isn't a miss")
        expect(ContextCompactionPolicy.isCacheMiss(cacheReadTokens: 30_000, cacheWriteTokens: 600_000), true, "reading only the system prompt is still a miss")

        // Triggers.
        expect(ContextCompactionTrigger.reported("auto", requested: nil), .threshold, "Claude Code's native auto-compaction is reported")
        expect(ContextCompactionTrigger.threshold.label, "Provider auto-compaction", "native auto-compaction is labelled as the provider's")
        expect(ContextCompactionTrigger(rawValue: "threshold"), .threshold, "recorded native compactions keep decoding")
        expect(ContextCompactionTrigger.reported("manual", requested: nil), .manual, "a /compact nobody automated")
        expect(ContextCompactionTrigger.reported("manual", requested: .warmIdle), .warmIdle, "Playhouse's own /compact keeps its reason")
        expect(ContextCompactionDetails(trigger: .warmIdle, preTokens: 180_000, postTokens: 6_000).summary.hasPrefix("Automatic · "), true, "automatic compactions say so")

        for invalid in ["-100000", "5.5", "200000x", "1,00,000", "", "  "] {
            expect(ContextCompactionSettings.parseInteger(invalid, groupingSeparator: ","), nil, "reject malformed setting: \(invalid)")
        }
        expect(ContextCompactionSettings.parseInteger("200,000", groupingSeparator: ","), 200_000, "accept displayed grouping")
        expect(ContextCompactionSettings.parseInteger(" 200000 ", groupingSeparator: ","), 200_000, "accept plain integer")
        let failed = ContextCompactionEvent(id: "failed", recordedAt: now, trigger: .warmIdle, succeeded: false)
        expect(failed.summary.hasPrefix("Compaction failed"), true, "failed attempts are labelled in Token Stats")

        // The session state reader.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("context-compaction-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func line(_ object: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\n"
        }
        func call(_ id: String, at time: String, read: Int, write: Int, model: String = "claude-opus-5-5", sidechain: Bool = false) -> String {
            line(["type": "assistant", "timestamp": time, "isSidechain": sidechain, "message": [
                "id": id, "model": model, "role": "assistant",
                "usage": ["input_tokens": 3, "cache_read_input_tokens": read, "cache_creation_input_tokens": write, "output_tokens": 40],
            ]])
        }
        let file = directory.appendingPathComponent("session.jsonl")
        var text = line(["type": "user", "timestamp": "2026-11-12T10:00:00.000Z", "message": ["role": "user", "content": "hi"]])
        text += call("msg_1", at: "2026-11-12T10:00:05.000Z", read: 100_000, write: 2_000)
        text += call("msg_2", at: "2026-11-12T10:05:00.250Z", read: 170_000, write: 10_000, model: "claude-sonnet-5-5")
        text += call("msg_sub", at: "2026-11-12T10:06:00.000Z", read: 9_000, write: 9_000, sidechain: true)
        text += line(["type": "assistant", "timestamp": "2026-11-12T10:07:00.000Z", "message": [
            "id": "synthetic", "model": "<synthetic>", "usage": ["input_tokens": 0, "output_tokens": 0],
        ]])
        text += String(repeating: line(["type": "attachment", "timestamp": "2026-11-12T10:07:00.000Z", "padding": String(repeating: "x", count: 1_100)]), count: 1_100)
        try! text.write(to: file, atomically: true, encoding: .utf8)
        // A session file with more than one MiB of trailing metadata exercises
        // the normal adaptive read path without a production-only test knob.
        let read = ClaudeSessionCacheState.read(file: file)
        expect(read?.contextTokens, 180_003, "the newest main-agent call's whole context")
        expect(read?.model, "claude-sonnet-5-5", "the newest call's model")
        expect(read?.lastCallAt, ClaudeSessionCacheState.date("2026-11-12T10:05:00.250Z"), "subagent and synthetic lines don't move the clock")
        expect(read?.compactedSinceLastCall, false, "no compaction yet")

        var compacted = text
        compacted += line(["type": "system", "subtype": "compact_boundary", "timestamp": "2026-11-12T10:55:00Z",
                           "compactMetadata": ["trigger": "manual", "preTokens": 180_003, "postTokens": 6_200]])
        try! compacted.write(to: file, atomically: true, encoding: .utf8)
        let afterCompaction = ClaudeSessionCacheState.read(file: file)
        expect(afterCompaction?.compactedSinceLastCall, true, "a boundary after the newest call")
        expect(afterCompaction?.contextTokens, 6_200, "the post-compaction context")
        expect(afterCompaction?.lastCallAt, ClaudeSessionCacheState.date("2026-11-12T10:55:00Z"), "the compaction's own call moves the clock")
        expect(afterCompaction?.lastCompaction?.preTokens, 180_003, "the boundary's size before")
        expect(afterCompaction?.lastCompaction?.trigger, "manual", "the boundary's trigger")

        compacted += call("msg_3", at: "2026-11-12T11:00:00Z", read: 6_000, write: 1_000)
        try! compacted.write(to: file, atomically: true, encoding: .utf8)
        let resumed = ClaudeSessionCacheState.read(file: file)
        expect(resumed?.compactedSinceLastCall, false, "a call after the boundary")
        expect(resumed?.contextTokens, 7_003, "the context grows again from the summary")
        expect(resumed?.lastCompaction == nil, true, "a compaction before the newest call no longer describes the context")
        expect(ClaudeSessionCacheState.read(file: directory.appendingPathComponent("missing.jsonl")), nil, "a missing file has no state")

        if failures.isEmpty {
            print("Context compaction policy tests: \(checks) checks passed.")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            print("Context compaction policy tests: \(failures.count) of \(checks) checks failed.")
            exit(1)
        }
    }
}
