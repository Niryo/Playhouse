import Foundation

// Pure-logic checks of where provider dividers and goal achievements sit in the transcript, in
// Playhouse/App/TranscriptRowAnchors.swift, compiled with it and run by scripts/test-e2e.sh
// before the bridge suite. The bridge case `test_transcript_rows_stay_with_older_messages`
// covers the same placement end to end, against paged history and the visible transcript.

@main
struct TranscriptRowAnchorsTests {
    static var failures: [String] = []
    static var checks = 0

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        checks += 1
        if actual != expected { failures.append("\(message): expected \(expected), got \(actual)") }
    }

    /// A row recorded after a message: a provider divider or a goal achievement.
    struct Row: Equatable, CustomStringConvertible {
        let name: String
        let afterMessageID: String
        var description: String { name }
    }

    /// The transcript as the view holds it: the loaded messages, the ones folded out of view,
    /// and the rendered window at the end of the loaded ones.
    struct Transcript {
        var loaded: [String]
        var folded: Set<String> = []
        var renderedCount: Int

        var visible: [String] { loaded.filter { !folded.contains($0) } }
        var rendered: [String] { Array(visible.suffix(renderedCount)) }

        func placement(_ rows: [Row]) -> [String: [Row]] {
            let visibleIDs = Set(visible)
            return TranscriptRowAnchors.rowsByRenderedAnchor(rows, renderedIDs: Set(rendered)) {
                TranscriptRowAnchors.visibleAnchor(after: $0.afterMessageID, loadedIDs: loaded, visibleIDs: visibleIDs)
            }
        }

        /// The rendered rows in order, each message followed by its rows.
        func layout(_ rows: [Row]) -> [String] {
            let placed = placement(rows)
            return rendered.flatMap { [$0] + (placed[$0] ?? []).map(\.name) }
        }
    }

    static func message(_ number: Int) -> String { "m\(number)" }

    static func main() {
        // 612 messages; the newest 80 are loaded and the newest 20 rendered.
        let all = (1...612).map(message)
        var transcript = Transcript(loaded: Array(all.suffix(80)), renderedCount: 20)
        for kind in ["divider", "goal"] {
            let rows = [
                Row(name: "\(kind) to Codex", afterMessageID: message(525)),
                Row(name: "\(kind) to Claude", afterMessageID: message(525)),
            ]
            expect(transcript.placement(rows).isEmpty, true, "A \(kind) whose message is not loaded is not drawn")
            expect(transcript.layout(rows).last, message(612), "The newest message stays last with a \(kind) above the loaded history")

            var appended = transcript
            appended.loaded.append(message(613))
            expect(appended.placement(rows).isEmpty, true, "A new message does not pull an unloaded \(kind) after it")
            expect(appended.layout(rows).last, message(613), "The newest message stays last after it arrives")

            // Loading the earlier page and revealing it puts the rows right after their message.
            var earlier = transcript
            earlier.loaded = Array(all.suffix(160))
            earlier.renderedCount = 100
            let layout = earlier.layout(rows)
            let anchor = layout.firstIndex(of: message(525)) ?? -1
            expect(Array(layout[(anchor + 1)...(anchor + 3)]), ["\(kind) to Codex", "\(kind) to Claude", message(526)],
                   "A loaded \(kind) follows its message, in recorded order, before the next message")
            expect(layout.last, message(612), "A loaded \(kind) is never drawn after the newest message")

            // Loaded but above the rendered window: drawn once the window reaches its message.
            var aboveWindow = earlier
            aboveWindow.renderedCount = 20
            expect(aboveWindow.placement(rows).isEmpty, true, "A \(kind) above the rendered window waits for its message")

            // A folded message hands its rows to the nearest visible message before it.
            var folded = earlier
            folded.folded = [message(524), message(525)]
            let foldedRows = [Row(name: "\(kind) after folded", afterMessageID: message(525))]
            expect(folded.placement(foldedRows)[message(523)] ?? [], foldedRows,
                   "A \(kind) after a folded message follows the nearest visible earlier message")
            expect(folded.placement(foldedRows)[message(612)] ?? [], [], "A \(kind) after a folded message never follows the newest message")

            // Every message at or before the row's is folded: nothing visible precedes it.
            var allFolded = earlier
            allFolded.folded = Set(all.prefix(525))
            expect(allFolded.placement(foldedRows).isEmpty, true, "A \(kind) with no visible message before it is not drawn after a newer one")
        }

        // A row anchored to the rendered newest message still follows it.
        let latest = [Row(name: "latest", afterMessageID: message(612))]
        expect(transcript.layout(latest).suffix(2), [message(612), "latest"], "A row after the newest message follows it")
        transcript.loaded.append(message(613))
        expect(transcript.layout(latest).suffix(3), [message(612), "latest", message(613)], "It stays in place when a newer message arrives")

        if failures.isEmpty {
            print("Transcript row anchor checks passed (\(checks) checks).")
        } else {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
    }
}
