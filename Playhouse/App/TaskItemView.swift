import OSLog
import QuartzCore
import SwiftUI

extension TaskItemModel {
    init(
        task: BoardTask,
        cpuPercent: Double?,
        cpuUsageColorMax: Int,
        tokenUsageColorMax: Int,
        canMoveToDone: Bool,
        canMoveToReview: Bool
    ) {
        let taskID = task.id.uuidString
        id = taskID
        title = task.title
        titleSpinner = task.title == "Generating title…"
        if let label = task.progressLabel, !label.isEmpty {
            progress = Progress(
                label: label,
                detail: task.progressDetail.flatMap { $0.isEmpty ? nil : $0 },
                symbol: TaskProgressType(rawValue: task.progressTypeRawValue ?? "")?.symbol ?? "sparkle"
            )
        }
        if task.scheduleKind == .once, let scheduledAt = task.scheduledAt {
            schedule = ScheduleFormatting.relativeTime(scheduledAt)
        }
        statusMessage = task.statusMessage.flatMap { $0.isEmpty ? nil : $0 }
        statusIsBlocked = task.status == .blocked
        isWorking = task.status == .inProgress
        workingSince = task.inProgressStartedAt?.timeIntervalSince1970
        workedSeconds = task.totalInProgressSeconds
        createdText = task.createdAt.formatted(date: .abbreviated, time: .omitted)
        // A zero counter says nothing yet, so it stays hidden until the task has sent tokens.
        if task.counterTokens > 0 {
            let description = task.hasCallUsage
                ? "\(TokenUsageHeatmap.compact(task.totalSentTokens)) tokens sent · \(task.totalCalls) \(task.totalCalls == 1 ? "call" : "calls") · \(TokenUsageHeatmap.compact(task.finalTranscriptTokens)) final transcript"
                : TokenUsageHeatmap.label(totalTokens: task.totalTokens)
            tokens = Tokens(
                compact: TokenUsageHeatmap.compact(task.counterTokens),
                color: AtomColor.hex(TokenUsageHeatmap.color(totalTokens: task.counterTokens, max: tokenUsageColorMax)),
                description: description
            )
        }
        cpu = cpuPercent.map { CPU(fraction: CPUUsageHeatmap.fraction(percent: $0, max: cpuUsageColorMax), label: CPUUsageHeatmap.label(percent: $0)) }
        self.canMoveToDone = canMoveToDone
        self.canMoveToReview = canMoveToReview

        hasPluginRow = task.status != .backlog && !task.repositoryWorktrees.isEmpty
    }
}

/// What a card's controls do. Menu ids: done, review, rename, stats, delete.
struct TaskItemActions {
    var open: () -> Void = {}
    var menu: (String) -> Void = { _ in }
    var showTokenStats: () -> Void = {}
}

/// The board's task item, composed only of plugin atoms (Plugins/Atoms), so a
/// plugin building the same item from the same atoms looks identical.
/// Rows, top to bottom: the title, the live progress report, the schedule,
/// the status message, the time with the token counter, then the row of
/// task card plugins (`PluginPlacement.taskItem`) on the right, among them
/// the built-in pull request controls and mode pill.
struct TaskItemView: View {
    let model: TaskItemModel
    var actions = TaskItemActions()
    /// The bottom row's plugins; the board passes its `TaskItemPluginRow`.
    var pluginRow: AnyView?

    private var id: String { model.id }

