import CardHarness
import CardModel
import Foundation
import GtkBackend
import GtkProbe
import SwiftCrossUI

/// One card (screenshots) or a scrollable board of PH_CARDS cards (benchmarks),
/// on the board's #1E1E1E background, 264pt cards with a 12pt gutter.
struct SCUICardApp: App {
    @State var board = SCUICardApp.harness.board

    @MainActor static var harness: Harness!

    var body: some Scene {
        WindowGroup("SwiftCrossUI card") {
            content
                .background(Palette.window)
                .preferredColorScheme(.dark)
                // Global CSS: the app font and the screenshot target's class.
                .inspectWindow { _ in AppStyle.install() }
        }
        .defaultSize(width: 288, height: SCUICardApp.harness.config.scene == "board" ? 900 : 260)
    }

    @ViewBuilder
    var content: some View {
        if SCUICardApp.harness.config.scene == "board" {
            ScrollView {
                boardStack
                    .padding(12)
            }
        } else {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(board.cards) { card in
                        TaskCard(model: card, board: board)
                    }
                }
                .padding(12)
                .background(Palette.window)
                .inspect(.onCreate) { widget in ph_add_css_class(UnsafeMutableRawPointer(widget.widgetPointer), "ph-shot") }
                Spacer(minLength: 0)
            }
        }
    }
}

extension SCUICardApp {
    /// The board's column. PH_VARIANT=lazy (fork builds): a LazyVStack, so only
    /// cards near the viewport get views and widgets.
    @ViewBuilder
    var boardStack: some View {
        #if PH_SCUI_FORK
            if HarnessDefaults.variant.contains("lazy") {
                LazyVStack(spacing: 10, estimatedRowHeight: 130) {
                    ForEach(board.cards) { card in
                        TaskCard(model: card, board: board)
                    }
                }
            } else {
                eagerStack
            }
        #else
            eagerStack
        #endif
    }

    var eagerStack: some View {
        VStack(spacing: 10) {
            ForEach(board.cards) { card in
                TaskCard(model: card, board: board)
            }
        }
    }
}

enum AppStyle {
    @MainActor static func install() {
        ph_prefer_dark()
        ph_load_css("""
        window { background-color: \(Theme.window); }
        """)
    }
}

#if PH_SCUI_FORK
// Fork diagnostics: PH_LAYOUT_STATS=1 prints layout work counters on exit.
if ProcessInfo.processInfo.environment["PH_LAYOUT_STATS"] != nil {
    LayoutStats.byTypeEnabled = ProcessInfo.processInfo.environment["PH_LAYOUT_STATS"] == "types"
    LayoutStats.traceType = TaskCard.self
    atexit { print("PERF {\"event\":\"layout_stats\",\"summary\":\"\(LayoutStats.summary)\"}") }
}
#endif

MainActor.assumeIsolated {
    let harness = Harness()
    SCUICardApp.harness = harness
    harness.install()
    // PH_METER_DEMO=1: the first card's CPU jumps 0.2 → 0.95 at 3 s and back at
    // 6 s, so screen captures can follow the meter animation.
    if ProcessInfo.processInfo.environment["PH_METER_DEMO"] != nil, let card = harness.board.cards.first {
        card.cpu = .init(fraction: 0.2, label: "20%")
        after(3.0) { card.cpu = .init(fraction: 0.95, label: "95%") }
        after(6.0) { card.cpu = .init(fraction: 0.2, label: "20%") }
    }
}
SCUICardApp.main()
