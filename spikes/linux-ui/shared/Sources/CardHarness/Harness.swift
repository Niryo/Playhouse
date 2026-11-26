import CardModel
import Foundation
import GtkProbe

/// What a run does, from environment variables set by run.sh:
///   PH_SCENE   card (one card) | board (PH_CARDS cards in a scroll view)
///   PH_ACTION  idle | shot | startup | scroll | live | redraw
///   PH_SHOT    PNG path for `shot`; PH_SHOT_DELAY seconds before taking it
///   PH_WORKING 1 = the single card is running (live clock)
///   PH_EXPANDED 1 = cards start expanded; PH_SELECTED 1 = the card starts selected
///   PH_T0_US   launch time (wall clock, µs) for startup timing
///   PH_DURATION / PH_LIVE_CARDS / PH_LIVE_HZ for `live`
public struct HarnessConfig: Sendable {
    public let scene: String
    public let action: String
    public let cards: Int
    public let working: Bool
    public let expanded: Bool
    public let selected: Bool
    public let shotPath: String
    public let shotDelay: Double
    public let duration: Double
    public let liveCards: Int
    public let liveHz: Double

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        scene = environment["PH_SCENE"] ?? "card"
        action = environment["PH_ACTION"] ?? "idle"
        cards = Int(environment["PH_CARDS"] ?? "") ?? 50
        working = environment["PH_WORKING"] == "1"
        expanded = environment["PH_EXPANDED"] == "1"
        selected = environment["PH_SELECTED"] == "1"
        shotPath = environment["PH_SHOT"] ?? "/tmp/card.png"
        shotDelay = Double(environment["PH_SHOT_DELAY"] ?? "") ?? 1.5
        duration = Double(environment["PH_DURATION"] ?? "") ?? 30
        liveCards = Int(environment["PH_LIVE_CARDS"] ?? "") ?? 100
        liveHz = Double(environment["PH_LIVE_HZ"] ?? "") ?? 10
    }

    public static let current = HarnessConfig()
}

/// Runs the configured benchmark or screenshot against whichever UI library
/// built the window. It only touches GTK through GtkProbe and the app model
/// through `BoardModel`, so both demos are measured identically.
@MainActor
public final class Harness {
    public let config: HarnessConfig
    public let board: BoardModel

    public init(config: HarnessConfig = .current) {
        self.config = config
        let now = Date()
        if config.scene == "board" {
            board = BoardModel(cards: Samples.board(count: config.cards, now: now))
        } else {
            board = BoardModel(cards: [config.working ? Samples.working(now: now) : Samples.reference()])
        }
        if config.selected { board.selectedID = board.cards.first?.id }
    }

    /// Call before the library starts its main loop.
    public func install() {
        print(ObservationCheck.report())
        ph_flush()
        let t0 = Int64(ProcessInfo.processInfo.environment["PH_T0_US"] ?? "") ?? 0
        // Roughly 100 px per card: "content laid out" means most cards have a size.
        ph_probe_install(t0, config.scene == "board" ? Double(config.cards) * 80 : 0)
        // The app clock: every working card's time row reads `board.now`.
        if ProcessInfo.processInfo.environment["PH_NO_CLOCK"] != "1" {
            every(1.0) { [board] in board.now = Date(); return true }
        }
        after(0.2) { [self] in waitForWindow() }
    }

    private func waitForWindow() {
        guard ph_probe_window() != nil else {
            after(0.05) { [self] in waitForWindow() }
            return
        }
        if let pick = ProcessInfo.processInfo.environment["PH_DEBUG_PICK"] {
            let xy = pick.split(separator: ",").compactMap { Double($0) }
            after(3.5) { ph_debug_pick(ph_probe_window(), xy[0], xy[1]) }
        }
        switch config.action {
        case "shot": after(config.shotDelay) { [self] in shot() }
        case "startup": whenContentPainted { [self] in after(1.0) { [self] in finish("startup") } }
        case "scroll": whenContentPainted { after(1.0) { ph_probe_scroll(ph_probe_window(), 40, { Harness.exit() }) } }
        case "live": whenContentPainted { [self] in after(1.0) { [self] in live() } }
        case "redraw": after(1.0) { [self] in redraw() }
        case "identity": after(1.0) { [self] in identity() }
        default: break
        }
    }

    /// Polls until the probe has seen the frame with the content laid out.
    private func whenContentPainted(_ body: @escaping @MainActor () -> Void) {
        every(0.02) {
            guard ph_probe_content_frame_done() != 0 else { return true }
            body()
            return false
        }
    }

    private func shot() {
        let window = ph_probe_window()
        // The window's content (no client-side titlebar); run.sh trims it to the card.
        let target = ph_window_child(window) ?? window
        let ok = ph_snapshot_png(target, config.shotPath, 2)
        print("PERF {\"event\":\"shot\",\"path\":\"\(config.shotPath)\",\"ok\":\(ok != 0)}")
        Harness.exit()
    }

    private func finish(_ label: String) {
        ph_probe_report(label)
        Harness.exit()
    }

