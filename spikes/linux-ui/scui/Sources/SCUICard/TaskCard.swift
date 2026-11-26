import CardHarness
import CardModel
import Foundation
import Gtk
import Observation
import GtkBackend
import GtkProbe
import SwiftCrossUI

// Gtk and SwiftCrossUI both export Color; CardModel and SwiftCrossUI both export MenuItem.
typealias Color = SwiftCrossUI.Color
typealias CardMenuItem = CardModel.MenuItem

/// Local, per-card UI state. It lives in the view (via @State), never in the
/// app model, and SwiftCrossUI observes it like any @Observable.
@Observable
@MainActor
final class CardUIState {
    var hovering = false
    var expanded: Bool
    var tokenHover = false
    init(expanded: Bool) { self.expanded = expanded }
}

/// The board task card (Playhouse/App/TaskItemView.swift + AtomCard),
/// rebuilt with SwiftCrossUI. Rows top to bottom: title, progress report,
/// status message, time + token counter; then the spike-only expanded
/// section (repository chips and the mode pill), see REPORT.md.
struct TaskCard: View {
    let model: TaskItemModel
    let board: BoardModel
    @State var ui: CardUIState

    init(model: TaskItemModel, board: BoardModel) {
        self.model = model
        self.board = board
        // Only the first value is kept: SwiftCrossUI ties the state to the view's identity.
        _ui = State(wrappedValue: CardUIState(expanded: Harness.initiallyExpanded(model.id)))
    }

    var isSelected: Bool { board.selectedID == model.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            if let progress = model.progress {
                progressRow(progress)
            }
            if let status = model.statusMessage {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundColor(model.statusIsBlocked ? Palette.red : Palette.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
            timeRow
            if ui.expanded {
                expandedSection
            }
        }
        .padding(14)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
        .overlay(alignment: .leading) { meter }
        .onHover { hovering in ui.hovering = hovering }
        .onTapGesture { board.selectedID = model.id; board.lastAction = "open \(model.id)" }
        // No context-menu API: drop to GTK for a right-click gesture and a GtkPopoverMenu.
        .inspect(.onCreate) { widget in
            ContextMenu.attach(to: UnsafeMutableRawPointer(widget.widgetPointer), model: model, board: board)
            // Clip the expanding section to the (animating) card bounds.
            ph_set_overflow_hidden(UnsafeMutableRawPointer(widget.widgetPointer))
        }
    }

    private var titleRow: some View {
        Text(model.title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Palette.text)
            .multilineTextAlignment(.leading)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if ui.hovering || ui.expanded {
                    // The expand toggle shows on hover, like a reveal-on-hover control.
                    Icon.system(.custom(ui.expanded ? "pan-up-symbolic" : "pan-down-symbolic"))
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                        .padding(.top, 2)
                        .onTapGesture { toggleExpanded() }
                }
            }
    }

    /// Fork build: the card springs open/closed (the fork's withAnimation).
    private func toggleExpanded() {
        #if PH_SCUI_FORK
            if !HarnessDefaults.variant.contains("noanim") {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { ui.expanded.toggle() }
                return
            }
        #endif
        ui.expanded.toggle()
    }