    var body: some View {
        AtomCard(props: cardProps, common: AtomCommon(testID: "task-card-\(id)", label: model.title, hint: "Open task", fillWidth: true, padding: 14), onPress: actions.open, onMenu: actions.menu) {
            AtomStack(props: StackProps(axis: "v", spacing: 10, align: "leading")) {
                // Every row but the token counter and the plugin row
                // lets clicks through to the card.
                AtomStack(props: StackProps(axis: "h", spacing: 6), common: AtomCommon(testID: "task-title-\(id)", passThrough: true)) {
                    if model.titleSpinner { AtomSpinner() }
                    AtomText(props: TextProps(text: model.title, size: 13, weight: "semibold", color: "text", tracking: 0.35, lineSpacing: 2, wrap: true))
                }

                if let progress = model.progress {
                    AtomStack(
                        props: StackProps(axis: "h", spacing: 6, align: "top", group: true),
                        common: AtomCommon(
                            testID: "task-progress-report-\(id)",
                            label: [progress.label, progress.detail].compactMap { $0 }.joined(separator: ", "),
                            value: "Progress icon: \(progress.symbol)",
                            fillWidth: true,
                            passThrough: true
                        )
                    ) {
                        AtomIcon(props: IconProps(name: progress.symbol, size: 10, weight: "semibold", color: "accent"), common: AtomCommon(testID: "task-progress-icon-\(id)", label: progress.symbol))
                        AtomStack(props: StackProps(axis: "v", spacing: 2, align: "leading")) {
                            AtomText(props: TextProps(text: progress.label, size: 10, weight: "semibold", color: "text"), common: AtomCommon(testID: "task-progress-label-\(id)"))
                            if let detail = progress.detail {
                                AtomText(props: TextProps(text: detail, size: 10, color: "secondary", lineLimit: 2), common: AtomCommon(testID: "task-progress-detail-\(id)"))
                            }
                        }
                    }
                }

                if let schedule = model.schedule {
                    AtomLabel(props: LabelProps(text: schedule, icon: "clock", size: 10, weight: "medium", color: "accent"), common: AtomCommon(testID: "task-schedule-badge-\(id)", passThrough: true))
                }

                if let statusMessage = model.statusMessage {
                    AtomText(
                        props: TextProps(text: statusMessage, size: 10, color: model.statusIsBlocked ? "red" : "secondary", lineLimit: 3),
                        common: AtomCommon(testID: "task-status-message-\(id)", fillWidth: true, passThrough: true)
                    )
                }

                timeRow

                if let pluginRow {
                    pluginRow
                }
            }
        }
    }

    private var cardProps: CardProps { TaskItemTree.cardProps(model) }

    private var timeRow: some View {
        // One row of clock, time and counter, as the card had before the atoms.
        AtomStack(props: StackProps(axis: "h", spacing: 6)) {
            AtomIcon(props: IconProps(name: "clock", size: 10, color: "tertiary"), common: AtomCommon(passThrough: true))
            if model.isWorking {
                // The clock only drives the string; the view is the Text atom.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    AtomText(props: TextProps(text: model.workingDuration(at: context.date), size: 10, color: "tertiary"), common: AtomCommon(testID: "task-working-duration-\(id)", passThrough: true))
                }
            } else {
                AtomText(props: TextProps(text: model.createdText, size: 10, color: "tertiary"), common: AtomCommon(testID: "task-created-time-\(id)", passThrough: true))
            }
            if let tokens = model.tokens {
                TokenCounterButton(tokens: tokens, testID: "task-token-usage-counter-\(id)", action: actions.showTokenStats)
            }
        }
    }
}

/// Which view draws the board's task items, picked once per launch by
/// `PLAYHOUSE_TASK_ITEM_RENDERER`: the native `TaskItemView` (the default),
/// or, for the atom-tree spike (docs/atom-tree-performance.md), the same card
/// as an atom tree (`tree`, typed props) or as plugin-style ops (`tree-dynamic`,
/// dictionary props decoded once per op) rendered through `AtomRegistry`.
enum TaskItemRenderer: String {
    case native
    case tree
    case treeDynamic = "tree-dynamic"

    static let current = TaskItemRenderer(rawValue: ProcessInfo.processInfo.environment["PLAYHOUSE_TASK_ITEM_RENDERER"] ?? "") ?? .native
}

/// Keeps a task item's atom tree in step with its model and sends the tree's
/// events to the card's actions.
@MainActor
@Observable
final class TaskItemTreeHost {
    private let typed: TypedAtomTree?
    private let dynamic: DynamicAtomTree?
    @ObservationIgnored var actions = TaskItemActions()
    @ObservationIgnored private(set) var model: TaskItemModel
    private(set) var root: PluginNode?

