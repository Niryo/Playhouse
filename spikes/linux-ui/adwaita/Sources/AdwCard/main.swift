import Adwaita
import CAdw
import CardHarness
import CardModel
import Foundation
import GtkProbe

/// One card (screenshots) or a scrollable board of PH_CARDS cards (benchmarks),
/// on the board's #1E1E1E background, 264pt cards with a 12pt gutter.
struct AdwCardApp: App {
    static var harness: Harness!

    var app = AdwaitaApp(id: "dev.playhouse.AdwCard")

    var scene: Scene {
        Window(id: "main") { _ in
            BoardView(board: AdwCardApp.harness.board, scene: AdwCardApp.harness.config.scene)
        }
        .defaultSize(width: 288, height: AdwCardApp.harness.config.scene == "board" ? 900 : 260)
        .title("Adwaita card")
    }
}

struct BoardView: View {
    var board: BoardModel
    var scene: String
    /// Bumped by ObservationBridge when a tracked @Observable changes.
    @State private var revision = 0

    var view: Body {
        let cards = ObservationBridge.track { board.cards }
        let _ = setUpBridge()
        if scene == "board" {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(cards, id: \.id) { card in
                        TaskCard(model: card, board: board)
                            .frame(maxWidth: Int(Theme.cardWidth))
                    }
                }
                .padding(12)
            }
            .vexpand()
            .style("ph-board")
        } else {
            VStack {
                VStack {
                    ForEach(cards, id: \.id) { card in
                        TaskCard(model: card, board: board)
                    }
                }
                .style("ph-shot")
                // 264 pt card + 12 pt gutter on each side; wrapped labels keep a small
                // natural width (maxWidthChars) so the column decides the width.
                .frame(minWidth: Int(Theme.cardWidth) + 24)
                .halign(.start)
            }
            .valign(.start)
            .style("ph-board")
        }
    }

    private func setUpBridge() {
        let revision = $revision
        ObservationBridge.refresh = { revision.wrappedValue += 1 }
    }
}

enum AppStyle {
    static func install() {
        // ADW_COLOR_SCHEME_FORCE_DARK
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), AdwColorScheme(rawValue: 4)!)
        ph_load_css(css)
    }

    static let css = """
    window, .ph-board { background-color: \(Theme.window); }
    .ph-shot { padding: 12px; background-color: \(Theme.window); }
    .ph-card {
        background-color: \(Theme.cardFill);
        border: 1px solid \(Theme.cardBorder);
        border-radius: \(Int(Theme.cornerRadius))px;
        box-shadow: 0 2px 5px rgba(0,0,0,0.035);
        transition: border-color 150ms ease-out;
    }
    .ph-card.ph-hover { border-color: rgba(255,255,255,0.16); }
    .ph-card.ph-selected { border: 2px solid \(Theme.accent); }
    .ph-title { font-size: 13px; font-weight: 600; letter-spacing: 0.35px; color: \(Theme.text); }
    .ph-small { font-size: 10px; }
    .ph-medium { font-weight: 500; }
    .ph-semibold { font-weight: 600; }
    .ph-text { color: \(Theme.text); }
    .ph-secondary { color: \(Theme.secondary); }
    .ph-tertiary { color: \(Theme.tertiary); }
    .ph-accent { color: \(Theme.accent); }
    .ph-red { color: \(Theme.red); }
    .ph-green { color: #32D74B; }
    .ph-tokens {
        font-family: "\(Theme.monoFamily)"; font-size: 10px; font-weight: 500;
        padding: 0 4px; border-radius: 999px; transition: background-color 140ms ease-out;
    }
    .ph-tokens:hover { background-color: alpha(\(Theme.accent), 0.14); }
    .ph-chevron { min-width: 16px; min-height: 16px; padding: 0; margin: 0; color: \(Theme.secondary); }
    .ph-chevron image { -gtk-icon-size: 12px; }
    .ph-chip { background-color: rgba(255,255,255,0.07); border-radius: 9px; padding: 3px 7px; }
    .ph-mode { color: \(Theme.accent); background-color: alpha(\(Theme.accent), 0.16); border-radius: 9px; padding: 3px 8px; }
    levelbar.ph-meter { margin: 1px 0; }
    /* GtkLevelBar draws the empty block over the whole trough and the filled
       block on top, sized to the value. CSS can't size a gradient to the
       trough from inside the filled block, so the fill runs green → red over
       its own height (the native fill reveals one full-height gradient). */
    .ph-hidden { opacity: 0; }
    levelbar.ph-meter trough { min-width: 4px; padding: 0; border: none; border-radius: 2px; background: none; }
    levelbar.ph-meter block { min-width: 4px; border: none; border-radius: 2px; }
    levelbar.ph-meter block.empty {
        background-image: linear-gradient(to top, alpha(\(Theme.meterGreen), 0.15), alpha(\(Theme.meterRed), 0.15));
        background-color: transparent;
    }
    levelbar.ph-meter block.filled {
        background-image: linear-gradient(to top, \(Theme.meterGreen), \(Theme.meterRed));
        background-color: transparent;
    }
    """
}

let harness = Harness()
AdwCardApp.harness = harness
harness.install()
// The stylesheet needs a display: install it once GTK has started.
after(0) { AppStyle.install() }
AdwCardApp.main()
