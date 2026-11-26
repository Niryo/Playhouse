import AppKit
import Darwin
import QuartzCore
import SwiftUI

#if PLAYHOUSE_TRANSCRIPT_BENCHMARK || PLAYHOUSE_ATOM_BENCHMARK
/// A development benchmark of the transcript's reply rendering, run by
/// `scripts/benchmark-transcript.sh`; it is not a product feature. It is compiled only when that
/// script builds the app with the PLAYHOUSE_TRANSCRIPT_BENCHMARK condition, never into a shipped
/// build, and runs only when the `PLAYHOUSE_TRANSCRIPT_BENCHMARK` variable names a JSON file to
/// write. It renders a deterministic long
/// conversation (`fixture`) through the transcript's reply body (`replyBody`) in its own window,
/// then measures opening it, laying all of it out, scrolling it from top to bottom, and streaming
/// a long reply into it at several transcript lengths, and exits. Frames are driven by a 60 Hz
/// timer that forces layout and drawing, so a frame's work is timed directly; a hitch is a frame
/// whose work exceeds the 16.7 ms budget. Main-thread time is the time the main run loop spends awake.
@MainActor
enum TranscriptBenchmark {
    static func runIfRequested() {
        guard let output = ProcessInfo.processInfo.environment["PLAYHOUSE_TRANSCRIPT_BENCHMARK"], !output.isEmpty else { return }
        let runner = Runner(outputPath: output)
        Runner.current = runner
        // After the launch's own windows have settled, so their first layout isn't measured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { runner.start() }
    }

    struct Message: Identifiable {
        let id: String
        let isUser: Bool
        var text: String
    }

    @Observable
    final class Model {
        var messages: [Message]
        init(messages: [Message]) { self.messages = messages }
    }

    /// The transcript's reply body, as `TaskConversationView.assistantMarkdown` builds it, with
    /// no comments or side chats on it.
    static func replyBody(_ text: String, id: String) -> some View {
        AtomMarkdown(
            props: MarkdownProps(text: text, size: Double(TaskConversationView.transcriptTextSize), selectable: true),
            host: MarkdownTextHost(slot: id, identifierPrefix: "assistant-markdown", opensAnyLink: true, blocksAreGroups: true)
        )
    }

    struct TranscriptView: View {
        let model: Model
        let lazy: Bool

        var body: some View {
            ScrollView {
                Group {
                    if lazy {
                        LazyVStack(alignment: .leading, spacing: 18) { rows }.padding(20)
                    } else {
                        VStack(alignment: .leading, spacing: 18) { rows }.padding(20)
                    }
                }
                // As the transcript's own scroll view does.
                .hoverRevealScrollers()
            }
            .background(WorkspaceTheme.windowBackground)
        }

        private var rows: some View {
            ForEach(model.messages) { message in
                if message.isUser {
                    HStack(spacing: 0) {
                        Spacer(minLength: 70)
                        SelectableAnnotationText(text: message.text, highlightedRanges: [], onSelection: { _, _, _ in })
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .background(WorkspaceTheme.inputBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .frame(maxWidth: 620, alignment: .trailing)
                    }
                } else {
                    HStack(spacing: 0) {
                        TranscriptBenchmark.replyBody(message.text, id: message.id)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(WorkspaceTheme.conversationText)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 11)
                            .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("assistant-message-\(message.id)")
                            .frame(maxWidth: 620, alignment: .leading)
                        Spacer(minLength: 70)
                    }
                }
            }
        }
    }

    // MARK: Fixture

    /// `turns` user prompts, each answered by a reply that mixes prose, lists, headings, quotes,
    /// tables and large code blocks; every 50th reply, from the 26th, runs past 20,000 characters.
    static func fixture(turns: Int, idPrefix: String = "m") -> [Message] {
        var messages: [Message] = []
        for turn in 0..<turns {
            messages.append(Message(id: "\(idPrefix)-u\(turn)", isUser: true,
                                    text: "Turn \(turn): please \(verbs[turn % verbs.count]) the \(nouns[turn % nouns.count]) and explain what changed."))
            messages.append(Message(id: "\(idPrefix)-a\(turn)", isUser: false, text: reply(turn)))
        }
        return messages
    }

    private static let verbs = ["review", "refactor", "profile", "document", "test", "simplify", "trace"]
    private static let nouns = ["transcript layout", "scroll controller", "history loader", "plugin registry", "token stats", "composer"]