    init(model: TaskItemModel, dynamicProps: Bool, now: Date = .now) {
        self.model = model
        typed = dynamicProps ? nil : TypedAtomTree()
        dynamic = dynamicProps ? DynamicAtomTree() : nil
        typed?.onEvent = { [weak self] id, event, value in self?.handle(id, event, value) }
        dynamic?.onEvent = { [weak self] id, event, value in self?.handle(id, event, value) }
        apply(now: now)
    }

    var events: any AtomEventHandler { typed?.handlers ?? dynamic!.handlers }

    func update(_ model: TaskItemModel, now: Date = .now) {
        guard model != self.model else { return }
        self.model = model
        apply(now: now)
    }

    /// Re-renders the working time.
    func tick(now: Date = .now) { apply(now: now) }

    private func apply(now: Date) {
        #if PLAYHOUSE_ATOM_BENCHMARK
        let started = CACurrentMediaTime()
        let state = Self.signposter.beginInterval("build spec")
        #endif
        let spec = TaskItemTree.spec(model: model, now: now)
        #if PLAYHOUSE_ATOM_BENCHMARK
        Self.signposter.endInterval("build spec", state)
        let built = CACurrentMediaTime()
        let reconcile = Self.signposter.beginInterval("reconcile")
        defer {
            Self.signposter.endInterval("reconcile", reconcile)
            Self.phaseTimes["specMs", default: 0] += (built - started) * 1000
            Self.phaseTimes["reconcileMs", default: 0] += (CACurrentMediaTime() - built) * 1000
            Self.phaseTimes["applies", default: 0] += 1
        }
        #endif
        if let typed {
            typed.apply(spec)
            if root !== typed.root { root = typed.root }
        } else if let dynamic {
            do { try dynamic.apply(spec) } catch { assertionFailure("Task item ops: \(error)") }
            if root !== dynamic.root { root = dynamic.root }
        }
    }

    #if PLAYHOUSE_ATOM_BENCHMARK
    static let signposter = OSSignposter(subsystem: "Playhouse", category: "AtomTree")
    /// Time spent building specs and reconciling trees, for `TaskItemBenchmark`.
    static var phaseTimes: [String: Double] = [:]
    #endif

    private func handle(_ id: Int, _ event: String, _ value: PluginValue?) {
        switch (id, event) {
        case (TaskItemTree.ID.card, "onPress"): actions.open()
        case (TaskItemTree.ID.card, "onMenu"): if let item = value?.string { actions.menu(item) }
        case (TaskItemTree.ID.tokenButton, "onPress"): actions.showTokenStats()
        default: break
        }
    }
}

/// `TaskItemView`'s card drawn from its atom tree (`TaskItemTree`) through
/// `AtomRegistry`, for the atom-tree spike. It looks and acts the same.
struct TaskItemTreeView: View {
    let model: TaskItemModel
    var actions = TaskItemActions()
    var pluginRow: AnyView?
    var dynamicProps = false
    /// Holds the host, built on the first render: a `State`'s initial value is
    /// evaluated on every init of the view, and a host builds its whole tree.
    private final class HostBox {
        var host: TaskItemTreeHost?
    }
    @State private var box = HostBox()

    var body: some View {
        let host = box.host ?? {
            let host = TaskItemTreeHost(model: model, dynamicProps: dynamicProps)
            box.host = host
            return host
        }()
        // The latest closures, which capture the board's current task.
        let _ = { host.actions = actions }()
        Group {
            if let root = host.root {
                PluginNodeView(node: root, events: host.events)
            }
        }
        .environment(\.atomSlots, AtomSlots(views: pluginRow.map { [TaskItemTree.pluginRowSlot: $0] } ?? [:]))
        // Tells a tree-drawn card from a native one, which has the same identifiers inside.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-item-tree-\(model.id)")
        .onChange(of: model) { _, model in host.update(model) }
        .task(id: model.isWorking) {
            guard model.isWorking else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                host.tick()
            }
        }
    }
}
