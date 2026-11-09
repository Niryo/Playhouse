import SwiftUI

/// What the Token Stats modal shows, already derived from a task's usage
/// summary and token map: plain values the native modal and the catalog's
/// JavaScript copy (catalog/TokenStats.js, as `Playhouse.props.tokenStats`)
/// compose the same way. Every number is already formatted. `id` prefixes
/// every accessibility identifier ("token-stats" on the board).
struct TokenStatsModel: Codable, Equatable {
    struct Section: Codable, Equatable {
        /// overview, wasters, tools or overhead; also the section's identifier suffix.
        var value: String
        var label: String
    }

    /// One of the big numbers at the top of the overview.
    struct Headline: Codable, Equatable {
        /// The identifier suffix: final-transcript, total-sent or excluding-cache.
        var key: String
        var label: String
        var value: String
    }

    struct Bucket: Codable, Equatable {
        var label: String
        var value: String
    }

    /// The call-level totals, present once the task has recorded calls.
    struct Calls: Codable, Equatable {
        var headlines: [Headline]
        var excludingCacheSplit: String?
        var calls: String
        var output: String
    }

    struct Tool: Codable, Equatable {
        var id: String
        var turns: String
        var total: String
    }

    struct Turn: Codable, Equatable {
        var id: String
        var recordedAt: String
        var provider: String
        var total: String
        var tools: String?
    }

    struct Overview: Codable, Equatable {
        var calls: Calls?
        var total: String
        var turnsCaption: String
        /// The turns listed add up to less than the total: private turns aren't listed.
        var hiddenTurnsNote: Bool
        var buckets: [Bucket]
        var tools: [Tool]
        var turns: [Turn]
    }

    /// A row's share bar: its length and heat against the largest row in its list.
    struct Bar: Codable, Equatable {
        var fraction: Double
        /// #RRGGBB on the token heatmap.
        var color: String
    }

    /// What the raw input sheet opens on: one agent's item, or (both nil) the final transcript.
    struct RawInputTarget: Codable, Equatable {
        var agent: String?
        var item: Int?
        var inFinalTranscript: Bool
    }

    struct Waster: Codable, Equatable {
        var label: String
        var kind: String
        var removed: Bool
        var preview: String
        var requests: String
        var tokens: String
        var bar: Bar
        var target: RawInputTarget
    }

    struct Duplicate: Codable, Equatable {
        var label: String
        var copies: String
        var wasted: String
    }

    struct CacheMiss: Codable, Equatable {
        var request: String
        var detail: String
        var rewritten: String
    }

    struct MeasuredTool: Codable, Equatable {
        var id: String
        var detail: String
        var total: String
        var bar: Bar
    }

    struct Server: Codable, Equatable {
        var id: String
        var detail: String
        var total: String
    }

    struct Overhead: Codable, Equatable {
        var label: String
        var requests: String
        var tokens: String
        var bar: Bar
    }

    struct Agent: Codable, Equatable {
        var id: String
        var label: String
        var detail: String
        var sent: String
    }

    /// The token map's sections, present once the providers' session files have a request log.
    struct Map: Codable, Equatable {
        var wasters: [Waster]
        var duplicates: [Duplicate]
        var cacheMisses: [CacheMiss]
        var tools: [MeasuredTool]
        var servers: [Server]
        var overhead: [Overhead]
        var agents: [Agent]
    }

    var id: String
    var title: String
    var taskTitle: String
    var sections: [Section]
    /// The first read has finished, so a missing overview or map means there is none.
    var loaded: Bool
    var rawInputAvailable: Bool
    var overview: Overview?
    var map: Map?
}

extension TokenStatsModel {
    static let sections = [
        Section(value: "overview", label: "Overview"),
        Section(value: "wasters", label: "Wasters"),
        Section(value: "tools", label: "Tools & MCP"),
        Section(value: "overhead", label: "Overhead"),
    ]

    private static let number = IntegerFormatStyle<Int>().grouping(.automatic)