    private func progressRow(_ progress: TaskItemModel.Progress) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Icon.system(.custom(Palette.icon(progress.symbol)))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Palette.text)
                if let detail = progress.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(Palette.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
            }
        }
    }

    /// PH_VARIANT=granular: the live parts (clock, token counter, meter) are
    /// their own views, so a tick re-evaluates only them (needs the fork's
    /// body-scoped observation; upstream, every ancestor observes them).
    static let granular = HarnessDefaults.variant.contains("granular")

    @ViewBuilder
    private var timeRow: some View {
        if Self.granular {
            HStack(spacing: 6) {
                Icon.system(.custom("document-open-recent-symbolic"))
                    .font(.system(size: 10))
                    .foregroundColor(Palette.tertiary)
                ElapsedTime(model: model, board: board)
                TokenCounter(model: model, board: board, ui: ui)
            }
        } else {
            plainTimeRow
        }
    }

    private var plainTimeRow: some View {
        HStack(spacing: 6) {
            Icon.system(.custom("document-open-recent-symbolic"))
                .font(.system(size: 10))
                .foregroundColor(Palette.tertiary)
            // The clock lives in the board model, so only working cards re-read it.
            Text(model.isWorking ? model.workingDuration(at: board.now) : model.createdText)
                .font(.system(size: 10))
                .foregroundColor(Palette.tertiary)
            if let tokens = model.tokens {
                Text(tokens.compact)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Palette.color(tokens.color))
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(ui.tokenHover ? Palette.accent.opacity(0.14) : Color.clear)
                    )
                    .onHover { ui.tokenHover = $0 }
                    .onTapGesture { board.lastAction = "token stats \(model.id)" }
            }
        }
    }

    private var expandedSection: some View {
        HStack(spacing: 5) {
            ForEach(model.repositories) { repository in
                Chip(repository: repository)
            }
            Spacer(minLength: 0)
            if let mode = model.mode {
                Text(mode)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Palette.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.accent.opacity(0.16)))
            }
        }
    }

    /// AtomCard's surface: rounded 12, window fill, 7% border (accent when selected, brighter on hover).
    private var cardSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Palette.cardFill)
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSelected ? Palette.accent : Color(white: 1, opacity: ui.hovering ? 0.16 : 0.07),
                    style: StrokeStyle(width: isSelected ? 2 : 1)
                )
        }
    }

    /// The CPU meter on the leading edge: the heatmap gradient at 15% for the
    /// track, then filled from the bottom to `fraction`.
    @ViewBuilder
    private var meter: some View {
        if Self.granular {
            CPUMeter(model: model)
        } else {
            CPUMeter.content(model.cpu)
        }
    }
}

/// The time label: elapsed clock while working, else the created date.
struct ElapsedTime: View {
    let model: TaskItemModel
    let board: BoardModel

    var body: some View {
        Text(model.isWorking ? model.workingDuration(at: board.now) : model.createdText)
            .font(.system(size: 10))
            .foregroundColor(Palette.tertiary)
    }
}

/// The token counter with its hover capsule.
struct TokenCounter: View {
    let model: TaskItemModel
    let board: BoardModel
    let ui: CardUIState

    var body: some View {
        if let tokens = model.tokens {
            Text(tokens.compact)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Palette.color(tokens.color))
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(ui.tokenHover ? Palette.accent.opacity(0.14) : Color.clear)
                )
                .onHover { ui.tokenHover = $0 }
                .onTapGesture { board.lastAction = "token stats \(model.id)" }
        }
    }
}

/// The CPU meter on the leading edge (see TaskCard.meter).
struct CPUMeter: View {
    let model: TaskItemModel

    var body: some View {
        Self.content(model.cpu)
    }

    static func content(_ cpu: TaskItemModel.CPU?) -> some View {
        #if PH_SCUI_FORK
            // Like the native meter: easeInOut 1.2 s whenever the fraction changes.
            meter(cpu).animation(
                HarnessDefaults.variant.contains("noanim") ? nil : .easeInOut(duration: 1.2),
                value: cpu?.fraction
            )
        #else
            meter(cpu)
        #endif
    }

    @ViewBuilder
    static func meter(_ cpu: TaskItemModel.CPU?) -> some View {
        if let cpu, !HarnessDefaults.variant.contains("nometer") {
            GeometryReader { proxy in
                let height = proxy.size.height - 2
                let filled = height * min(1, max(0, cpu.fraction))
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [Palette.meterGreen, Palette.meterRed], startPoint: .bottom, endPoint: .top)
                        .opacity(0.15)
                    // No mask(): draw the visible slice of the same gradient instead.
                    LinearGradient(
                        colors: [Palette.meterGreen, Palette.meterMix(cpu.fraction)],
                        startPoint: .bottom, endPoint: .top
                    )
                    .frame(height: filled)
                }
                .frame(width: 4, height: height)
                .cornerRadius(2)
                .padding(.top, 1)
            }
            .frame(width: 4)
        }
    }
}

