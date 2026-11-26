import Adwaita
import CardHarness
import CardModel
import Foundation
import GtkProbe

/// What one card renders, read from the @Observable models inside
/// `ObservationBridge.track` so every read is tracked.
struct CardSnapshot {
    var title: String
    var progress: TaskItemModel.Progress?
    var status: String?
    var blocked: Bool
    var time: String
    var tokens: TaskItemModel.Tokens?
    var cpu: Double?
    var repositories: [TaskItemModel.Repository]
    var mode: String?
    var selected: Bool

    init(_ model: TaskItemModel, _ board: BoardModel) {
        title = model.title
        progress = model.progress
        status = model.statusMessage
        blocked = model.statusIsBlocked
        time = model.isWorking ? model.workingDuration(at: board.now) : model.createdText
        tokens = model.tokens
        cpu = model.cpu?.fraction
        repositories = model.repositories
        mode = model.mode
        selected = board.selectedID == model.id
    }
}

/// The board task card (Playhouse/App/TaskItemView.swift + AtomCard),
/// rebuilt with Adwaita for Swift. Styling is one global GTK stylesheet
/// (AppStyle.css) applied through style classes.
struct TaskCard: View {
    var model: TaskItemModel
    var board: BoardModel
    // Local view state, owned by this view through Adwaita's @State.
    @State private var hovering = false
    @State private var expanded: Bool
    @State private var menuVisible = false

    init(model: TaskItemModel, board: BoardModel) {
        self.model = model
        self.board = board
        _expanded = State(wrappedValue: Harness.initiallyExpanded(model.id))
    }

    var view: Body {
        let card = ObservationBridge.track { CardSnapshot(model, board) }
        Overlay()
            .child {
                VStack(spacing: 10) {
                    titleRow(card)
                    if let progress = card.progress {
                        progressRow(progress)
                    }
                    if let status = card.status {
                        Text(status)
                            .wrap()
                            .maxWidthChars(12)
                            .lines(3)
                            .xalign(0)
                            .style("ph-small")
                            .style(card.blocked ? "ph-red" : "ph-secondary")
                    }
                    timeRow(card)
                    if expanded {
                        expandedSection(card)
                            .transition(.slideDown)
                    }
                }
                .padding(14)
            }
            .overlay {
                // Not wrapped in `if`: every `if` becomes a GtkStack that fills the
                // overlay and swallows clicks meant for the controls below it.
                LevelBar()
                    .value(card.cpu ?? 0)
                    .inverted()
                    .style("ph-meter")
                    .style("ph-hidden", active: card.cpu == nil)
                    .halign(.start)
                    .valign(.fill)
                    .inspectOnAppear { storage in
                        let bar = UnsafeMutableRawPointer(storage.opaquePointer)
                        ph_set_vertical(bar)
                        ph_set_can_target(bar, 0)
                    }
            }
            .style("ph-card")
            .style("ph-selected", active: card.selected)
            .style("ph-hover", active: hovering)
            .onClick {
                board.selectedID = model.id
                board.lastAction = "open \(model.id)"
            }
            // MenuButton actions are registered window-wide by label, so a handler
            // must not capture its card: the last card to update would win. Route
            // through the card that was right-clicked instead.
            .menuPopover(visible: $menuVisible) {
                MenuSection {
                    if model.canMoveToDone {
                        MenuButton("Move to Done") { ContextTarget.activate("done") }
                    }
                    if model.canMoveToReview {
                        MenuButton("Move to Review") { ContextTarget.activate("review") }
                    }
                    MenuButton("Rename…") { ContextTarget.activate("rename") }
                    MenuButton("Token Stats…") { ContextTarget.activate("stats") }
                }
                MenuSection {
                    MenuButton("Delete Task") { ContextTarget.activate("delete") }
                }
            }
            // No hover or right-click API: raw GTK controllers set the local @State.
            .inspectOnAppear { storage in
                let widget = UnsafeMutableRawPointer(storage.opaquePointer)
                RawEvents.attach(to: widget, hover: { hovering = $0 }, secondaryClick: {
                    ContextTarget.set(model: model, board: board)
                    board.selectedID = model.id
                    menuVisible = true
                })
            }
    }