    private static func format(_ value: Int) -> String { value.formatted(number) }

    private static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    /// A row's share bar against the largest row in its list.
    static func bar(_ tokens: Int, largest: Int) -> Bar {
        Bar(
            fraction: largest > 0 ? min(1, Double(tokens) / Double(largest)) : 0,
            color: AtomColor.hex(TokenUsageHeatmap.color(totalTokens: tokens, max: max(1, largest)))
        )
    }

    init(taskTitle: String, summary: TaskTokenUsageSummary?, waste: TaskTokenWasteReport?, loaded: Bool) {
        id = "token-stats"
        title = "Token stats"
        self.taskTitle = taskTitle
        sections = Self.sections
        self.loaded = loaded
        rawInputAvailable = waste?.available == true
        if let summary, summary.totalTokens > 0 || summary.callUsage.available {
            overview = Self.overview(summary)
        }
        if let waste, waste.available {
            map = Self.map(waste)
        }
    }

    private static func overview(_ summary: TaskTokenUsageSummary) -> Overview {
        let usage = summary.callUsage
        var calls: Calls?
        if usage.available {
            var headlines = [
                Headline(key: "final-transcript", label: "Final transcript size", value: format(usage.finalTranscriptTokens)),
                Headline(key: "total-sent", label: "Total sent (incl. subagents)", value: format(usage.totalSentTokens)),
            ]
            if let excluding = usage.totalTokensExcludingCacheReads {
                headlines.append(Headline(key: "excluding-cache", label: "Excluding cache reads (incl. subagents)", value: format(excluding)))
            }
            var split: String?
            if let main = usage.mainAgent.tokensExcludingCacheReads, let subs = usage.subagents.tokensExcludingCacheReads {
                split = "Excluding cache reads: \(format(main)) main agent · \(format(subs)) subagents"
            }
            let subagents = usage.subagents
            calls = Calls(
                headlines: headlines,
                excludingCacheSplit: split,
                calls: "\(usage.totalCalls) model \(usage.totalCalls == 1 ? "call" : "calls") · \(usage.mainAgent.calls) main, \(subagents.calls) across \(plural(subagents.count, "subagent", "subagents"))",
                output: "Output \(format(usage.totalOutputTokens))"
            )
        }
        // A private recovery turn contributes to the total with no visible
        // row, so the two numbers can legitimately differ; the modal says so
        // rather than let it read as a miscount.
        let turnsTotal = summary.turns.reduce(0) { $0 + $1.totalTokens }
        return Overview(
            calls: calls,
            total: format(summary.totalTokens),
            turnsCaption: "tokens across \(plural(summary.turnCount, "turn", "turns"))",
            hiddenTurnsNote: turnsTotal != summary.totalTokens,
            buckets: [
                Bucket(label: "Input", value: format(summary.usage.inputTokens)),
                Bucket(label: "Output", value: format(summary.usage.outputTokens)),
                Bucket(label: "Cache read", value: format(summary.usage.cacheReadTokens)),
                Bucket(label: "Cache write", value: format(summary.usage.cacheCreationTokens)),
            ],
            tools: summary.tools.map { Tool(id: $0.id, turns: plural($0.turnCount, "turn", "turns"), total: format($0.totalTokens)) },
            turns: summary.turns.map { turn in
                Turn(
                    id: turn.id,
                    recordedAt: turn.recordedAt.formatted(date: .abbreviated, time: .shortened),
                    provider: turn.provider.displayName,
                    total: format(turn.totalTokens),
                    tools: turn.tools.isEmpty ? nil : turn.tools.joined(separator: " · ")
                )
            }
        )
    }

