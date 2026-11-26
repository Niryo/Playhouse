import AppKit
import Darwin
import OSLog
import QuartzCore
import SwiftUI

#if PLAYHOUSE_ATOM_BENCHMARK
/// The atom-tree spike's board benchmark, run by `scripts/benchmark-task-item.sh`; not a product
/// feature, compiled only into PLAYHOUSE_ATOM_BENCHMARK builds and run only when
/// `PLAYHOUSE_TASK_ITEM_BENCHMARK` names a JSON file to write. One process measures one variant
/// (`PLAYHOUSE_TASK_ITEM_BENCHMARK_VARIANT`: native, tree or tree-dynamic) in one scenario
/// (`PLAYHOUSE_TASK_ITEM_BENCHMARK_SCENARIO`), so memory readings don't mix:
/// - `board-N`: a board of N task items in four columns, as the real board lays them out
///   (eager columns, every card built): opening it, scrolling it down (to the bottom or 300
///   frames) and back, memory;
/// - `live-N`: a board of N cards where 100 of them change tokens, CPU and progress 10 times a
///   second for 30 seconds, with a 60 Hz frame clock;
/// - `interaction`: hovering over, pressing, right-clicking (the context menu) and rendering the
///   drag preview of cards on a 500-card board, with synthetic mouse events.
/// Each card's model sits in its own observable box, as each real card observes its own task, so
/// a change re-renders only its card. Frames are forced (layout, display, flush) from a 60 Hz
/// timer, so a frame's work is timed directly; a hitch is a frame over the 16.7 ms budget.
@MainActor
enum TaskItemBenchmark {
    static let signposter = OSSignposter(subsystem: "Playhouse", category: "AtomTreeBenchmark")

    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["PLAYHOUSE_TASK_ITEM_BENCHMARK"], !output.isEmpty else { return }
        let variant = TaskItemRenderer(rawValue: environment["PLAYHOUSE_TASK_ITEM_BENCHMARK_VARIANT"] ?? "") ?? .native
        let scenario = environment["PLAYHOUSE_TASK_ITEM_BENCHMARK_SCENARIO"] ?? "board-50"
        let runner = Runner(outputPath: output, variant: variant, scenario: scenario)
        Runner.current = runner
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { runner.start() }
    }

    // MARK: Fixture

    @Observable
    final class CardBox: Identifiable {
        let id: String
        var model: TaskItemModel
        init(_ model: TaskItemModel) {
            id = model.id
            self.model = model
        }
    }

    static let epoch = Date.now.timeIntervalSince1970
    static let titles = ["Fix the flaky board drag test", "Speed up transcript layout", "Add Linux build of the bridge daemon",
                         "Review PR #412: plugin network sandbox", "Generating title…", "Migrate settings to the new store",
                         "Investigate CPU spike when 40 agents stream at once and the board redraws every card"]

    /// A deterministic mix: a third working with a progress report, tokens and CPU; some blocked
    /// with a status message; some scheduled; some generating their title.
    /// `PLAYHOUSE_TASK_ITEM_BENCHMARK_NO_CLOCKS`: no card is working, so no card has a running
    /// clock (the native card's `TimelineView`, the tree's once-a-second tick).
    static let noClocks = ProcessInfo.processInfo.environment["PLAYHOUSE_TASK_ITEM_BENCHMARK_NO_CLOCKS"] == "1"

    static func model(_ index: Int, tick: Int = 0) -> TaskItemModel {
        let working = index % 3 == 0
        let tokens = 12_000 + index * 977 + tick * 4_321
        return TaskItemModel(
            id: String(format: "00000000-0000-0000-0000-%012d", index),
            title: titles[index % titles.count] + (index % titles.count == 4 ? "" : " (\(index))"),
            titleSpinner: index % titles.count == 4,
            progress: working ? .init(label: ["Testing", "Building", "Searching", "Writing"][(index + tick) % 4],
                                      detail: "Step \(tick % 50) of 50: CLI/XPC \(index % 8 + 1)/8", symbol: ["checkmark.seal", "hammer", "magnifyingglass", "pencil"][(index + tick) % 4]) : nil,
            schedule: index % 11 == 5 ? "in 2 hours" : nil,
            statusMessage: index % 7 == 3 ? "Waiting for the user to choose between two migration plans before continuing." : nil,
            statusIsBlocked: index % 14 == 3,
            isWorking: working && !noClocks,
            workingSince: working ? epoch - Double(index * 37 % 5_000) : nil,
            workedSeconds: working ? Double(index * 113 % 20_000) : 0,
            createdText: "Nov \(index % 28 + 1), 2026",
            tokens: index % 4 == 3 ? nil : .init(compact: TokenUsageHeatmap.compact(tokens), color: AtomColor.hex(TokenUsageHeatmap.color(totalTokens: tokens, max: 2_000_000)),
                                                 description: TokenUsageHeatmap.label(totalTokens: tokens)),
            cpu: working ? .init(fraction: Double((index * 7 + tick * 13) % 100) / 100, label: "\((index * 7 + tick * 13) % 100)% CPU") : nil,
            hasPluginRow: false,
            canMoveToDone: index % 2 == 0,
            canMoveToReview: index % 5 == 1
        )
    }

    // MARK: Views

    struct Card: View {
        let box: CardBox
        let variant: TaskItemRenderer
        let actions: TaskItemActions
        /// Reports the card's frame in the window, for the interaction scenario only.
        var onFrame: ((String, CGRect) -> Void)?

        var body: some View {
            let card = Group {
                switch variant {
                case .native: TaskItemView(model: box.model, actions: actions)
                case .tree: TaskItemTreeView(model: box.model, actions: actions)
                case .treeDynamic: TaskItemTreeView(model: box.model, actions: actions, dynamicProps: true)
                }
            }
            // As the board makes Review and Waiting Response cards draggable.
            .onDrag { NSItemProvider(object: box.id as NSString) }
            if let onFrame {
                card.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame(box.id, $0) }
            } else {
                card
            }
        }
    }

    struct Board: View {
        let columns: [[CardBox]]
        let variant: TaskItemRenderer
        let actions: (CardBox) -> TaskItemActions
        var onFrame: ((String, CGRect) -> Void)?
        static let statuses: [TaskStatus] = [.backlog, .inProgress, .review, .blocked]

        var body: some View {
            ScrollView {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { offset, cards in
                        KanbanColumnSection(model: KanbanColumnModel(status: Self.statuses[offset % 4], taskCount: cards.count), minHeight: 480) {
                            ForEach(cards) { box in
                                Card(box: box, variant: variant, actions: actions(box), onFrame: onFrame)
                            }
                        }
                        .frame(width: 290)
                    }
                }
                .padding(16)
                .hoverRevealScrollers()
            }
            .frame(width: 1260, height: 1000, alignment: .topLeading)
            .background(WorkspaceTheme.windowBackground)
        }
    }

    // MARK: Measuring

    static func footprintMB() -> (current: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    /// Prop decodes, node view bodies (`PluginNodeView`, trees only) and atom view bodies
    /// (native and tree alike) since `init`.
    struct ViewCounts {
        let decodes = AtomCounters.decodes, bodies = AtomCounters.bodies, views = AtomCounters.views
        var decodesSince: Int { AtomCounters.decodes - decodes }
        var bodiesSince: Int { AtomCounters.bodies - bodies }
        var viewsSince: Int { AtomCounters.views - views }
    }

    static func frameStats(_ frames: [Double]) -> [String: Any] {
        let budget = 1000.0 / 60
        let hitches = frames.filter { $0 > budget }
        return [
            "frames": frames.count,
            "frameWork": AtomTreeBenchmark.summary(frames),
            "hitchCount": hitches.count,
            "severeHitchCount": frames.filter { $0 > budget * 2 }.count,
            "hitchTimeMs": hitches.reduce(0) { $0 + ($1 - budget) },
        ]
    }

    @MainActor
    final class Runner: NSObject {
        static var current: Runner?
        let outputPath: String
        let variant: TaskItemRenderer
        let scenario: String
        var results: [String: Any] = [:]
        let meter = AtomTreeBenchmark.BusyMeter()
        var window: NSWindow?
        var frameTimer: Timer?
        var onFrame: (() -> Void)?
        var columns: [[CardBox]] = []
        var pressed: [String: Double] = [:]
        var cardFrames: [String: CGRect] = [:]
        var pressToAction: [Double] = []

        init(outputPath: String, variant: TaskItemRenderer, scenario: String) {
            self.outputPath = outputPath
            self.variant = variant
            self.scenario = scenario
        }

        func makeBoard(cards: Int) -> [[CardBox]] {
            var columns: [[CardBox]] = [[], [], [], []]
            for index in 0..<cards { columns[index % 4].append(CardBox(TaskItemBenchmark.model(index))) }
            return columns
        }

        func actions(_ box: CardBox) -> TaskItemActions {
            TaskItemActions(open: { [weak self] in self?.pressed[box.id] = CACurrentMediaTime() }, menu: { _ in }, showTokenStats: {})
        }

        func open(cards: Int) -> NSView {
            columns = makeBoard(cards: cards)
            let before = TaskItemBenchmark.footprintMB().current
            let counts = ViewCounts()
            let started = CACurrentMediaTime()
            let startedCPU = AtomTreeBenchmark.threadCPUms()
            let state = TaskItemBenchmark.signposter.beginInterval("open board")
            let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1260, height: 1000), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Task item benchmark (\(variant.rawValue))"
            let trackFrames = scenario == "interaction"
            let host = NSHostingView(rootView: Board(columns: columns, variant: variant, actions: { [unowned self] in self.actions($0) },
                                                     onFrame: trackFrames ? { [unowned self] id, frame in self.cardFrames[id] = frame } : nil))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            renderNow(host)
            TaskItemBenchmark.signposter.endInterval("open board", state)
            results["open"] = [
                "cards": cards,
                "totalMs": (CACurrentMediaTime() - started) * 1000,
                "cpuMs": AtomTreeBenchmark.threadCPUms() - startedCPU,
                "footprintDeltaMB": TaskItemBenchmark.footprintMB().current - before,
                "decodes": counts.decodesSince,
                "nodeBodies": counts.bodiesSince,
                "atomViewBodies": counts.viewsSince,
            ]
            results["baselineFootprintMB"] = before
            self.window = window
            return host
        }

        func renderNow(_ host: NSView) {
            let state = TaskItemBenchmark.signposter.beginInterval("render")
            host.layoutSubtreeIfNeeded()
            host.window?.displayIfNeeded()
            CATransaction.flush()
            TaskItemBenchmark.signposter.endInterval("render", state)
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

        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for subview in view.subviews { if let found = scrollView(in: subview) { return found } }
            return nil
        }

        func start() {
            results["variant"] = variant.rawValue
            results["scenario"] = scenario
            results["noClocks"] = TaskItemBenchmark.noClocks
            if scenario.hasPrefix("board-"), let cards = Int(scenario.dropFirst(6)) {
                let host = open(cards: cards)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.scroll(host) }
            } else if scenario.hasPrefix("live-"), let cards = Int(scenario.dropFirst(5)) {
                let host = open(cards: cards)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.live(host) }
            } else if scenario == "interaction" {
                let host = open(cards: 500)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.interact(host) }
            } else {
                results["error"] = "unknown scenario \(scenario)"
                finish()
            }
        }

        /// Scrolls the board to the bottom (at most 300 frames) and back, 80 points a frame.
        func scroll(_ host: NSView) {
            guard let scroll = scrollView(in: host) else {
                results["error"] = "no scroll view"
                return finish()
            }
            var frameWork: [Double] = []
            var down = true
            let counts = ViewCounts()
            _ = meter.take()
            let startedCPU = AtomTreeBenchmark.threadCPUms()
            let started = CACurrentMediaTime()
            frames { [weak self] in
                guard let self else { return }
                let clip = scroll.contentView
                let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
                // At most 300 frames (24,000 points) down, so a 2000-card board ends in time.
                if down, clip.bounds.origin.y >= maxY - 0.5 || frameWork.count >= 300 { down = false }
                if !down, clip.bounds.origin.y <= 0.5 {
                    self.stopFrames()
                    var stats = TaskItemBenchmark.frameStats(frameWork)
                    stats["documentHeight"] = scroll.documentView?.frame.height ?? 0
                    stats["durationS"] = CACurrentMediaTime() - started
                    stats["mainThreadBusyMs"] = self.meter.take() * 1000
                    stats["cpuMs"] = AtomTreeBenchmark.threadCPUms() - startedCPU
                    stats["nodeBodies"] = counts.bodiesSince
                    stats["atomViewBodies"] = counts.viewsSince
                    self.results["scroll"] = stats
                    self.results["afterScrollFootprintMB"] = TaskItemBenchmark.footprintMB().current
                    return self.finish()
                }
                let start = CACurrentMediaTime()
                let target = down ? min(maxY, clip.bounds.origin.y + 80) : max(0, clip.bounds.origin.y - 80)
                clip.scroll(to: NSPoint(x: 0, y: target))
                scroll.reflectScrolledClipView(clip)
                self.renderNow(host)
                frameWork.append((CACurrentMediaTime() - start) * 1000)
            }
        }

        /// 100 cards change tokens, CPU and progress 10 times a second for 30 seconds; every
        /// frame is forced and timed.
        func live(_ host: NSView) {
            let boxes = columns.flatMap { $0 }
            // 100 cards spread over the board (all of them on a board of 100).
            let stride = max(1, boxes.count / 100)
            let changing = Array(boxes.enumerated().filter { $0.offset % stride == 0 }.map(\.element).prefix(100))
            let duration = 30.0
            let updatesPerSecond = 10.0
            var frameWork: [Double] = []
            var updateWork: [Double] = []
            var updateBusy: [Double] = []
            var tick = 0
            var frame = 0
            var busySinceUpdate = 0.0
            let counts = ViewCounts()
            _ = meter.take()
            let startedCPU = AtomTreeBenchmark.threadCPUms()
            let started = CACurrentMediaTime()
            let framesPerUpdate = Int(60 / updatesPerSecond)
            frames { [weak self] in
                guard let self else { return }
                // Main-thread time awake since the last frame, including SwiftUI's deferred work.
                busySinceUpdate += self.meter.take() * 1000
                guard CACurrentMediaTime() - started < duration else {
                    self.stopFrames()
                    let elapsed = CACurrentMediaTime() - started
                    let cpu = AtomTreeBenchmark.threadCPUms() - startedCPU
                    var stats = TaskItemBenchmark.frameStats(frameWork)
                    stats["updates"] = tick
                    stats["changingCards"] = changing.count
                    stats["updateWork"] = AtomTreeBenchmark.summary(updateWork)
                    stats["busyPerUpdate"] = AtomTreeBenchmark.summary(updateBusy)
                    stats["mainThreadCPUms"] = cpu
                    stats["mainThreadPercent"] = cpu / (elapsed * 1000) * 100
                    stats["nodeBodies"] = counts.bodiesSince
                    stats["atomViewBodies"] = counts.viewsSince
                    stats["decodes"] = counts.decodesSince
                    stats["atomViewBodiesPerUpdate"] = Double(counts.viewsSince) / Double(max(1, tick))
                    stats["decodesPerUpdate"] = Double(counts.decodesSince) / Double(max(1, tick))
                    self.results["live"] = stats
                    self.results["afterLiveFootprintMB"] = TaskItemBenchmark.footprintMB().current
                    return self.finish()
                }
                let start = CACurrentMediaTime()
                if frame % framesPerUpdate == 0 {
                    if tick > 0 { updateBusy.append(busySinceUpdate) }
                    busySinceUpdate = 0
                    tick += 1
                    let state = TaskItemBenchmark.signposter.beginInterval("live update")
                    for box in changing {
                        let index = Int(box.id.suffix(12)) ?? 0
                        box.model = TaskItemBenchmark.model(index, tick: tick)
                    }
                    self.renderNow(host)
                    TaskItemBenchmark.signposter.endInterval("live update", state)
                    updateWork.append((CACurrentMediaTime() - start) * 1000)
                } else {
                    self.renderNow(host)
                }
                frameWork.append((CACurrentMediaTime() - start) * 1000)
                frame += 1
            }
        }

        // MARK: Interaction

        /// The center of card `id`, in window coordinates.
        func center(of id: String, host: NSView) -> NSPoint? {
            guard let frame = cardFrames[id] else { return nil }
            return NSPoint(x: frame.midX, y: host.bounds.height - frame.midY)
        }

        func mouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0)
        }

        /// Idle: 5 seconds with nothing changing but the working cards' clocks.
        func interact(_ host: NSView) {
            _ = meter.take()
            let startedCPU = AtomTreeBenchmark.threadCPUms()
            let counts = ViewCounts()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                let cpu = AtomTreeBenchmark.threadCPUms() - startedCPU
                self.results["idle"] = ["mainThreadPercent": cpu / 5_000 * 100, "mainThreadBusyMs": self.meter.take() * 1000,
                                        "atomViewBodiesPerSecond": Double(counts.viewsSince) / 5, "nodeBodiesPerSecond": Double(counts.bodiesSince) / 5]
                self.interactWithCards(host)
            }
        }

        func interactWithCards(_ host: NSView) {
            guard let window = host.window else { return finish() }
            let boxes = Array(columns[0].prefix(6)) + Array(columns[1].prefix(6))
            let points = boxes.compactMap { box in center(of: box.id, host: host).map { (box, $0) } }
            guard points.count == boxes.count else {
                results["error"] = "found \(points.count) of \(boxes.count) cards"
                return finish()
            }
            // Hover: move across the cards, each move dispatched and the frame drawn.
            var hover: [Double] = []
            for _ in 0..<5 {
                for (_, point) in points {
                    for offset in stride(from: -30.0, through: 30.0, by: 10) {
                        let start = CACurrentMediaTime()
                        if let event = mouse(.mouseMoved, at: NSPoint(x: point.x + offset, y: point.y), window: window) { window.sendEvent(event) }
                        renderNow(host)
                        hover.append((CACurrentMediaTime() - start) * 1000)
                    }
                }
            }
            results["hover"] = AtomTreeBenchmark.summary(hover)
            pressSequence(points: points, host: host, window: window, index: 0, latencies: [])
        }

        /// Press: mouse down and up on a card until its open action runs (the card defers it one
        /// main-queue turn), then the frame drawn.
        func pressSequence(points: [(CardBox, NSPoint)], host: NSView, window: NSWindow, index: Int, latencies: [Double]) {
            let rounds = 3
            guard index < points.count * rounds else {
                results["press"] = AtomTreeBenchmark.summary(latencies)
                results["pressToAction"] = AtomTreeBenchmark.summary(pressToAction)
                results["pressedCards"] = latencies.count
                return menuSequence(points: points, host: host, window: window, index: 0, latencies: [])
            }
            let (box, point) = points[index % points.count]
            pressed[box.id] = nil
            let start = CACurrentMediaTime()
            // Queued, not sent: the button's tracking loop takes the mouse up from the queue.
            if let down = mouse(.leftMouseDown, at: point, window: window), let up = mouse(.leftMouseUp, at: point, window: window) {
                NSApp.postEvent(down, atStart: false)
                NSApp.postEvent(up, atStart: false)
            }
            func wait(_ tries: Int) {
                if let at = pressed[box.id] {
                    renderNow(host)
                    pressToAction.append((at - start) * 1000)
                    return pressSequence(points: points, host: host, window: window, index: index + 1, latencies: latencies + [(CACurrentMediaTime() - start) * 1000])
                }
                guard CACurrentMediaTime() - start < 2 else { return pressSequence(points: points, host: host, window: window, index: index + 1, latencies: latencies) }
                DispatchQueue.main.async { wait(tries + 1) }
            }
            DispatchQueue.main.async { wait(0) }
        }

        /// Context menu: right mouse down on a card until AppKit starts tracking its menu, which
        /// is then cancelled.
        func menuSequence(points: [(CardBox, NSPoint)], host: NSView, window: NSWindow, index: Int, latencies: [Double]) {
            guard index < points.count * 2 else {
                results["menu"] = AtomTreeBenchmark.summary(latencies)
                return dragPreview(points: points, host: host)
            }
            let (_, point) = points[index % points.count]
            var began: Double?
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                began = CACurrentMediaTime()
                let menu = note.object as? NSMenu
                let timer = Timer(timeInterval: 0.05, repeats: false) { _ in menu?.cancelTrackingWithoutAnimation() }
                RunLoop.main.add(timer, forMode: .eventTracking)
                RunLoop.main.add(timer, forMode: .common)
            }
            let start = CACurrentMediaTime()
            if let down = mouse(.rightMouseDown, at: point, window: window) { window.sendEvent(down) }
            if let up = mouse(.rightMouseUp, at: point, window: window) { window.sendEvent(up) }
            NotificationCenter.default.removeObserver(observer)
            let next = began.map { latencies + [($0 - start) * 1000] } ?? latencies
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.menuSequence(points: points, host: host, window: window, index: index + 1, latencies: next)
            }
        }

        /// The drag preview: AppKit snapshots the dragged card's view, so render each card on its
        /// own into an image, as a drag's start does.
        func dragPreview(points: [(CardBox, NSPoint)], host: NSView) {
            var costs: [Double] = []
            for _ in 0..<3 {
                for (box, _) in points {
                    let start = CACurrentMediaTime()
                    let renderer = ImageRenderer(content: Card(box: box, variant: variant, actions: TaskItemActions()).frame(width: 262))
                    renderer.scale = 2
                    _ = renderer.nsImage
                    costs.append((CACurrentMediaTime() - start) * 1000)
                }
            }
            results["dragPreview"] = AtomTreeBenchmark.summary(costs)
            finish()
        }

        func finish() {
            stopFrames()
            results["peakFootprintMB"] = TaskItemBenchmark.footprintMB().peak
            results["phases"] = TaskItemTreeHost.phaseTimes
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                FileManager.default.createFile(atPath: outputPath, contents: data)
            }
            exit(0)
        }
    }
}
#endif