    private func titleRow(_ card: CardSnapshot) -> AnyView {
        // The toggle floats over the title's trailing edge, so revealing it doesn't reflow the title.
        Overlay()
            .child {
                Text(card.title)
                    .wrap()
                    .maxWidthChars(12)
                    .xalign(0)
                    .hexpand()
                    .style("ph-title")
            }
            .overlay {
                if hovering || expanded {
                    Button(icon: .custom(name: expanded ? "pan-up-symbolic" : "pan-down-symbolic")) {
                        expanded.toggle()
                        print("PERF {\"event\":\"expand_toggle\",\"expanded\":\(expanded)}")
                    }
                    .flat()
                    .style("ph-chevron")
                    .halign(.end)
                    .valign(.start)
                }
            }
            .hexpand()
    }

    private func progressRow(_ progress: TaskItemModel.Progress) -> AnyView {
        HStack(spacing: 6) {
            Image()
                .iconName(Palette.icon(progress.symbol))
                .pixelSize(10)
                .style("ph-accent")
                .valign(.start)
                .padding(2, .top)
            VStack(spacing: 2) {
                Text(progress.label).xalign(0).style("ph-small").style("ph-semibold").style("ph-text")
                if let detail = progress.detail {
                    Text(detail).wrap().maxWidthChars(12).lines(2).xalign(0).style("ph-small").style("ph-secondary")
                }
            }
            .hexpand()
        }
    }

    private func timeRow(_ card: CardSnapshot) -> AnyView {
        HStack(spacing: 6) {
            Image().iconName("document-open-recent-symbolic").pixelSize(10).style("ph-tertiary")
            Text(card.time).style("ph-small").style("ph-tertiary")
            if let tokens = card.tokens {
                // The hover capsule is pure CSS (:hover); the color is per card,
                // so it goes through Pango markup rather than a stylesheet.
                Text("<span foreground=\"\(tokens.color)\">\(tokens.compact)</span>")
                    .useMarkup()
                    .style("ph-tokens")
                    .onClick { board.lastAction = "token stats \(model.id)" }
            }
        }
    }

    private func expandedSection(_ card: CardSnapshot) -> AnyView {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
              ForEach(card.repositories, id: \.name) { repository in
                HStack(spacing: 4) {
                    Text(repository.name).style("ph-small").style("ph-medium").style("ph-text")
                    if let pullRequest = repository.pullRequest {
                        Text(pullRequest).style("ph-small").style("ph-semibold").style("ph-green")
                    }
                }
                .style("ph-chip")
              }
              .orientation(.horizontal)
            }
            .hexpand()
            if let mode = card.mode {
                Text(mode).style("ph-small").style("ph-semibold").style("ph-mode")
            }
        }
    }
}

/// The card whose context menu is open; see the comment on `.menuPopover`.
enum ContextTarget {
    private static weak var model: TaskItemModel?
    private static weak var board: BoardModel?

    static func set(model: TaskItemModel, board: BoardModel) {
        self.model = model
        self.board = board
    }

    static func activate(_ item: String) {
        guard let model, let board else { return }
        board.lastAction = "menu \(item) \(model.id)"
        print("PERF {\"event\":\"menu\",\"item\":\"\(item)\",\"card\":\"\(model.id)\"}")
        ph_flush()
    }
}

/// Raw GTK hover and right-click controllers (GtkProbe) calling Swift closures.
enum RawEvents {
    final class Handlers {
        let hover: (Bool) -> Void
        let secondaryClick: () -> Void
        init(hover: @escaping (Bool) -> Void, secondaryClick: @escaping () -> Void) {
            self.hover = hover
            self.secondaryClick = secondaryClick
        }
    }

    static func attach(to widget: UnsafeMutableRawPointer?, hover: @escaping (Bool) -> Void, secondaryClick: @escaping () -> Void) {
        let context = Unmanaged.passRetained(Handlers(hover: hover, secondaryClick: secondaryClick)).toOpaque()
        ph_on_hover(widget, { context, entered in
            MainActor.assumeIsolated { Unmanaged<Handlers>.fromOpaque(context!).takeUnretainedValue().hover(entered != 0) }
        }, context)
        ph_on_secondary_click(widget, { context, _, _ in
            MainActor.assumeIsolated { Unmanaged<Handlers>.fromOpaque(context!).takeUnretainedValue().secondaryClick() }
        }, context)
    }
}

enum Palette {
    /// SF Symbol → Adwaita symbolic icon.
    static func icon(_ symbol: String) -> String {
        switch symbol {
        case "hammer": "applications-engineering-symbolic"
        case "checkmark.seal": "emblem-ok-symbolic"
        case "eye": "view-reveal-symbolic"
        default: "starred-symbolic"
        }
    }
}