    /// `liveCards` cards update usage and tokens, plus the clock, `liveHz`
    /// times a second for `duration` seconds.
    private func live() {
        let cards = Array(board.cards.prefix(config.liveCards))
        var tick = 0
        var mutationMS: [Double] = []
        ph_probe_reset()
        let cpuStart = ph_cpu_seconds()
        let start = ph_now_us()
        every(1 / config.liveHz) { [board, config] in
            tick += 1
            ph_probe_mark()
            let begin = ph_now_us()
            board.now = Date()
            for (index, card) in cards.enumerated() {
                let fraction = 0.5 + 0.45 * sin(Double(tick + index) / 7)
                card.cpu = .init(fraction: fraction, label: "CPU \(Int(fraction * 100))%")
                let tokens = 10_000 + tick * 1_234 + index * 97
                card.tokens = .init(compact: Samples.compact(tokens), color: Samples.heatmapHex(tokens), description: "\(tokens) tokens")
            }
            mutationMS.append(Double(ph_now_us() - begin) / 1000)
            let elapsed = Double(ph_now_us() - start) / 1e6
            guard elapsed < config.duration else {
                let cpu = ph_cpu_seconds() - cpuStart
                let sorted = mutationMS.sorted()
                print("PERF {\"event\":\"live_summary\",\"ticks\":\(tick),\"cpu_percent\":\(String(format: "%.1f", 100 * cpu / elapsed)),\"mutation_median_ms\":\(String(format: "%.3f", sorted[sorted.count / 2])),\"mutation_max_ms\":\(String(format: "%.3f", sorted.last ?? 0))}")
                ph_probe_report("live")
                Harness.exit()
                return false
            }
            return true
        }
    }

    /// Mutates the model and checks the GTK widget tree shows each change.
    private func redraw() {
        let window = ph_probe_window()
        let card = board.cards[0]
        var results: [(String, Bool)] = []
        let steps: [(String, () -> Void, () -> Bool)] = [
            ("title change", { card.title = "Redraw check title" }, { ph_count_labels(window, "Redraw check title") > 0 }),
            ("status appears", { card.statusMessage = "Redraw status" }, { ph_count_labels(window, "Redraw status") > 0 }),
            ("status disappears", { card.statusMessage = nil }, { ph_count_labels(window, "Redraw status") == 0 }),
            ("tokens change", { card.tokens = .init(compact: "9.9M", color: "#FF0000", description: "") }, { ph_count_labels(window, "9.9M") > 0 }),
            ("clock ticks", {
                card.isWorking = true
                card.workingSince = Date().timeIntervalSince1970 - 3_725
                card.workedSeconds = 0
                self.board.now = Date()
            }, { ph_count_labels(window, "1h 2m") > 0 }),
            ("card removed", { self.board.cards.removeFirst() }, { ph_count_labels(window, "Redraw check title") == 0 }),
        ]
        var index = 0
        func next() {
            guard index < steps.count else {
                let detail = results.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
                print("PERF {\"event\":\"redraw_check\",\"passed\":\(results.allSatisfy { $0.1 }),\(detail)}")
                Harness.exit()
                return
            }
            let step = steps[index]
            step.1()
            after(0.4) {
                results.append((step.0, step.2()))
                index += 1
                next()
            }
        }
        next()
    }

    /// Local view state must follow the card, not its position: card-00001
    /// starts expanded (see `initiallyExpanded`); cards before it are removed
    /// and inserted. Only even-index cards have a mode pill ("Plan"), and
    /// card-00001 has none, so a "Plan" label showing up means the expanded
    /// state moved to a different card.
    private func identity() {
        let window = ph_probe_window()
        func expandedCards() -> String { "Playhouse=\(ph_count_labels(window, "Playhouse")),Plan=\(ph_count_labels(window, "Plan"))" }
        var results: [(String, String, Bool)] = []
        let before = expandedCards()
        results.append(("initial", before, before == "Playhouse=1,Plan=0"))
        board.cards.removeFirst()
        after(0.5) { [self] in
            let afterRemove = expandedCards()
            results.append(("after removing the first card", afterRemove, afterRemove == "Playhouse=1,Plan=0"))
            board.cards.insert(Samples.board(count: 1)[0].withID("inserted"), at: 0)
            after(0.5) { [self] in
                let afterInsert = expandedCards()
                results.append(("after inserting at the front", afterInsert, afterInsert == "Playhouse=1,Plan=0"))
                board.cards.swapAt(1, 2)
                after(0.5) {
                    let afterSwap = expandedCards()
                    results.append(("after swapping it with its neighbour", afterSwap, afterSwap == "Playhouse=1,Plan=0"))
                    let detail = results.map { "\"\($0.0)\":\"\($0.1)\"" }.joined(separator: ",")
                    print("PERF {\"event\":\"identity_check\",\"passed\":\(results.allSatisfy { $0.2 }),\(detail)}")
                    Harness.exit()
                }
            }
        }
    }

    /// Whether a card's local `expanded` state starts on (PH_EXPANDED, or the identity check's card).
    public static func initiallyExpanded(_ id: String) -> Bool {
        HarnessConfig.current.expanded || (HarnessConfig.current.action == "identity" && id == "card-00001")
    }

    public static func exit() {
        ph_flush()
        Foundation.exit(0)
    }
}

// MARK: GLib timers (the UI libraries run GLib's main loop, not a RunLoop)

private final class TimerBox {
    let body: @MainActor () -> Bool
    init(_ body: @escaping @MainActor () -> Bool) { self.body = body }
}

@MainActor
public func every(_ seconds: Double, _ body: @escaping @MainActor () -> Bool) {
    let box = Unmanaged.passRetained(TimerBox(body)).toOpaque()
    ph_timeout_add(UInt32(max(1, seconds * 1000)), { context in
        let box = Unmanaged<TimerBox>.fromOpaque(context!)
        let keep = MainActor.assumeIsolated { box.takeUnretainedValue().body() }
        if !keep { box.release() }
        return keep ? 1 : 0
    }, box)
}

@MainActor
public func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
    every(seconds) { body(); return false }
}
