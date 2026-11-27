import AppKit
import Darwin
import QuartzCore
import SwiftUI
import PlayhouseCore
import PlayhouseViews
import PlayhouseAtoms
import PlayhouseUI

#if PLAYHOUSE_ATOM_BENCHMARK
/// A development benchmark of the atom-tree renderer, run by `scripts/benchmark-atom-tree.sh`;
/// it is not a product feature. It is compiled only when that script builds the app with the
/// PLAYHOUSE_ATOM_BENCHMARK condition, and runs only when the `PLAYHOUSE_ATOM_BENCHMARK` variable
/// names a JSON file to write.
///
/// It renders a board of card-like atom trees (Card > Stack > Icon, Stack > Text, Text, and a
/// Meter: 7 nodes a card) through `PluginNodeView` in its own window, the way a plugin's tree
/// renders, and drives it with the same ops a plugin's commits send, applied straight to the
/// tree (no JavaScript, so only the renderer is measured). Phases:
/// - open: create the board and draw its first frame;
/// - streaming: 60 updates, each changing the token counter and meter of 10 cards;
/// - allCards: 60 updates, each changing the meter of every card;
/// - scroll: a lazy 500-card list scrolled to the bottom and back, which rebuilds rows as they
///   come into view;
/// - typed: the streaming phase on a board native Swift built
///   with typed props, with no dictionaries and no decoding.
/// Each update is applied and laid out and drawn at once, as the next frame would be, from a
/// 60 Hz timer; its "busy" time is all the main-thread work until the next frame, including
/// work SwiftUI deferred. `decodes` counts prop decodes and `bodies` atom body evaluations.
@MainActor
enum AtomTreeBenchmark {
    static func runIfRequested() {
        guard let output = ProcessInfo.processInfo.environment["PLAYHOUSE_ATOM_BENCHMARK"], !output.isEmpty else { return }
        let runner = Runner(outputPath: output)
        Runner.current = runner
        // After the launch's own windows have settled, so their first layout isn't measured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { runner.start() }
    }

    static let boardCards = 300
    static let scrollCards = 500
    static let updates = 60
    static let streamingCards = 10
    static let nodesPerCard = 7

    /// The node ids of card `index`.
    struct CardIDs {
        let card, row, icon, column, title, counter, meter: Int

        init(_ index: Int) {
            let base = 10 + index * 10
            (card, row, icon, column, title, counter, meter) = (base, base + 1, base + 2, base + 3, base + 4, base + 5, base + 6)
        }
    }

    static func fraction(_ index: Int, tick: Int) -> Double { Double((index * 7 + tick) % 100) / 100 }
    static func tokens(_ index: Int, tick: Int) -> Int { 1_000 + index * 13 + tick * 97 }

    static func counterProps(_ index: Int, tick: Int) -> [String: PluginValue] {
        ["text": .string("\(tokens(index, tick: tick)) tokens"), "size": .number(11), "color": .string("secondary"), "monospacedDigits": .bool(true)]
    }

    static func meterProps(_ index: Int, tick: Int) -> [String: PluginValue] {
        ["fraction": .number(fraction(index, tick: tick)), "width": .number(120), "label": .string("Progress")]
    }

    /// The ops that create `cards` cards in a Scroll (node 1) and add it to the root.
    static func boardOps(cards: Int, lazy: Bool) -> [PluginOp] {
        var ops: [PluginOp] = [
            .create(id: 1, type: "Scroll", props: ["spacing": .number(8), "inset": .number(12), "lazy": .bool(lazy), "height": .number(960)], events: []),
            .append(parent: 0, child: 1),
        ]
        for index in 0..<cards {
            let ids = CardIDs(index)
            ops += [
                .create(id: ids.card, type: "Card", props: ["testID": .string("bench-card-\(index)"), "padding": .number(10)], events: []),
                .create(id: ids.row, type: "Stack", props: ["axis": .string("h"), "spacing": .number(10), "align": .string("center")], events: []),
                .create(id: ids.icon, type: "Icon", props: ["name": .string("bolt.fill"), "size": .number(13), "color": .string("accent")], events: []),
                .create(id: ids.column, type: "Stack", props: ["spacing": .number(2), "align": .string("leading"), "fillWidth": .bool(true)], events: []),
                .create(id: ids.title, type: "Text", props: ["text": .string("Task \(index): streaming tokens"), "weight": .string("semibold"), "lineLimit": .number(1)], events: []),
                .create(id: ids.counter, type: "Text", props: counterProps(index, tick: 0), events: []),
                .create(id: ids.meter, type: "Meter", props: meterProps(index, tick: 0), events: []),
                .append(parent: ids.column, child: ids.title),
                .append(parent: ids.column, child: ids.counter),
                .append(parent: ids.row, child: ids.icon),
                .append(parent: ids.row, child: ids.column),
                .append(parent: ids.row, child: ids.meter),
                .append(parent: ids.card, child: ids.row),
                .append(parent: 1, child: ids.card),
            ]
        }
        return ops
    }