    static func paragraph(_ seed: Int) -> String {
        let noun = nouns[seed % nouns.count]
        return "The **\(noun)** keeps its state in `\(noun.replacingOccurrences(of: " ", with: "_"))Model`, and each update re-renders "
            + "only the rows whose inputs changed. See [the design notes](https://example.com/notes/\(seed)) for why the cache is keyed "
            + "by message ID, and *why* a streaming reply replaces its own entry instead of adding one for every partial text it passes through."
    }

    static func codeBlock(_ seed: Int, lines: Int) -> String {
        var code = ["```swift", "struct Example\(seed) {"]
        for line in 0..<lines {
            code.append("    let value\(line) = compute(\(line), seed: \(seed)) // keeps line \(line) of the sample long enough to wrap")
        }
        code.append("}")
        code.append("```")
        return code.joined(separator: "\n")
    }

    static func reply(_ turn: Int) -> String {
        if turn % 50 == 25 { return longReply(turn) }
        switch turn % 5 {
        case 0:
            return [paragraph(turn), paragraph(turn + 1), paragraph(turn + 2)].joined(separator: "\n\n")
        case 1:
            let bullets = (0..<8).map { "- Item \($0) of turn \(turn): `step\($0)` updates the \(nouns[($0 + turn) % nouns.count])." }
            let numbered = (1...5).map { "\($0). Then verify **case \($0)** with the focused test." }
            return (["## Plan for turn \(turn)", paragraph(turn)] + [bullets.joined(separator: "\n"), numbered.joined(separator: "\n")])
                .joined(separator: "\n\n")
        case 2:
            return [paragraph(turn), codeBlock(turn, lines: 40), paragraph(turn + 3)].joined(separator: "\n\n")
        case 3:
            let rows = (0..<6).map { "| Case \($0) | \(nouns[$0 % nouns.count]) | \($0 % 2 == 0 ? "Passed" : "Pending") |" }
            return (["> Note: turn \(turn) quotes the earlier answer, which still holds for the \(nouns[turn % nouns.count]).",
                     "| Case | Area | Status |\n| --- | --- | --- |\n" + rows.joined(separator: "\n"),
                     "---", paragraph(turn)]).joined(separator: "\n\n")
        default:
            return ["### Details", paragraph(turn), codeBlock(turn, lines: 80),
                    (0..<4).map { "- Follow-up \($0)" }.joined(separator: "\n")].joined(separator: "\n\n")
        }
    }

    static func longReply(_ turn: Int) -> String {
        var sections: [String] = []
        var section = 0
        while sections.joined(separator: "\n\n").count < 24_000 {
            sections.append("## Section \(section) of turn \(turn)")
            sections.append(paragraph(turn + section))
            sections.append(paragraph(turn + section + 1))
            sections.append((0..<6).map { "- Point \($0) in section \(section): `value\($0)` holds." }.joined(separator: "\n"))
            if section % 3 == 2 { sections.append(codeBlock(turn + section, lines: 20)) }
            section += 1
        }
        return sections.joined(separator: "\n\n")
    }

    /// The reply streamed token by token: prose, a list and a code block, as a long answer runs.
    static let streamedReply: String = {
        var parts: [String] = []
        for index in 0..<6 {
            parts.append("### Step \(index)")
            parts.append(paragraph(index))
            parts.append((0..<4).map { "- Check \($0) of step \(index) passes." }.joined(separator: "\n"))
            if index % 2 == 1 { parts.append(codeBlock(index, lines: 8)) }
        }
        return parts.joined(separator: "\n\n")
    }()

    // MARK: Measuring

    /// The main run loop's awake time, accumulated between `reset` calls.
    @MainActor
    final class BusyMeter {
        private(set) var busy: Double = 0
        private var wokeAt: Double?
        private var observer: CFRunLoopObserver?

        init() {
            observer = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0
            ) { [weak self] _, activity in
                guard let self else { return }
                let now = CACurrentMediaTime()
                if activity == .afterWaiting {
                    self.wokeAt = now
                } else if let wokeAt = self.wokeAt {
                    self.busy += now - wokeAt
                    self.wokeAt = nil
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        /// The time awake since the last reset, counting the current wake up to now.
        func take() -> Double {
            let now = CACurrentMediaTime()
            var total = busy
            if let wokeAt { total += now - wokeAt; self.wokeAt = now }
            busy = 0
            return total
        }

        deinit { if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) } }
    }