    private static func map(_ report: TaskTokenWasteReport) -> Map {
        let agentLabel = { (id: String) in report.agents.first { $0.id == id }?.label ?? id }
        let largestWaster = report.wasters.first?.tokens ?? 0
        let largestTool = report.tools.first?.totalTokens ?? 0
        let largestOverhead = report.overhead.first?.tokens ?? 0
        return Map(
            wasters: report.wasters.map { item in
                Waster(
                    label: item.label,
                    kind: contextKindName(item.kind),
                    removed: !item.inFinalTranscript,
                    preview: item.preview,
                    requests: "×\(item.requests)",
                    tokens: format(item.tokens),
                    bar: bar(item.tokens, largest: largestWaster),
                    target: RawInputTarget(agent: item.agent, item: item.item, inFinalTranscript: item.inFinalTranscript)
                )
            },
            duplicates: report.duplicates.map {
                Duplicate(label: $0.label, copies: "\($0.copies) copies of \(format($0.tokensPerCopy))", wasted: format($0.wastedTokens))
            },
            cacheMisses: report.cacheMisses.map {
                CacheMiss(request: "Request \($0.request)", detail: "\(agentLabel($0.agent)) · \(format($0.contextTokens)) in context", rewritten: format($0.rewrittenTokens))
            },
            tools: report.tools.map { tool in
                MeasuredTool(
                    id: tool.id,
                    detail: "\(plural(tool.calls, "call", "calls")) · largest \(format(tool.largestResultTokens)) · average \(format(tool.averageResultTokens))",
                    total: format(tool.totalTokens),
                    bar: bar(tool.totalTokens, largest: largestTool)
                )
            },
            servers: report.servers.map {
                Server(id: $0.id, detail: "\($0.tools) tools · \($0.calls) calls · definitions \(format($0.definitionTokens))", total: format($0.totalTokens))
            },
            overhead: report.overhead.map { entry in
                Overhead(
                    label: entry.label,
                    requests: entry.everyRequest ? "× every request" : "×\(entry.requests)",
                    tokens: format(entry.tokens),
                    bar: bar(entry.tokens, largest: largestOverhead)
                )
            },
            agents: report.agents.map { agent in
                Agent(
                    id: agent.id,
                    label: agent.label,
                    detail: "\(agent.requests) requests · final \(format(agent.finalTranscriptTokens))\(agent.compactions > 0 ? " · \(agent.compactions) compacted" : "")",
                    sent: format(agent.sentTokens)
                )
            }
        )
    }
}

/// How each kind of context item is named on screen.
func contextKindName(_ kind: String) -> String {
    switch ProviderContextKind(rawValue: kind) {
    case .systemPrompt: "System prompt"
    case .toolDefinition: "Tool definition"
    case .hiddenOverhead: "Hidden overhead"
    case .systemReminder: "Injected text"
    case .userText: "User"
    case .assistantText: "Assistant"
    case .thinking: "Thinking"
    case .toolCall: "Tool call"
    case .toolResult: "Tool result"
    case .image: "Image"
    case .other, nil: "Other"
    }
}

/// A bar whose length and heat follow an item's share of the largest one in
/// view, drawn by the Meter atom (Token Stats rows and the raw input list).
struct TokenShareBar: View {
    let bar: TokenStatsModel.Bar

    var body: some View {
        AtomMeter(props: MeterProps(fraction: bar.fraction, color: bar.color, thickness: 6, trackOpacity: 0.07, minFill: 2), common: AtomCommon(width: 72))
    }
}

/// What the modal's controls do: choose a section by its value, open the
/// raw input sheet on a target, and close.
struct TokenStatsActions {
    var selectSection: (String) -> Void = { _ in }
    var showRawInput: (TokenStatsModel.RawInputTarget) -> Void = { _ in }
    var done: () -> Void = {}
}

/// The task item's live token counter, which opens Token Stats. The hover
/// capsule pads the hit area well past the small text and overhangs, so the
/// larger target doesn't grow the row it sits in.
struct TokenCounterButton: View {
    let tokens: TaskItemModel.Tokens
    let testID: String
    let action: () -> Void

