import Foundation

/// The card data every render uses. `reference` is the Plugin Catalog's
/// sample task (Playhouse/Resources/PluginRuntime/catalog/sample-task.json),
/// the same data the native macOS reference renders.
@MainActor
public enum Samples {
    public static let repositories: [TaskItemModel.Repository] = [
        .init(name: "Playhouse", branch: "react-renderer", pullRequest: "#412", pullRequestState: "open"),
        .init(name: "plugin-sdk", branch: "main", pullRequest: nil, pullRequestState: "none"),
    ]

    public static func reference() -> TaskItemModel {
        TaskItemModel(
            id: "C0FFEE00-0000-4000-8000-000000000001",
            title: "Add a React renderer for plugins",
            progress: .init(label: "Building", detail: "Compiling the atom registry", symbol: "hammer"),
            statusMessage: "Waiting on CI checks",
            createdText: "Nov 8, 2026",
            tokens: .init(compact: "1.2M", color: "#C9A02E", description: "1.2M tokens sent · 14 calls · 312K final transcript"),
            cpu: .init(fraction: 0.35, label: "CPU 35%"),
            repositories: repositories,
            mode: "Plan",
            canMoveToDone: true
        )
    }

    /// The reference card while its task runs, so the time row is the live clock.
    public static func working(now: Date = Date()) -> TaskItemModel {
        let card = reference()
        card.isWorking = true
        card.workingSince = now.timeIntervalSince1970 - 754
        card.workedSeconds = 3_600
        return card
    }

    static let titles = [
        "Add a React renderer for plugins", "Fix flaky board drag test", "Speed up atom-tree rendering",
        "Collapse tool calls to one line", "Copy full message button", "Port the task card to GTK",
        "Investigate CPU spike in daemon", "Rename worktree branches on retitle", "Nightly tests improver round",
    ]
    static let progress: [TaskItemModel.Progress?] = [
        .init(label: "Building", detail: "Compiling the atom registry", symbol: "hammer"),
        .init(label: "Testing", detail: "CLI/XPC 3/8: task progress persistence", symbol: "checkmark.seal"),
        nil,
        .init(label: "Reviewing", detail: nil, symbol: "eye"),
    ]

    /// `count` varied cards for the board benchmarks; deterministic.
    public static func board(count: Int, now: Date = Date()) -> [TaskItemModel] {
        (0..<count).map { index in
            let tokens = (index * 7_919) % 2_400_000
            return TaskItemModel(
                id: String(format: "card-%05d", index),
                title: "\(titles[index % titles.count]) #\(index + 1)",
                progress: progress[index % progress.count],
                statusMessage: index % 5 == 0 ? (index % 10 == 0 ? "Blocked: 2 checks failing" : "Waiting on CI checks") : nil,
                statusIsBlocked: index % 10 == 0,
                isWorking: index % 3 == 0,
                workingSince: now.timeIntervalSince1970 - Double(30 + index * 17),
                workedSeconds: index % 2 == 0 ? Double(index * 60) : 0,
                createdText: "Nov \(1 + index % 25), 2026",
                tokens: tokens > 0 ? .init(compact: compact(tokens), color: heatmapHex(tokens), description: "\(compact(tokens)) tokens") : nil,
                cpu: index % 3 == 0 ? .init(fraction: Double(index % 10) / 10, label: "CPU \(index % 10 * 10)%") : nil,
                repositories: index % 4 == 0 ? repositories : [repositories[0]],
                mode: index % 2 == 0 ? "Plan" : nil,
                canMoveToDone: true,
                canMoveToReview: index % 2 == 1
            )
        }
    }

    /// The app's `TokenUsageHeatmap.compact`.
    public static func compact(_ tokens: Int) -> String {
        func trimmed(_ value: Double) -> String {
            let text = String(format: "%.1f", value)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        switch tokens {
        case ..<1_000: return "\(max(0, tokens))"
        case ..<100_000: return trimmed(Double(tokens) / 1_000) + "K"
        case ..<999_500: return "\(Int((Double(tokens) / 1_000).rounded()))K"
        default: return trimmed(Double(tokens) / 1_000_000) + "M"
        }
    }

    /// The app's `TokenUsageHeatmap.color` (HSB green → red) as #RRGGBB.
    public static func heatmapHex(_ tokens: Int, max: Int = 2_000_000) -> String {
        let fraction = Swift.min(1, Double(tokens) / Double(max))
        let (r, g, b) = Theme.hsb(0.33 * (1 - fraction), 0.45 + 0.45 * fraction, 0.80)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

/// Colors and metrics taken from the native card (WorkspaceTheme, AtomColor,
/// AtomCard, macOS dark-mode label colors), as both libraries need them.
public enum Theme {
    public static let window = "#1E1E1E"
    public static let cardFill = "#1E1E1E"
    /// `Color.primary.opacity(0.07)` in dark mode.
    public static let cardBorder = "rgba(255,255,255,0.07)"
    public static let text = "#C5C5C5"
    /// macOS dark `secondaryLabelColor` / `tertiaryLabelColor`.
    public static let secondary = "rgba(255,255,255,0.55)"
    public static let tertiary = "rgba(255,255,255,0.25)"
    /// macOS dark system blue / red (`Color.accentColor`, `Color.red`).
    public static let accent = "#0A84FF"
    public static let red = "#FF453A"
    public static let cornerRadius = 12.0
    public static let padding = 14.0
    public static let cardWidth = 264.0
    /// `CPUUsageHeatmap.gradient`: HSB(0.33, 0.7, 0.75) at the bottom to HSB(0, 0.7, 0.75) at the top.
    public static let meterGreen = hex(hsb(0.33, 0.7, 0.75))
    public static let meterRed = hex(hsb(0.0, 0.7, 0.75))
    public static let fontFamily = "Inter"
    public static let monoFamily = "JetBrains Mono"

    public static func hsb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    public static func hex(_ rgb: (Double, Double, Double)) -> String {
        String(format: "#%02X%02X%02X", Int((rgb.0 * 255).rounded()), Int((rgb.1 * 255).rounded()), Int((rgb.2 * 255).rounded()))
    }

    /// #RRGGBB → 0...1 components.
    public static func components(_ hex: String) -> (Double, Double, Double) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}