    /// Update `tick` of the streaming phase: the counter and meter of 10 cards, a different 10 each time.
    static func streamingOps(tick: Int) -> [PluginOp] {
        (0..<streamingCards).flatMap { offset -> [PluginOp] in
            let index = (tick * streamingCards + offset) % boardCards
            let ids = CardIDs(index)
            return [.update(id: ids.counter, props: counterProps(index, tick: tick + 1), events: []),
                    .update(id: ids.meter, props: meterProps(index, tick: tick + 1), events: [])]
        }
    }

    /// Update `tick` of the all-cards phase: every card's meter.
    static func allCardsOps(tick: Int) -> [PluginOp] {
        (0..<boardCards).map { .update(id: CardIDs($0).meter, props: meterProps($0, tick: tick + 1), events: []) }
    }

    /// The same board as `boardOps` (not lazy), built by native Swift with typed props: no
    /// dictionaries and no decoding. Returns its root and its cards' counter and meter nodes.
    static func typedBoard(cards: Int) -> (root: PluginNode, counters: [PluginNode], meters: [PluginNode]) {
        let root = PluginNode(id: 0, type: "#root")
        let scroll = PluginNode(id: 1, props: ScrollProps(spacing: 8, inset: 12, lazy: false), common: AtomCommon(height: 960))
        var counters: [PluginNode] = []
        var meters: [PluginNode] = []
        scroll.children = (0..<cards).map { index in
            let ids = CardIDs(index)
            let counter = PluginNode(id: ids.counter, props: typedCounter(index, tick: 0))
            let meter = PluginNode(id: ids.meter, props: typedMeter(index, tick: 0), common: AtomCommon(label: "Progress", width: 120))
            let column = PluginNode(id: ids.column, props: StackProps(spacing: 2, align: "leading"), common: AtomCommon(fillWidth: true))
            column.children = [PluginNode(id: ids.title, props: TextProps(text: "Task \(index): streaming tokens", weight: "semibold", lineLimit: 1)), counter]
            let row = PluginNode(id: ids.row, props: StackProps(axis: "h", spacing: 10, align: "center"))
            row.children = [PluginNode(id: ids.icon, props: IconProps(name: "bolt.fill", size: 13, color: "accent")), column, meter]
            let card = PluginNode(id: ids.card, props: CardProps(), common: AtomCommon(testID: "bench-card-\(index)", padding: 10))
            card.children = [row]
            counters.append(counter)
            meters.append(meter)
            return card
        }
        root.children = [scroll]
        return (root, counters, meters)
    }

    static func typedCounter(_ index: Int, tick: Int) -> TextProps {
        TextProps(text: "\(tokens(index, tick: tick)) tokens", size: 11, color: "secondary", monospacedDigits: true)
    }

    static func typedMeter(_ index: Int, tick: Int) -> MeterProps { MeterProps(fraction: fraction(index, tick: tick)) }