    var body: some View {
        AtomButton(
            props: ButtonProps(emphasis: 6, overhang: true),
            common: AtomCommon(testID: testID, label: tokens.description, hint: "Open Token Stats", help: "\(tokens.description). Click for Token Stats", paddingX: 4),
            action: action
        ) {
            AtomText(props: TextProps(text: tokens.compact, size: 10, weight: "medium", design: "monospaced", color: tokens.color, numeric: true))
        }
    }
}

/// The Token Stats modal's content, composed only of plugin atoms
/// (Plugins/Atoms), so a plugin building it from the same atoms looks
/// identical. Top to bottom: the title with the raw input button, the
/// section bar, the selected section, then Done. `section` is the selected
/// section's value; the owner holds it.
struct TokenStatsView: View {
    let model: TokenStatsModel
    let section: String
    var actions = TokenStatsActions()

    private var id: String { model.id }

    var body: some View {
        AtomStack(props: StackProps(axis: "v", spacing: 14, align: "leading", group: true), common: AtomCommon(testID: id, width: 672, padding: 24)) {
            AtomStack(props: StackProps(axis: "h", align: "top")) {
                AtomStack(props: StackProps(axis: "v", spacing: 4, align: "leading")) {
                    AtomText(props: TextProps(text: model.title, size: 19, weight: "semibold", design: "rounded"), common: AtomCommon(testID: "\(id)-title"))
                    AtomText(props: TextProps(text: model.taskTitle, size: 12, color: "secondary", lineLimit: 2), common: AtomCommon(testID: "\(id)-task-title"))
                }
                AtomSpacer()
                AtomButton(
                    props: ButtonProps(style: "bordered", disabled: !model.rawInputAvailable),
                    common: AtomCommon(testID: "\(id)-raw-input-button", help: "Open the full input the model was sent, item by item"),
                    action: { actions.showRawInput(.init(agent: nil, item: nil, inFinalTranscript: true)) }
                ) {
                    AtomLabel(props: LabelProps(text: "View raw input…", icon: "doc.text.magnifyingglass"))
                }
            }
            AtomChoiceBar(
                props: ChoiceBarProps(options: model.sections.map { .init(value: $0.value, label: $0.label, testID: "\(id)-section-\($0.value)") }, selected: section),
                common: AtomCommon(testID: "\(id)-sections"),
                onChange: actions.selectSection
            )
            switch section {
            case "wasters": map { wasters($0) }
            case "tools": map { measuredTools($0) }
            case "overhead": map { overhead($0) }
            default: overview
            }
            AtomStack(props: StackProps(axis: "h")) {
                AtomSpacer()
                AtomButton(
                    props: ButtonProps(style: "prominent", shortcut: "default"),
                    common: AtomCommon(testID: "close-\(id)-button", help: "Done"),
                    action: actions.done
                ) {
                    AtomText(props: TextProps(text: "Done"))
                }
            }
        }
    }

    @ViewBuilder
    private var overview: some View {
        if let overview = model.overview {
            totals(overview)
            AtomDivider()
            AtomScroll(props: ScrollProps(spacing: 18, maxHeight: 320), common: AtomCommon(testID: "\(id)-overview")) {
                tools(overview)
                turns(overview)
            }
        } else if model.loaded {
            AtomText(props: TextProps(text: "No tokens recorded for this task yet.", size: 12, color: "secondary"), common: AtomCommon(testID: "\(id)-empty"))
        }
    }

    /// A map section, or why there is no map: the providers only log their
    /// requests once a conversation has run with a version that writes them.
    @ViewBuilder
    private func map<Content: View>(@ViewBuilder _ content: @escaping (TokenStatsModel.Map) -> Content) -> some View {
        if let map = model.map {
            AtomScroll(props: ScrollProps(spacing: 18), common: AtomCommon(testID: "\(id)-map", height: 420)) {
                content(map)
            }
        } else if model.loaded {
            AtomText(
                props: TextProps(text: "No request log for this task yet. Claude Code and Codex write one to their session files as the conversation runs.", size: 12, color: "secondary"),
                common: AtomCommon(testID: "\(id)-map-unavailable")
            )
        }
    }