    static func footprintMB() -> (current: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    /// The calling thread's CPU time, user and system, in milliseconds: unlike wall time, it
    /// doesn't grow when other processes compete for the machine.
    static func threadCPUms() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        func ms(_ time: time_value_t) -> Double { Double(time.seconds) * 1000 + Double(time.microseconds) / 1000 }
        return ms(info.user_time) + ms(info.system_time)
    }

    static func summary(_ values: [Double]) -> [String: Double] {
        guard !values.isEmpty else { return [:] }
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))] }
        return ["count": Double(values.count), "mean": values.reduce(0, +) / Double(values.count),
                "median": percentile(0.5), "p95": percentile(0.95), "max": sorted.last ?? 0]
    }

    @MainActor
    final class Runner: NSObject {
        static var current: Runner?
        let outputPath: String
        var results: [String: Any] = [:]
        let meter = BusyMeter()
        var window: NSWindow?
        var frameTimer: Timer?
        var lastOpenCPUStart: Double = 0
        var lastOpenCPUms: Double = 0
        var onFrame: (() -> Void)?

        init(outputPath: String) { self.outputPath = outputPath }

        func makeWindow(_ model: Model, lazy: Bool) -> (NSWindow, NSHostingView<TranscriptView>) {
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 760, height: 900),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Transcript benchmark"
            let host = NSHostingView(rootView: TranscriptView(model: model, lazy: lazy))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            return (window, host)
        }

        /// Shows the transcript and lays out and draws its first frame, in milliseconds.
        func open(_ model: Model, lazy: Bool) -> (NSWindow, NSHostingView<TranscriptView>, Double) {
            let start = CACurrentMediaTime()
            lastOpenCPUStart = TranscriptBenchmark.threadCPUms()
            let (window, host) = makeWindow(model, lazy: lazy)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            lastOpenCPUms = TranscriptBenchmark.threadCPUms() - lastOpenCPUStart
            return (window, host, (CACurrentMediaTime() - start) * 1000)
        }

        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for subview in view.subviews { if let found = scrollView(in: subview) { return found } }
            return nil
        }

        /// Calls `handler` at 60 frames a second. A timer rather than a display link, so the
        /// benchmark also runs with the screen asleep or locked, when no display frames arrive.
        func frames(_ handler: @escaping () -> Void) {
            onFrame = handler
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFrame?() }
            }
            RunLoop.main.add(timer, forMode: .common)
            frameTimer = timer
        }

        func stopFrames() {
            frameTimer?.invalidate()
            frameTimer = nil
            onFrame = nil
        }

        /// Lays out and draws whatever changed now, in milliseconds, as the next frame would.
        func renderNow(_ host: NSView) -> Double {
            let start = CACurrentMediaTime()
            host.layoutSubtreeIfNeeded()
            host.window?.displayIfNeeded()
            CATransaction.flush()
            return (CACurrentMediaTime() - start) * 1000
        }

        func start() {
            let baseline = footprintMB()
            results["baselineFootprintMB"] = baseline.current
            let model = Model(messages: fixture(turns: 200))
            results["fixture"] = [
                "messages": model.messages.count,
                "characters": model.messages.reduce(0) { $0 + $1.text.count },
                "longestMessage": model.messages.map(\.text.count).max() ?? 0,
            ]
            // Opening: the first screen of a lazily realized transcript, as the reader sees it.
            let (window, host, openMs) = open(model, lazy: true)
            results["openFirstScreenMs"] = openMs
            results["openFirstScreenCPUms"] = lastOpenCPUms
            results["afterOpenFootprintMB"] = footprintMB().current
            self.window = window
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.scroll(host: host, model: model) }
        }

        /// Scrolls the whole transcript from top to bottom at a steady pace, one step per frame.
        func scroll(host: NSHostingView<TranscriptView>, model: Model) {
            guard let scroll = scrollView(in: host) else {
                results["error"] = "no scroll view"
                finish()
                return
            }
            let step: CGFloat = 60
            var frameWork: [Double] = []
            _ = meter.take()
            let started = CACurrentMediaTime()
            let startedCPU = TranscriptBenchmark.threadCPUms()
            frames { [weak self] in
                guard let self else { return }
                let clip = scroll.contentView
                let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
                // The document may grow as rows are realized; stop only at its settled end.
                if clip.bounds.origin.y >= maxY - 0.5, frameWork.count > 10 {
                    self.stopFrames()
                    let busy = self.meter.take()
                    let duration = CACurrentMediaTime() - started
                    let budget = 1000.0 / 60
                    let hitches = frameWork.filter { $0 > budget }
                    self.results["scroll"] = [
                        "frames": frameWork.count,
                        "durationS": duration,
                        "documentHeight": scroll.documentView?.frame.height ?? 0,
                        "frameWork": TranscriptBenchmark.summary(frameWork),
                        "hitchCount": hitches.count,
                        "severeHitchCount": frameWork.filter { $0 > budget * 2 }.count,
                        "hitchTimeMs": hitches.reduce(0) { $0 + ($1 - budget) },
                        "longestFrameMs": frameWork.max() ?? 0,
                        "frameWorkTotalMs": frameWork.reduce(0, +),
                        "mainThreadBusyMs": busy * 1000,
                        "mainThreadCPUms": TranscriptBenchmark.threadCPUms() - startedCPU,
                    ]
                    self.results["afterScrollFootprintMB"] = TranscriptBenchmark.footprintMB().current
                    self.window?.close()
                    self.window = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.fullLayout() }
                    return
                }
                let start = CACurrentMediaTime()
                clip.scroll(to: NSPoint(x: 0, y: min(maxY, clip.bounds.origin.y + step)))
                scroll.reflectScrolledClipView(clip)
                _ = self.renderNow(host)
                frameWork.append((CACurrentMediaTime() - start) * 1000)
            }
        }

        /// Lays out every message at once, as a transcript that realized all its rows would.
        func fullLayout() {
            let model = Model(messages: fixture(turns: 200, idPrefix: "full"))
            let (window, _, ms) = open(model, lazy: false)
            results["fullLayoutMs"] = ms
            results["fullLayoutCPUms"] = lastOpenCPUms
            results["afterFullLayoutFootprintMB"] = footprintMB().current
            window.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.stream(lengths: [10, 100, 200], results: [:]) }
        }

        /// Streams `streamedReply` into a new last reply, a few characters per frame, at each
        /// transcript length, recording each update's main-thread time.
        func stream(lengths: [Int], results streaming: [String: Any]) {
            guard let turns = lengths.first else {
                results["streaming"] = streaming
                finish()
                return
            }
            var messages = fixture(turns: turns, idPrefix: "s\(turns)")
            messages.append(Message(id: "s\(turns)-u-stream", isUser: true, text: "Stream a long answer."))
            messages.append(Message(id: "s\(turns)-a-stream", isUser: false, text: ""))
            let model = Model(messages: messages)
            let (window, host, _) = open(model, lazy: true)
            if let scroll = scrollView(in: host) {
                // Follow the bottom, where the streaming reply grows.
                scroll.documentView?.scroll(NSPoint(x: 0, y: scroll.documentView?.frame.height ?? 0))
            }
            let full = Array(TranscriptBenchmark.streamedReply)
            let updates = 400
            let chunk = 5
            var sent = 0
            var busyCosts: [Double] = []
            var syncCosts: [Double] = []
            var startedCPU: Double = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                _ = self.meter.take()
                startedCPU = TranscriptBenchmark.threadCPUms()
                self.frames { [weak self] in
                    guard let self else { return }
                    // The previous update's whole main-thread cost, including work SwiftUI deferred.
                    let busy = self.meter.take() * 1000
                    if sent > 0 { busyCosts.append(busy) }
                    guard sent < updates else {
                        self.stopFrames()
                        var streaming = streaming
                        streaming["\(turns)"] = TranscriptBenchmark.summary(busyCosts)
                        streaming["\(turns)-sync"] = TranscriptBenchmark.summary(syncCosts)
                        streaming["\(turns)-cpuPerUpdateMs"] = (TranscriptBenchmark.threadCPUms() - startedCPU) / Double(updates)
                        window.close()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            self.stream(lengths: Array(lengths.dropFirst()), results: streaming)
                        }
                        return
                    }
                    let start = CACurrentMediaTime()
                    let end = min(full.count, (sent + 1) * chunk)
                    model.messages[model.messages.count - 1].text = String(full[0..<end])
                    _ = self.renderNow(host)
                    if let scroll = self.scrollView(in: host) {
                        scroll.documentView?.scroll(NSPoint(x: 0, y: scroll.documentView?.frame.height ?? 0))
                        _ = self.renderNow(host)
                    }
                    syncCosts.append((CACurrentMediaTime() - start) * 1000)
                    sent += 1
                }
            }
        }

        func finish() {
            results["peakFootprintMB"] = footprintMB().peak
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                FileManager.default.createFile(atPath: outputPath, contents: data)
            }
            exit(0)
        }
    }
}
#endif