/// A repository chip: branch name with its pull request badge.
struct Chip: View {
    let repository: TaskItemModel.Repository

    var body: some View {
        HStack(spacing: 4) {
            Text(repository.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Palette.text)
            if let pullRequest = repository.pullRequest {
                Text(pullRequest)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Palette.green)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 1, opacity: 0.07)))
    }
}

enum HarnessDefaults {
    /// Profiling switches (PH_VARIANT), e.g. "nometer" drops the GeometryReader meter.
    nonisolated(unsafe) static var variant = ProcessInfo.processInfo.environment["PH_VARIANT"] ?? ""
}

enum Palette {
    static let text = color(Theme.text)
    static let secondary = Color(white: 1, opacity: 0.55)
    static let tertiary = Color(white: 1, opacity: 0.25)
    static let accent = color(Theme.accent)
    static let red = color(Theme.red)
    static let green = color("#32D74B")
    static let cardFill = color(Theme.cardFill)
    static let window = color(Theme.window)
    static let meterGreen = color(Theme.meterGreen)
    static let meterRed = color(Theme.meterRed)

    static func color(_ hex: String) -> Color {
        let (r, g, b) = Theme.components(hex)
        return Color(red: r, green: g, blue: b)
    }

    /// The gradient's color at `fraction` of its height.
    static func meterMix(_ fraction: Double) -> Color {
        let a = Theme.components(Theme.meterGreen), b = Theme.components(Theme.meterRed)
        let f = min(1, max(0, fraction))
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }

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

/// The card's right-click menu through raw GTK (GtkGestureClick + GtkPopoverMenu).
@MainActor
enum ContextMenu {
    final class Context {
        let model: TaskItemModel
        let board: BoardModel
        let anchor: UnsafeMutableRawPointer
        var menu: UnsafeMutableRawPointer?
        var items: [CardMenuItem] = []
        init(model: TaskItemModel, board: BoardModel, anchor: UnsafeMutableRawPointer) {
            self.model = model
            self.board = board
            self.anchor = anchor
        }
    }

    static func attach(to widget: UnsafeMutableRawPointer, model: TaskItemModel, board: BoardModel) {
        let context = Unmanaged.passRetained(Context(model: model, board: board, anchor: widget)).toOpaque()
        ph_on_secondary_click(widget, { context, x, y in
            MainActor.assumeIsolated { ContextMenu.show(context!, x: x, y: y) }
        }, context)
    }

    private static func show(_ context: UnsafeMutableRawPointer, x: Double, y: Double) {
        let box = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
        // Built on first use from the model's items, as AtomCard's .contextMenu reads props.menu.
        if box.menu == nil {
            box.items = box.model.menu
            let titles = box.items.map { strdup($0.title) }
            defer { titles.forEach { free($0) } }
            let constTitles = titles.map { UnsafePointer<CChar>($0) }
            let destructive = box.items.map { Int32($0.destructive ? 1 : 0) }
            box.menu = ph_context_menu_new(box.anchor, constTitles, destructive, Int32(box.items.count), { context, index in
                MainActor.assumeIsolated {
                    let box = Unmanaged<Context>.fromOpaque(context!).takeUnretainedValue()
                    box.board.lastAction = "menu \(box.items[Int(index)].id)"
                    print("PERF {\"event\":\"menu\",\"item\":\"\(box.items[Int(index)].id)\"}")
                    ph_flush()
                }
            }, context)
        }
        box.board.selectedID = box.model.id
        ph_context_menu_popup(box.menu, x, y)
    }
}