    private func sectionHeader(_ title: String, _ caption: String) -> some View {
        AtomStack(props: StackProps(axis: "v", spacing: 2, align: "leading")) {
            AtomText(props: TextProps(text: title, size: 12, weight: "semibold"))
            AtomText(props: TextProps(text: caption, size: 10, color: "tertiary"))
        }
    }

    private func tokens(_ value: String, id: String?) -> some View {
        AtomText(props: TextProps(text: value, size: 11, weight: "medium", monospacedDigits: true), common: AtomCommon(testID: id))
    }

    private func detail(_ text: String, id: String? = nil) -> some View {
        AtomText(props: TextProps(text: text, size: 10, color: "secondary", lineLimit: 1), common: AtomCommon(testID: id))
    }

    private func name(_ text: String, id: String? = nil) -> some View {
        AtomText(props: TextProps(text: text, size: 11, lineLimit: 1), common: AtomCommon(testID: id))
    }

    private func shareBar(_ bar: TokenStatsModel.Bar) -> some View {
        TokenShareBar(bar: bar)
    }

    /// One accessibility container per row, found by its identifier.
    private func row(_ testID: String, align: String? = nil, @ViewBuilder content: @escaping () -> some View) -> some View {
        AtomStack(props: StackProps(axis: "h", spacing: 8, align: align, group: true), common: AtomCommon(testID: testID), content: content)
    }

    private func list(@ViewBuilder content: @escaping () -> some View) -> some View {
        AtomStack(props: StackProps(axis: "v", spacing: 6, align: "leading"), content: content)
    }

