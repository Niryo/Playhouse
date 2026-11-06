import Foundation

// Pure-logic checks of the usage payload parsing and reset rules in
// Playhouse/App/AgentUsage.swift, compiled with it and run by
// scripts/test-e2e.sh before the bridge suite. The bridge case
// `test_agents_info_shows_provider_usage_and_accounts` covers the same payloads end to end.

@main
struct AgentUsageParsingTests {
    static var failures: [String] = []
    static var checks = 0

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        checks += 1
        if actual != expected { failures.append("\(message): expected \(expected), got \(actual)") }
    }

    static func json(_ text: String) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: Data(text.utf8))) as! [String: Any]
    }

    static func main() {
        // Claude: the documented event.
        let full = ClaudeRateLimitEvent.parse(json("""
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","rateLimitType":"five_hour","utilization":0.85,"resetsAt":1900000000,
         "unifiedWindows":{"five_hour":{"utilization":0.85,"resetsAt":1900000000},"seven_day":{"utilization":0.4,"resetsAt":1900500000},"seven_day_opus":{"utilization":12,"resetsAt":1900500000}}}}
        """))
        expect(full?.status, .warning, "allowed_warning maps to warning")
        expect(full?.windows.map(\.id), ["five_hour", "seven_day", "seven_day_opus"], "windows ordered 5h, weekly, model weekly")
        expect(full?.windows.map(\.label), ["5h", "Weekly", "Weekly Opus"], "window labels")
        expect(full?.windows[0].usedPercent, 85, "fractional utilization becomes a percent")
        expect(full?.windows[2].usedPercent, 12, "percent utilization is kept")
        expect(full?.windows[0].resetsAt, 1_900_000_000, "reset time")

        // Claude: only the stable fields.
        let stable = ClaudeRateLimitEvent.parse(json(#"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"seven_day","resetsAt":1900500000000}}"#))
        expect(stable?.status, .rejected, "rejected status")
        expect(stable?.windows.count, 1, "fallback window from rateLimitType")
        expect(stable?.windows.first?.usedPercent, nil, "missing utilization stays unknown")
        expect(stable?.windows.first?.resetsAt, 1_900_500_000, "millisecond reset time is normalised")

        // Claude: empty, unknown and malformed fields never throw.
        expect(ClaudeRateLimitEvent.parse(json(#"{"type":"rate_limit_event"}"#)) == nil, true, "event without info is ignored")
        let odd = ClaudeRateLimitEvent.parse(json(#"{"rate_limit_info":{"status":"future_status","rateLimitType":"weird_new_limit","unifiedWindows":[{"type":"five_hour","utilization":"0.5"},"junk",7]}}"#))
        expect(odd?.status, nil, "unknown status is ignored")
        expect(odd?.windows.map(\.id), ["five_hour", "weird_new_limit"], "list-shaped windows and unknown types are kept")
        expect(odd?.windows.last?.label, "Weird New Limit", "unknown type gets a readable label")
        expect(odd?.windows.first?.usedPercent, 50, "numeric strings are accepted")

        // Codex: a full read with both windows, credits, and a second bucket.
        let read = json("""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":30,"windowDurationMins":300,"resetsAt":1900000000},
          "secondary":{"usedPercent":62,"windowDurationMins":10080,"resetsAt":1900500000},
          "credits":{"hasCredits":true,"unlimited":false,"balance":"12.50"},"planType":"pro","rateLimitReachedType":null},
         "rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":30,"windowDurationMins":300}},
           "codex_spark":{"limitId":"codex_spark","limitName":"Spark","primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":1900000000}}}}
        """)
        let buckets = CodexRateLimits.parseRead(read)
        expect(buckets.count, 2, "main bucket plus one other")
        expect(buckets[0].windows.map(\.label), ["5h", "Weekly"], "primary and secondary labelled by duration")
        expect(buckets[0].windows.map(\.usedPercent), [30, 62], "used percent")
        expect(buckets[0].credits, AgentUsageCredits(hasCredits: true, unlimited: false, balance: "12.50"), "credits")
        expect(CodexRateLimits.planName(buckets[0].plan), "Pro", "plan name")
        expect(buckets[1].windows.first?.id, "codex_spark.primary", "other buckets are namespaced")
        expect(buckets[1].windows.first?.label, "Spark 5h", "other bucket label names the limit")

        // Codex: a spend-controlled account reports one limit and no rolling windows.
        let spend = CodexRateLimits.parse(json(#"{"limitId":"codex","primary":null,"secondary":null,"credits":{"hasCredits":true,"unlimited":false,"balance":null},"individualLimit":{"limit":"8750","used":"920","remainingPercent":89,"resetsAt":1900000000},"rateLimitReachedType":"rate_limit_reached"}"#))
        expect(spend.windows.map(\.label), ["Spend limit"], "individual limit becomes a window")
        expect(spend.windows.first?.usedPercent, 11, "remaining percent inverts to used")
        expect(spend.limitReached, true, "reached type marks the limit reached")
        expect(CodexRateLimits.parse([:]).windows.isEmpty, true, "empty snapshot has no windows")
        expect(CodexRateLimits.parse(json(#"{"primary":{"windowDurationMins":300}}"#)).windows.isEmpty, true, "a window without usedPercent is skipped")

        // Reset handling: passed reset times read as reset and lift the limit they held.
        let snapshot = AgentUsageSnapshot(
            windows: [
                AgentUsageWindow(id: "five_hour", label: "5h", usedPercent: 100, resetsAt: 1_000),
                AgentUsageWindow(id: "seven_day", label: "Weekly", usedPercent: 40, resetsAt: 9_000),
            ],
            status: .rejected, credits: nil, updatedAt: 500
        )
        let before = snapshot.effective(now: 900)
        expect(before.status, .rejected, "limit stays before the reset")
        expect(before.windows[0].isReset, false, "window not reset yet")
        let after = snapshot.effective(now: 1_000)
        expect(after.windows[0].isReset, true, "window resets exactly at its reset time")
        expect(after.windows[0].usedPercent, 0, "reset window reads empty")
        expect(after.windows[0].resetsAt, nil, "reset window has no reset time")
        expect(after.status, .allowed, "limit lifts once its window reset")
        expect(after.windows[1].usedPercent, 40, "other windows are untouched")
        expect(snapshot.nextReset(after: 900), 1_000, "next reset")
        expect(snapshot.nextReset(after: 9_000), nil, "no reset ahead")
        expect(after.effective(now: 1_100) == after, true, "applying the rules twice changes nothing")
        let warm = AgentUsageSnapshot(windows: [AgentUsageWindow(id: "a", label: "a", usedPercent: 85, resetsAt: 9_000)], status: nil, credits: nil, updatedAt: 0)
        expect(warm.effective(now: 1).status, .warning, "a missing provider status is derived from usage")

        expect(AgentUsageParsing.windowLabel(minutes: 300), "5h", "300 minutes is 5h")
        expect(AgentUsageParsing.windowLabel(minutes: 10_080), "Weekly", "10080 minutes is weekly")
        expect(AgentUsageParsing.windowLabel(minutes: 30), "30m", "short window")
        expect(AgentUsageParsing.windowLabel(minutes: nil), nil, "missing duration")

        if failures.isEmpty {
            print("Agent usage parsing: \(checks) checks passed")
        } else {
            for failure in failures { FileHandle.standardError.write(Data((failure + "\n").utf8)) }
            exit(1)
        }
    }
}