    /// The root's atoms, as a plugin surface shows them.
    struct BoardView: View {
        let events: any AtomEventHandler
        let root: PluginNode

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(root.children) { node in
                    PluginNodeView(node: node, events: events)
                }
            }
            .frame(width: 900, height: 1000, alignment: .topLeading)
        }
    }

    /// Main-thread time awake, from run-loop wake and sleep.
    final class BusyMeter {
        private var busy: Double = 0
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

    /// The calling thread's CPU time, user and system, in milliseconds.
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
                "median": percentile(0.5), "p95": percentile(0.95), "max": sorted.last ?? 0, "total": values.reduce(0, +)]
    }

    /// The decode and body counts since `start`.
    struct Counts {
        let decodes = AtomCounters.decodes
        let bodies = AtomCounters.bodies
        var decodesSince: Int { AtomCounters.decodes - decodes }
        var bodiesSince: Int { AtomCounters.bodies - bodies }
    }

    @MainActor
    final class Runner: NSObject {
        static var current: Runner?
        let outputPath: String
        var results: [String: Any] = [:]
        let meter = BusyMeter()
        var window: NSWindow?
        var frameTimer: Timer?
        var onFrame: (() -> Void)?

        init(outputPath: String) { self.outputPath = outputPath }

        func makeWindow<Content: View>(_ content: Content) -> (NSWindow, NSView) {
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 1000),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Atom tree benchmark"
            let host = NSHostingView(rootView: content)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            return (window, host)
        }

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

        /// Lays out and draws whatever changed now, as the next frame would.
        func renderNow(_ host: NSView) {
            host.layoutSubtreeIfNeeded()
            host.window?.displayIfNeeded()
            CATransaction.flush()
        }

        func makeRuntime() -> PluginRuntime? {
            do {
                return try PluginRuntime(source: "", sourceName: "atom-benchmark.js")
            } catch {
                results["error"] = "runtime: \(error.localizedDescription)"
                finish()
                return nil
            }
        }

        func start() {
            guard let runtime = makeRuntime() else { return }
            let counts = Counts()
            let started = CACurrentMediaTime()
            let startedCPU = AtomTreeBenchmark.threadCPUms()
            do {
                try runtime.tree.apply(AtomTreeBenchmark.boardOps(cards: boardCards, lazy: false))
            } catch {
                results["error"] = "board: \(error.localizedDescription)"
                finish()
                return
            }
            let applied = CACurrentMediaTime()
            let (window, host) = makeWindow(BoardView(events: runtime, root: runtime.tree.root))
            renderNow(host)
            results["open"] = [
                "cards": boardCards,
                "nodes": boardCards * nodesPerCard + 1,
                "applyMs": (applied - started) * 1000,
                "totalMs": (CACurrentMediaTime() - started) * 1000,
                "cpuMs": AtomTreeBenchmark.threadCPUms() - startedCPU,
                "decodes": counts.decodesSince,
                "bodies": counts.bodiesSince,
            ]
            self.window = window
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.updates(name: "streaming", host: host, changedNodes: streamingCards * 2, apply: { tick in
                    try runtime.tree.apply(AtomTreeBenchmark.streamingOps(tick: tick))
                }) {
                    self.updates(name: "allCards", host: host, changedNodes: boardCards, apply: { tick in
                        try runtime.tree.apply(AtomTreeBenchmark.allCardsOps(tick: tick))
                    }) {
                        window.close()
                        self.window = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.scroll() }
                    }
                }
            }
        }

        /// Applies `updates` updates, one a frame, then calls `then`.
        func updates(name: String, host: NSView, changedNodes: Int, apply: @escaping (Int) throws -> Void, then: @escaping () -> Void) {
            var sent = 0
            var busyCosts: [Double] = []
            var syncCosts: [Double] = []
            var applyCosts: [Double] = []
            _ = meter.take()
            let counts = Counts()
            let startedCPU = AtomTreeBenchmark.threadCPUms()
            frames { [weak self] in
                guard let self else { return }
                // The previous update's whole main-thread cost, including work SwiftUI deferred.
                let busy = self.meter.take() * 1000
                if sent > 0 { busyCosts.append(busy) }
                guard sent < AtomTreeBenchmark.updates else {
                    self.stopFrames()
                    let count = Double(AtomTreeBenchmark.updates)
                    self.results[name] = [
                        "updates": AtomTreeBenchmark.updates,
                        "changedNodesPerUpdate": changedNodes,
                        "busyPerUpdate": AtomTreeBenchmark.summary(busyCosts),
                        "syncPerUpdate": AtomTreeBenchmark.summary(syncCosts),
                        "applyPerUpdate": AtomTreeBenchmark.summary(applyCosts),
                        "cpuPerUpdateMs": (AtomTreeBenchmark.threadCPUms() - startedCPU) / count,
                        "decodesPerUpdate": Double(counts.decodesSince) / count,
                        "bodiesPerUpdate": Double(counts.bodiesSince) / count,
                    ]
                    then()
                    return
                }
                let start = CACurrentMediaTime()
                do {
                    try apply(sent)
                } catch {
                    self.stopFrames()
                    self.results["error"] = "\(name): \(error.localizedDescription)"
                    self.finish()
                    return
                }
                applyCosts.append((CACurrentMediaTime() - start) * 1000)
                self.renderNow(host)
                syncCosts.append((CACurrentMediaTime() - start) * 1000)
                sent += 1
            }
        }

        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for subview in view.subviews { if let found = scrollView(in: subview) { return found } }
            return nil
        }

        /// A lazy list of 500 cards, scrolled to the bottom and back to the top, 80 points a frame.
        func scroll() {
            guard let runtime = makeRuntime() else { return }
            do {
                try runtime.tree.apply(AtomTreeBenchmark.boardOps(cards: scrollCards, lazy: true))
            } catch {
                results["error"] = "scroll board: \(error.localizedDescription)"
                finish()
                return
            }
            let (window, host) = makeWindow(BoardView(events: runtime, root: runtime.tree.root))
            renderNow(host)
            self.window = window
            guard let scroll = scrollView(in: host) else {
                results["error"] = "no scroll view"
                finish()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                var frameWork: [Double] = []
                var down = true
                let counts = Counts()
                _ = self.meter.take()
                let startedCPU = AtomTreeBenchmark.threadCPUms()
                self.frames { [weak self] in
                    guard let self else { return }
                    let clip = scroll.contentView
                    let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
                    if down, clip.bounds.origin.y >= maxY - 0.5, frameWork.count > 10 { down = false }
                    if !down, clip.bounds.origin.y <= 0.5 {
                        self.stopFrames()
                        self.results["scroll"] = [
                            "cards": scrollCards,
                            "frames": frameWork.count,
                            "frameWork": AtomTreeBenchmark.summary(frameWork),
                            "mainThreadBusyMs": self.meter.take() * 1000,
                            "cpuMs": AtomTreeBenchmark.threadCPUms() - startedCPU,
                            "decodes": counts.decodesSince,
                            "bodies": counts.bodiesSince,
                        ]
                        window.close()
                        self.window = nil
                        self.finishPhases()
                        return
                    }
                    let start = CACurrentMediaTime()
                    let target = down ? min(maxY, clip.bounds.origin.y + 80) : max(0, clip.bounds.origin.y - 80)
                    clip.scroll(to: NSPoint(x: 0, y: target))
                    scroll.reflectScrolledClipView(clip)
                    self.renderNow(host)
                    frameWork.append((CACurrentMediaTime() - start) * 1000)
                }
            }
        }

        /// The streaming phase on a typed board: native props set directly, never
        /// decoded, and native event handlers, with no JavaScript runtime.
        func finishPhases() {
            let counts = Counts()
            let board = AtomTreeBenchmark.typedBoard(cards: boardCards)
            let (window, host) = makeWindow(BoardView(events: AtomEventHandlers(), root: board.root))
            renderNow(host)
            results["typedOpen"] = ["decodes": counts.decodesSince, "bodies": counts.bodiesSince]
            self.window = window
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.updates(name: "typed", host: host, changedNodes: streamingCards * 2, apply: { tick in
                    for offset in 0..<streamingCards {
                        let index = (tick * streamingCards + offset) % boardCards
                        board.counters[index].setProps(AtomTreeBenchmark.typedCounter(index, tick: tick + 1))
                        board.meters[index].setProps(AtomTreeBenchmark.typedMeter(index, tick: tick + 1), common: AtomCommon(label: "Progress", width: 120))
                    }
                }) {
                    window.close()
                    self.finish()
                }
            }
        }

        func finish() {
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                FileManager.default.createFile(atPath: outputPath, contents: data)
            }
            exit(0)
        }
    }
}
#endif