    @ViewBuilder
    private func wasters(_ map: TokenStatsModel.Map) -> some View {
        list {
            sectionHeader("Largest items", "Ranked by the tokens each item added. ×N is how many requests carried it; show one to read its full text.")
            ForEach(Array(map.wasters.enumerated()), id: \.offset) { index, item in
                let prefix = "\(id)-waster-\(index)"
                row(prefix) {
                    shareBar(item.bar)
                    AtomStack(props: StackProps(axis: "v", spacing: 2, align: "leading")) {
                        AtomStack(props: StackProps(axis: "h", spacing: 6)) {
                            AtomText(props: TextProps(text: item.label, size: 11, weight: "medium", lineLimit: 1), common: AtomCommon(testID: "\(prefix)-label"))
                            AtomText(props: TextProps(text: item.kind, size: 9, color: "tertiary"))
                            if item.removed {
                                AtomText(props: TextProps(text: "removed by compaction", size: 9, color: "orange"), common: AtomCommon(testID: "\(prefix)-removed"))
                            }
                        }
                        detail(item.preview)
                    }
                    AtomSpacer(props: SpacerProps(minLength: 8))
                    detail(item.requests, id: "\(prefix)-requests")
                    tokens(item.tokens, id: "\(prefix)-tokens")
                    AtomButton(
                        props: ButtonProps(style: "bordered", controlSize: "small"),
                        common: AtomCommon(testID: "\(prefix)-show", help: "Show the full text the model received"),
                        action: { actions.showRawInput(item.target) }
                    ) {
                        AtomText(props: TextProps(text: "Show"))
                    }
                }
            }
        }
        if !map.duplicates.isEmpty {
            list {
                sectionHeader("Repeated results", "Tool results whose text was sent more than once in the same agent.")
                ForEach(Array(map.duplicates.enumerated()), id: \.offset) { index, duplicate in
                    row("\(id)-duplicate-\(index)") {
                        name(duplicate.label)
                        detail(duplicate.copies, id: "\(id)-duplicate-\(index)-copies")
                        AtomSpacer(props: SpacerProps(minLength: 8))
                        tokens(duplicate.wasted, id: "\(id)-duplicate-\(index)-wasted")
                    }
                }
            }
        }
        if !map.cacheMisses.isEmpty {
            list {
                sectionHeader("Cache misses", "Requests that re-sent most of the previous request's context without the prompt cache, paying for it again.")
                ForEach(Array(map.cacheMisses.enumerated()), id: \.offset) { index, miss in
                    row("\(id)-cache-miss-\(index)") {
                        AtomText(props: TextProps(text: miss.request, size: 11), common: AtomCommon(testID: "\(id)-cache-miss-\(index)-request"))
                        detail(miss.detail)
                        AtomSpacer(props: SpacerProps(minLength: 8))
                        tokens(miss.rewritten, id: "\(id)-cache-miss-\(index)-rewritten")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func measuredTools(_ map: TokenStatsModel.Map) -> some View {
        list {
            sectionHeader("Tools", "Tokens each tool's calls and results added to the context, across every agent.")
            ForEach(map.tools, id: \.id) { tool in
                let prefix = "\(id)-measured-tool-\(tool.id)"
                row(prefix) {
                    shareBar(tool.bar)
                    name(tool.id)
                    AtomSpacer(props: SpacerProps(minLength: 8))
                    detail(tool.detail, id: "\(prefix)-calls")
                    tokens(tool.total, id: "\(prefix)-total")
                }
            }
        }
        if !map.servers.isEmpty {
            list {
                sectionHeader("MCP servers", "What each server's calls added, and what its tool definitions cost on every request.")
                ForEach(map.servers, id: \.id) { server in
                    let prefix = "\(id)-server-\(server.id)"
                    row(prefix) {
                        name(server.id)
                        AtomSpacer(props: SpacerProps(minLength: 8))
                        detail(server.detail, id: "\(prefix)-detail")
                        tokens(server.total, id: "\(prefix)-total")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func overhead(_ map: TokenStatsModel.Map) -> some View {
        list {
            sectionHeader("Sent with every request", "The system prompt and tool definitions each main agent carries, whatever the conversation does.")
            ForEach(Array(map.overhead.enumerated()), id: \.offset) { index, entry in
                let prefix = "\(id)-overhead-\(index)"
                row(prefix) {
                    shareBar(entry.bar)
                    name(entry.label, id: "\(prefix)-label")
                    AtomSpacer(props: SpacerProps(minLength: 8))
                    detail(entry.requests, id: "\(prefix)-requests")
                    tokens(entry.tokens, id: "\(prefix)-tokens")
                }
            }
        }
        list {
            sectionHeader("Agents", "Each agent's own requests, everything they sent, and the size of its final transcript.")
            ForEach(map.agents, id: \.id) { agent in
                let prefix = "\(id)-agent-\(agent.id)"
                row(prefix) {
                    name(agent.label)
                    AtomSpacer(props: SpacerProps(minLength: 8))
                    detail(agent.detail, id: "\(prefix)-detail")
                    tokens(agent.sent, id: "\(prefix)-sent")
                }
            }
        }
    }

    private func totals(_ overview: TokenStatsModel.Overview) -> some View {
        AtomStack(props: StackProps(axis: "v", spacing: 8, align: "leading")) {
            callTotals(overview.calls)
            AtomText(props: TextProps(text: overview.total, size: 30, weight: "semibold", design: "rounded"), common: AtomCommon(testID: "\(id)-total"))
            AtomText(props: TextProps(text: overview.turnsCaption, size: 11, color: "secondary"))
            if overview.hiddenTurnsNote {
                AtomText(props: TextProps(text: "Includes tokens from private turns not shown below.", size: 10, color: "tertiary"), common: AtomCommon(testID: "\(id)-hidden-turns-note"))
            }
            AtomStack(props: StackProps(axis: "h", spacing: 18)) {
                ForEach(overview.buckets, id: \.label) { bucket in
                    AtomStack(props: StackProps(axis: "v", spacing: 2, align: "leading")) {
                        AtomText(props: TextProps(text: bucket.label, size: 10, color: "tertiary"))
                        AtomText(props: TextProps(text: bucket.value, size: 13, weight: "medium"))
                    }
                }
            }
        }
    }

    /// The two numbers a task is judged by: how large its transcript grew, and
    /// how much it re-sent over all of its model calls, subagents included.
    @ViewBuilder
    private func callTotals(_ calls: TokenStatsModel.Calls?) -> some View {
        if let calls {
            AtomStack(props: StackProps(axis: "v", spacing: 8, align: "leading")) {
                AtomStack(props: StackProps(axis: "h", spacing: 28, align: "top")) {
                    ForEach(calls.headlines, id: \.key) { headline in
                        AtomStack(props: StackProps(axis: "v", spacing: 2, align: "leading")) {
                            AtomText(props: TextProps(text: headline.label, size: 10, color: "tertiary"))
                            AtomText(props: TextProps(text: headline.value, size: 22, weight: "semibold", design: "rounded"), common: AtomCommon(testID: "\(id)-\(headline.key)"))
                        }
                    }
                }
                if let split = calls.excludingCacheSplit {
                    AtomText(props: TextProps(text: split, size: 11, color: "secondary"), common: AtomCommon(testID: "\(id)-excluding-cache-split"))
                }
                AtomText(props: TextProps(text: calls.calls, size: 11, color: "secondary"), common: AtomCommon(testID: "\(id)-total-calls"))
                AtomText(props: TextProps(text: calls.output, size: 11, color: "secondary"), common: AtomCommon(testID: "\(id)-output"))
                AtomDivider()
                AtomText(props: TextProps(text: "Main agent turns", size: 10, weight: "semibold", color: "tertiary"))
            }
        } else {
            AtomText(props: TextProps(text: "Call-level stats are not recorded for this task yet.", size: 10, color: "tertiary"), common: AtomCommon(testID: "\(id)-calls-unavailable"))
        }
    }

    @ViewBuilder
    private func tools(_ overview: TokenStatsModel.Overview) -> some View {
        // Providers report usage once per turn, so a turn's cost counts toward
        // every tool that ran in it. Say so rather than implying these totals
        // add up to the task total.
        if !overview.tools.isEmpty {
            AtomStack(props: StackProps(axis: "v", spacing: 6, align: "leading")) {
                AtomText(props: TextProps(text: "By tool, skill and MCP", size: 12, weight: "semibold"))
                AtomText(props: TextProps(text: "Cost of the turns each ran in; turns with several tools count toward each.", size: 10, color: "tertiary"))
                ForEach(overview.tools, id: \.id) { tool in
                    row("\(id)-tool-\(tool.id)", align: "baseline") {
                        name(tool.id)
                        AtomSpacer(props: SpacerProps(minLength: 8))
                        AtomText(props: TextProps(text: tool.turns, size: 10, color: "tertiary"))
                        tokens(tool.total, id: nil)
                    }
                }
            }
        }
    }

    private func turns(_ overview: TokenStatsModel.Overview) -> some View {
        AtomStack(props: StackProps(axis: "v", spacing: 6, align: "leading")) {
            AtomText(props: TextProps(text: "By turn", size: 12, weight: "semibold"))
            ForEach(overview.turns, id: \.id) { turn in
                AtomStack(props: StackProps(axis: "v", spacing: 2, align: "leading", group: true), common: AtomCommon(testID: "\(id)-turn-\(turn.id)")) {
                    AtomStack(props: StackProps(axis: "h", spacing: 8, align: "baseline")) {
                        AtomText(props: TextProps(text: turn.recordedAt, size: 11))
                        AtomText(props: TextProps(text: turn.provider, size: 10, color: "tertiary"))
                        AtomSpacer(props: SpacerProps(minLength: 8))
                        tokens(turn.total, id: nil)
                    }
                    if let tools = turn.tools {
                        AtomText(props: TextProps(text: tools, size: 10, color: "secondary", lineLimit: 2))
                    }
                }
            }
        }
    }
}
