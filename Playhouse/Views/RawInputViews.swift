import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

private extension ProviderSessionHomes {
    static var forThisApp: ProviderSessionHomes {
        let configuration = DaemonClient.Configuration.fromEnvironment()
        return .resolve(claudeConfigDirectory: configuration.claudeConfigDirectory, codexHome: configuration.codexHome)
    }
}

/// What the raw input sheet opens on: one agent's item, or the start of its transcript.
package struct RawInputFocus: Identifiable {
    package let id = UUID()
    package let agent: String?
    package let item: Int?
    package let inFinalTranscript: Bool

    package init(agent: String?, item: Int?, inFinalTranscript: Bool) {
        self.agent = agent
        self.item = item
        self.inFinalTranscript = inFinalTranscript
    }
}

/// The `ChoiceBar` atom over a string-backed choice, so the raw input sheet's
/// scope and export bars share the Token Stats section bar's view.
private struct ChoiceBar<Choice: RawRepresentable & Hashable>: PHView where Choice.RawValue == String {
    let choices: [(value: Choice, title: String, id: String)]
    @PHBinding var selection: Choice

    var body: some PHView {
        AtomChoiceBar(
            props: ChoiceBarProps(options: choices.map { .init(value: $0.value.rawValue, label: $0.title, testID: $0.id) }, selected: selection.rawValue)
        ) { value in
            if let choice = Choice(rawValue: value) { selection = choice }
        }
    }
}

/// The board's Token Stats modal: a task's token accounting, re-read every
/// two seconds while it is open, around the atom-built `TokenStatsView`. It
/// holds the selected section and opens the raw input sheet. With a `turnID`
/// it shows only that finished turn, read once: nothing it covers changes.
package struct TokenStatsSheet: PHView {
    @PHEnvironment(\.dismiss) private var dismiss
    package let taskID: UUID
    package let taskTitle: String
    package var turnID: String?
    package let modelContext: PlayhouseModelContext
    @PHState private var summary: TaskTokenUsageSummary?
    @PHState private var waste: TaskTokenWasteReport?
    @PHState private var didLoad = false
    @PHState private var section = "overview"
    @PHState private var rawInputFocus: RawInputFocus?

    package var body: some PHView {
        TokenStatsView(
            model: TokenStatsModel(taskTitle: taskTitle, summary: summary, waste: waste, loaded: didLoad),
            section: section,
            actions: TokenStatsActions(
                selectSection: { section = $0 },
                showRawInput: { rawInputFocus = RawInputFocus(agent: $0.agent, item: $0.item, inFinalTranscript: $0.inFinalTranscript) },
                done: { dismiss() }
            )
        )
        // Keeps reading while the sheet is open, so a running turn's calls
        // show up live. The map extends its parsed logs from where they
        // stopped, so a poll only reads what the session files gained.
        .task {
            let manager = BoardTaskManager(modelContext: modelContext)
            if let turnID {
                summary = try? await manager.tokenUsageSummary(taskID, turnID: turnID, homes: .forThisApp)
                waste = try? await manager.tokenWasteReport(taskID, turnID: turnID, homes: .forThisApp)
                didLoad = true
                return
            }
            while !Task.isCancelled {
                summary = try? manager.tokenUsageSummary(taskID)
                waste = try? await manager.tokenWasteReport(taskID, homes: .forThisApp)
                didLoad = true
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(item: $rawInputFocus) { focus in
            RawInputSheet(taskID: taskID, taskTitle: taskTitle, turnID: turnID, modelContext: modelContext, focus: focus)
        }
    }

    package init(taskID: UUID, taskTitle: String, turnID: String? = nil, modelContext: PlayhouseModelContext) {
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.turnID = turnID
        self.modelContext = modelContext
    }
}

private extension TaskRawInputPage.Row {
    /// A single request can list one item twice, so its rows are keyed by position.
    var listKey: Int { position ?? id }
    var accessibilityID: String { position.map { "raw-input-request-row-\($0)" } ?? "raw-input-row-\(id)" }
}

/// The input a task's model requests were sent, one row per item: the final
/// transcript or everything ever sent (including what a compaction removed)
/// list each item once, and a single request lists everything it sent in
/// order, repeats included and flagged. Rows load a page at a time as the list scrolls.
package struct RawInputSheet: PHView {
    @PHEnvironment(\.dismiss) private var dismiss
    package let taskID: UUID
    package let taskTitle: String
    /// The one turn whose requests the sheet lists; `nil` lists the whole conversation's.
    package let turnID: String?
    package let modelContext: PlayhouseModelContext
    package let focus: RawInputFocus
    @PHState private var agent: String?
    @PHState private var scope: TaskRawInputScope
    @PHState private var order = TaskRawInputOrder.transcript
    @PHState private var query = ""
    @PHState private var submittedQuery = ""
    @PHState private var page: TaskRawInputPage?
    @PHState private var rows: [TaskRawInputPage.Row] = []
    @PHState private var isLoading = false
    @PHState private var selected: Int?
    /// In a single request, which copy of the selected item is highlighted.
    @PHState private var selectedPosition: Int?
    @PHState private var scrollTarget: Int?
    /// `nil` is the request the final transcript was read from.
    @PHState private var requestNumber: Int?
    @PHState private var requestField = ""
    @PHState private var exportFormat = TaskRawInputExportFormat.text
    @PHState private var exportStatus: String?

    private static let pageSize = 100
    private static let number = IntegerFormatStyle<Int>().grouping(.automatic)

    /// Wide enough for the list beside the text, but never wider or taller than the screen.
    private static var size: CGSize {
        let visible = Platform.services.mainScreenVisibleFrame?.size ?? CGSize(width: 1200, height: 800)
        return CGSize(width: min(1120, max(800, visible.width - 60)), height: min(720, max(480, visible.height - 80)))
    }

    package init(taskID: UUID, taskTitle: String, turnID: String? = nil, modelContext: PlayhouseModelContext, focus: RawInputFocus) {
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.turnID = turnID
        self.modelContext = modelContext
        self.focus = focus
        _agent = PHState(initialValue: focus.agent)
        _scope = PHState(initialValue: focus.inFinalTranscript ? .finalTranscript : .everything)
        _selected = PHState(initialValue: focus.item)
    }

    private var hasMore: Bool { rows.count < (page?.total ?? 0) }
    private var reloadKey: String {
        "\(agent ?? "")|\(scope.rawValue)|\(order.rawValue)|\(submittedQuery)|\(scope == .request ? requestNumber ?? 0 : 0)"
    }

    package var body: some PHView {
        // The fixed size holds the 20 pt padding, so the content gets 40 pt less.
        AtomStack(
            props: StackProps(spacing: 12, align: "leading"),
            common: AtomCommon(width: Self.size.width - 40, height: Self.size.height - 40, padding: 20)
        ) {
            AtomStack(props: StackProps(axis: "h", align: "baseline")) {
                AtomStack(props: StackProps(spacing: 4, align: "leading")) {
                    AtomText(props: TextProps(text: "Raw input", size: 19, weight: "semibold", design: "rounded"))
                    AtomText(props: TextProps(text: taskTitle, size: 12, color: "secondary", lineLimit: 1))
                }
                AtomSpacer()
                if let page {
                    AtomStack(props: StackProps(spacing: 2, align: "trailing")) {
                        AtomText(
                            props: TextProps(text: "\(page.total) \(page.total == 1 ? "item" : "items") · \(page.totalTokens.formatted(Self.number)) tokens", size: 12, color: "secondary"),
                            common: AtomCommon(testID: "raw-input-summary")
                        )
                        AtomText(props: TextProps(text: "\(rows.count) of \(page.total) loaded", size: 10, color: "tertiary"), common: AtomCommon(testID: "raw-input-loaded-rows"))
                    }
                }
            }
            controls
            if scope == .request, let request = page?.request {
                requestBar(request)
            }
            AtomStack(props: StackProps(axis: "h", spacing: 0, align: "top"), common: AtomCommon(fillHeight: true)) {
                AtomStack(common: AtomCommon(width: min(460, Self.size.width * 0.42))) {
                    list
                }
                AtomDivider()
                AtomStack(common: AtomCommon(fillWidth: true, fillHeight: true, frameAlign: "center")) {
                    if let selected {
                        RawInputTextPane(taskID: taskID, turnID: turnID, modelContext: modelContext, agent: page?.agent ?? agent, item: selected)
                            .id("\(page?.agent ?? agent ?? "")#\(selected)")
                    } else {
                        AtomText(
                            props: TextProps(text: "Select an item to read the full text the model received.", size: 12, color: "secondary"),
                            common: AtomCommon(testID: "raw-input-no-selection", fillWidth: true, fillHeight: true, frameAlign: "center")
                        )
                    }
                }
            }
            AtomStack(props: StackProps(axis: "h")) {
                AtomSpacer()
                AtomButton(
                    props: ButtonProps(style: "prominent", shortcut: "default"),
                    common: AtomCommon(testID: "close-raw-input-button", help: "Done"),
                    action: { dismiss() }
                ) {
                    AtomText(props: TextProps(text: "Done"))
                }
            }
        }
        .task(id: reloadKey) { await reload() }
        // Item IDs belong to one agent's log; another agent's item with the same ID is unrelated.
        .onChange(of: agent) {
            selected = nil
            selectedPosition = nil
            requestNumber = nil
        }
        .onChange(of: requestNumber) {
            selected = nil
            selectedPosition = nil
            exportStatus = nil
        }
    }

    private var controls: some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 10)) {
            if let page, page.agents.count > 1 {
                LabeledMenuPicker(
                    title: "Agent",
                    options: page.agents.map { .init(value: $0.id, label: $0.label) },
                    selected: agent ?? page.agent ?? "",
                    testID: "raw-input-agent-picker",
                    width: 240
                ) { agent = $0 }
            }
            ChoiceBar(
                choices: [
                    (TaskRawInputScope.finalTranscript, "Final transcript", "raw-input-scope-final"),
                    (TaskRawInputScope.everything, "Everything sent", "raw-input-scope-all"),
                    (TaskRawInputScope.request, "Single request", "raw-input-scope-request"),
                ],
                selection: $scope
            )
            LabeledMenuPicker(
                title: "Order",
                options: [
                    .init(value: TaskRawInputOrder.transcript.rawValue, label: "Transcript order"),
                    .init(value: TaskRawInputOrder.size.rawValue, label: "Largest first"),
                    .init(value: TaskRawInputOrder.rent.rawValue, label: "Most tokens carried"),
                ],
                selected: order.rawValue,
                testID: "raw-input-order-picker",
                width: 220
            ) { if let chosen = TaskRawInputOrder(rawValue: $0) { order = chosen } }
            AtomTextField(
                props: TextFieldProps(text: query, placeholder: "Search the full text"),
                common: AtomCommon(testID: "raw-input-search-field"),
                onChange: { query = $0 },
                onSubmit: { submittedQuery = query }
            )
        }
    }

    private var list: some PHView {
        PHScrollViewReader { proxy in
            AtomScroll(props: ScrollProps(directContent: true)) {
                AtomStack(common: AtomCommon(paddingTrailing: 8)) {
                    AtomStack(props: StackProps(spacing: 2, align: "leading", lazy: true)) {
                        PHForEach(rows, id: \.listKey) { row in
                            RawInputRowView(
                                row: row, maxTokens: page?.maxTokens ?? 0,
                                isSelected: row.position.map { $0 == selectedPosition } ?? (row.id == selected)
                            )
                            .id(row.listKey)
                            .onTapGesture {
                                selected = row.id
                                selectedPosition = row.position
                            }
                            // no-pointer: selecting a list row, which keeps the arrow like other macOS lists.
                            .onAppear {
                                if row.listKey == rows.last?.listKey { Task { await loadMore() } }
                            }
                        }
                        if hasMore {
                            AtomSpinner(common: AtomCommon(testID: "raw-input-loading-more", fillWidth: true, frameAlign: "center", padding: 8))
                        } else if page != nil, rows.isEmpty {
                            AtomText(
                                props: TextProps(text: submittedQuery.isEmpty ? "Nothing was sent yet." : "No item contains “\(submittedQuery)”.", size: 12, color: "secondary"),
                                common: AtomCommon(testID: "raw-input-empty", padding: 12)
                            )
                        }
                    }
                }
                .hoverRevealScrollers()
            }
            .accessibilityIdentifier("raw-input-list")
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .center)
                scrollTarget = nil
            }
        }
    }

    private func fetch(offset: Int, focusing item: Int?) async -> TaskRawInputPage? {
        try? await BoardTaskManager(modelContext: modelContext).rawInputPage(
            taskID, turnID: turnID, homes: .forThisApp, agent: agent, scope: scope, order: order, query: submittedQuery,
            offset: offset, limit: Self.pageSize, focus: item, request: scope == .request ? requestNumber : nil
        )
    }

    /// Which request is shown, how the provider measured it, how exact the
    /// rebuild is, and the whole request's export.
    private func requestBar(_ request: TaskRawInputPage.Request) -> some PHView {
        let exactness = request.exact ? "green" : "orange"
        return AtomStack(props: StackProps(spacing: 4, align: "leading", fill: "primary", fillOpacity: 0.04, cornerRadius: 7), common: AtomCommon(padding: 8)) {
            AtomStack(props: StackProps(axis: "h", spacing: 8)) {
                AtomButton(
                    props: ButtonProps(style: "automatic", disabled: request.number <= 1),
                    common: AtomCommon(testID: "raw-input-request-previous", label: "Previous request", help: "Show the request before this one"),
                    action: { requestNumber = request.number - 1 }
                ) {
                    AtomIcon(props: IconProps(name: PHIcon.chevronLeft.name))
                }
                AtomText(
                    props: TextProps(text: "Request \(request.number) of \(request.count)", size: 12, weight: "semibold", monospacedDigits: true),
                    common: AtomCommon(testID: "raw-input-request-number")
                )
                AtomButton(
                    props: ButtonProps(style: "automatic", disabled: request.number >= request.count),
                    common: AtomCommon(testID: "raw-input-request-next", label: "Next request", help: "Show the request after this one"),
                    action: { requestNumber = request.number + 1 }
                ) {
                    AtomIcon(props: IconProps(name: PHIcon.chevronRight.name))
                }
                AtomTextField(
                    props: TextFieldProps(text: requestField, placeholder: "Go to #"),
                    common: AtomCommon(testID: "raw-input-request-field", width: 70),
                    onChange: { requestField = $0 },
                    onSubmit: {
                        if let number = Int(requestField.trimmingCharacters(in: .whitespaces)) {
                            requestNumber = min(max(1, number), request.count)
                        }
                        requestField = ""
                    }
                )
                AtomButton(
                    props: ButtonProps(style: "automatic", disabled: request.number == request.latest, controlSize: "small"),
                    common: AtomCommon(testID: "raw-input-request-latest", help: "Show the request the final transcript was read from"),
                    action: { requestNumber = nil }
                ) {
                    AtomText(props: TextProps(text: "Latest"))
                }
                AtomStack(props: StackProps(fill: exactness, fillOpacity: 0.15, capsule: true), common: AtomCommon(help: request.note, paddingX: 5, paddingY: 1)) {
                    AtomText(
                        props: TextProps(text: request.exact ? "Exact" : "Reconstructed", size: 9, weight: "semibold", color: exactness),
                        common: AtomCommon(testID: "raw-input-request-exactness")
                    )
                }
                if let timestamp = request.timestamp {
                    AtomText(props: TextProps(text: Self.displayTime(timestamp), size: 10, color: "tertiary"), common: AtomCommon(testID: "raw-input-request-time"))
                }
                AtomSpacer(props: SpacerProps(minLength: 8))
                ChoiceBar(
                    choices: [
                        (TaskRawInputExportFormat.text, "Text", "raw-input-export-format-text"),
                        (TaskRawInputExportFormat.json, "JSON", "raw-input-export-format-json"),
                    ],
                    selection: $exportFormat
                )
                AtomButton(
                    props: ButtonProps(style: "automatic", controlSize: "small"),
                    common: AtomCommon(testID: "raw-input-request-copy-button", help: "Copy this whole request, every item in order"),
                    action: { Task { await exportRequest(request, open: false) } }
                ) {
                    AtomLabel(props: LabelProps(text: "Copy all", icon: PHIcon.docOnDoc.name))
                }
                AtomButton(
                    props: ButtonProps(style: "automatic", controlSize: "small"),
                    common: AtomCommon(testID: "raw-input-request-open-editor-button", help: "Write this whole request to a file and open it"),
                    action: { Task { await exportRequest(request, open: true) } }
                ) {
                    AtomLabel(props: LabelProps(text: "Open in editor", icon: PHIcon.squareAndPencil.name))
                }
            }
            // The bar keeps one height whatever it shows: a bar that grows
            // resizes the lazy list below it while it lays out its rows.
            AtomStack(props: StackProps(axis: "h", spacing: 8)) {
                AtomText(
                    props: TextProps(text: Self.usageLine(request), size: 11, color: "secondary", lineLimit: 1, monospacedDigits: true),
                    common: AtomCommon(testID: "raw-input-request-usage", layoutPriority: 1)
                )
                AtomSpacer(props: SpacerProps(minLength: 8))
                AtomText(props: TextProps(text: exportStatus ?? "", size: 10, color: "secondary", lineLimit: 1), common: AtomCommon(testID: "raw-input-request-export-status"))
            }
            // Two lines are always reserved: an invisible two-line text under the note.
            AtomStack(props: StackProps(axis: "z", align: "topLeading")) {
                AtomText(props: TextProps(text: " \n ", size: 10, lineLimit: 2), common: AtomCommon(opacity: 0, decorative: true))
                AtomText(
                    props: TextProps(text: "\(request.note) \(request.tokenNote)", size: 10, color: "tertiary", lineLimit: 2),
                    common: AtomCommon(testID: "raw-input-request-note", help: "\(request.note) \(request.tokenNote)")
                )
            }
        }
    }

    private static func usageLine(_ request: TaskRawInputPage.Request) -> String {
        var parts: [String] = []
        if let context = request.contextTokens {
            var reported = "Reported input \(context.formatted(number))"
            var split = ["uncached \((request.inputTokens ?? 0).formatted(number))", "cache read \((request.cacheReadTokens ?? 0).formatted(number))"]
            if let write = request.cacheWriteTokens { split.append("cache write \(write.formatted(number))") }
            reported += " (\(split.joined(separator: " · ")))"
            parts.append(reported)
        } else {
            parts.append("No usage reported")
        }
        parts.append("items add up to \(request.itemTokens.formatted(number))")
        parts.append("\(request.repeatedItems) repeated")
        if let source = request.querySource, !source.isEmpty { parts.append("source \(source)") }
        return parts.joined(separator: " · ")
    }

    private static func displayTime(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        return date?.formatted(date: .abbreviated, time: .standard) ?? timestamp
    }

    private func exportRequest(_ request: TaskRawInputPage.Request, open: Bool) async {
        let format = exportFormat
        do {
            let export = try await BoardTaskManager(modelContext: modelContext).rawInputExport(
                taskID, turnID: turnID, homes: .forThisApp, agent: page?.agent ?? agent, request: request.number, format: format
            )
            let name = format == .json ? "JSON" : "text"
            if open {
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("playhouse-request-\(taskID.uuidString.prefix(8))-\(export.agent.replacingOccurrences(of: "/", with: "-"))-\(export.request).\(format == .json ? "json" : "txt")")
                try export.text.write(to: file, atomically: true, encoding: .utf8)
                Platform.services.open(file)
                exportStatus = "Opened request \(export.request) as \(name): \(export.items) items"
            } else {
                Platform.services.copyToClipboard(export.text)
                exportStatus = "Copied request \(export.request) as \(name): \(export.items) items"
            }
        } catch {
            exportStatus = error.localizedDescription
        }
    }

    /// Loads the first page, then on up to the selected item so the list can scroll to it.
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        guard let first = await fetch(offset: 0, focusing: selected) else { return }
        page = first
        rows = first.rows
        if let position = first.focusPosition {
            while rows.count <= position, let next = await fetch(offset: rows.count, focusing: nil), !next.rows.isEmpty {
                rows += next.rows
            }
            guard rows.indices.contains(position) else { return }
            if selectedPosition == nil || scope != .request { selectedPosition = rows[position].position }
            scrollTarget = rows[position].listKey
        }
    }

    private func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let next = await fetch(offset: rows.count, focusing: nil) else { return }
        page = next
        rows += next.rows
    }
}

private struct RawInputRowView: PHView {
    let row: TaskRawInputPage.Row
    let maxTokens: Int
    let isSelected: Bool

    private static let number = IntegerFormatStyle<Int>().grouping(.automatic)

    var body: some PHView {
        // The hover handler gives the whole row, padding included, the hit
        // shape, so a click anywhere on it selects it.
        AtomStack(
            props: StackProps(spacing: 3, align: "leading", group: true, fill: fill.color, fillOpacity: fill.opacity, cornerRadius: 6),
            common: AtomCommon(testID: row.accessibilityID, paddingX: 8, paddingY: 5),
            onHover: { _ in }
        ) {
            AtomStack(props: StackProps(axis: "h", spacing: 6)) {
                AtomStack(props: StackProps(fill: "primary", fillOpacity: 0.07, capsule: true), common: AtomCommon(paddingX: 5, paddingY: 1)) {
                    AtomText(props: TextProps(text: contextKindName(row.kind), size: 9, weight: "semibold", color: "secondary"))
                }
                if let position = row.position {
                    AtomText(props: TextProps(text: "#\(position + 1)", size: 9, color: "tertiary", monospacedDigits: true))
                }
                AtomText(props: TextProps(text: row.label, size: 11, weight: "medium", lineLimit: 1), common: AtomCommon(testID: "\(row.accessibilityID)-label"))
                if !row.inFinalTranscript {
                    AtomText(props: TextProps(text: "removed", size: 9, color: "orange"))
                }
                AtomSpacer(props: SpacerProps(minLength: 6))
                AtomText(props: TextProps(text: "×\(row.requests)", size: 10, color: "tertiary"))
                AtomText(
                    props: TextProps(text: row.tokens.formatted(Self.number), size: 11, weight: "medium", monospacedDigits: true),
                    common: AtomCommon(testID: "\(row.accessibilityID)-tokens")
                )
            }
            AtomStack(props: StackProps(axis: "h", spacing: 6)) {
                TokenShareBar(bar: TokenStatsModel.bar(row.tokens, largest: maxTokens))
                AtomText(props: TextProps(text: row.preview, size: 10, design: "monospaced", color: "secondary", lineLimit: 1))
            }
            // Every row of a single request keeps this line, flagged or not: rows
            // of one height keep the lazy list's placement from oscillating.
            if row.position != nil {
                if let repeated = row.repeated {
                    AtomText(
                        props: TextProps(
                            text: "Duplicate \(repeated.copy) of \(repeated.copies)\(repeated.copy > 1 ? " · first at #\(repeated.first + 1)" : "")",
                            size: 9, weight: "semibold", color: "red", lineLimit: 1
                        ),
                        common: AtomCommon(testID: "\(row.accessibilityID)-repeat")
                    )
                } else {
                    AtomText(props: TextProps(text: " ", size: 9, weight: "semibold"), common: AtomCommon(decorative: true))
                }
            }
        }
    }

    /// Selected rows take the accent, repeated ones a red tint, the rest nothing.
    private var fill: (color: String, opacity: Double) {
        if isSelected { return ("accent", 0.18) }
        return row.repeated == nil ? ("clear", 1) : ("red", 0.08)
    }
}

/// One item's full text, line-numbered, read from the session file a chunk at
/// a time as it scrolls; a chunk always ends on a line break.
private struct RawInputTextPane: PHView {
    private struct Line: Identifiable {
        let id: Int
        let number: Int?
        let text: String
    }

    let taskID: UUID
    let turnID: String?
    let modelContext: PlayhouseModelContext
    let agent: String?
    let item: Int
    @PHState private var header: TaskRawInputText?
    @PHState private var lines: [Line] = []
    @PHState private var nextOffset: Int? = 0
    @PHState private var nextNumber = 1
    /// A chunk with no line break in its second half ends mid-line; the next one continues that line.
    @PHState private var continuesLine = false
    @PHState private var loadedLength = 0
    @PHState private var isLoading = false
    @PHState private var failure: String?

    private static let number = IntegerFormatStyle<Int>().grouping(.automatic)
    /// A very long line (minified JSON, a base64 blob) wraps across rows of this many characters.
    private static let segmentLength = 2_000

    var body: some PHView {
        AtomStack(props: StackProps(spacing: 8, align: "leading"), common: AtomCommon(paddingLeading: 12)) {
            if let header {
                AtomStack(props: StackProps(axis: "h", spacing: 8, align: "baseline")) {
                    AtomText(props: TextProps(text: header.label, size: 13, weight: "semibold", lineLimit: 1), common: AtomCommon(testID: "raw-input-text-label"))
                    AtomText(props: TextProps(text: contextKindName(header.kind), size: 10, color: "tertiary"))
                    AtomSpacer()
                    AtomButton(
                        props: ButtonProps(style: "automatic", controlSize: "small"),
                        common: AtomCommon(testID: "raw-input-copy-button", help: "Copy this item's full text"),
                        action: { Task { await copyAll() } }
                    ) {
                        AtomLabel(props: LabelProps(text: "Copy all", icon: PHIcon.docOnDoc.name))
                    }
                    AtomButton(
                        props: ButtonProps(style: "automatic", controlSize: "small"),
                        common: AtomCommon(testID: "raw-input-open-editor-button", help: "Write this item's full text to a file and open it"),
                        action: { Task { await openInEditor() } }
                    ) {
                        AtomLabel(props: LabelProps(text: "Open in editor", icon: PHIcon.squareAndPencil.name))
                    }
                }
                AtomText(
                    props: TextProps(
                        text: "\(header.tokens.formatted(Self.number)) tokens · carried in \(header.requests) \(header.requests == 1 ? "request" : "requests") · \(header.totalLength.formatted(Self.number)) characters",
                        size: 11, color: "secondary"
                    ),
                    common: AtomCommon(testID: "raw-input-text-size")
                )
                AtomText(
                    props: TextProps(text: "\(loadedLength.formatted(Self.number)) of \(header.totalLength.formatted(Self.number)) characters loaded", size: 10, color: "tertiary"),
                    common: AtomCommon(testID: "raw-input-text-loaded")
                )
                if let call = header.call {
                    AtomText(
                        props: TextProps(text: "Called as \(call)", size: 10, design: "monospaced", color: "secondary", lineLimit: 3, selectable: true),
                        common: AtomCommon(testID: "raw-input-text-call")
                    )
                }
                AtomDivider()
            } else if let failure {
                AtomText(props: TextProps(text: failure, size: 12, color: "secondary"), common: AtomCommon(testID: "raw-input-text-failure"))
            }
            AtomScroll(props: ScrollProps(directContent: true)) {
                AtomStack(common: AtomCommon(paddingTrailing: 8)) {
                    AtomStack(props: StackProps(spacing: 0, align: "leading", lazy: true)) {
                        PHForEach(lines) { line in
                            AtomStack(
                                props: StackProps(axis: "h", spacing: 10, align: "top", combine: true),
                                common: AtomCommon(testID: line.number.map { "raw-input-text-line-\($0)" })
                            ) {
                                AtomText(
                                    props: TextProps(text: line.number.map(String.init) ?? "", size: 11, design: "monospaced", color: "tertiary"),
                                    common: AtomCommon(width: 52, frameAlign: "trailing")
                                )
                                AtomText(
                                    props: TextProps(text: line.text.isEmpty ? " " : line.text, size: 11, design: "monospaced", selectable: true),
                                    common: AtomCommon(fillWidth: true)
                                )
                            }
                            .onAppear {
                                if line.id == lines.last?.id { Task { await loadNextChunk() } }
                            }
                        }
                    }
                }
                .hoverRevealScrollers()
            }
            .accessibilityIdentifier("raw-input-text")
        }
        .task { await loadNextChunk() }
    }

    private func loadNextChunk() async {
        guard let offset = nextOffset, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let chunk = try await BoardTaskManager(modelContext: modelContext).rawInputText(
                taskID, turnID: turnID, homes: .forThisApp, agent: agent, item: item, offset: offset, length: ProviderTokenMap.defaultTextChunk
            )
            header = chunk
            append(chunk.text, isLast: chunk.nextOffset == nil)
            nextOffset = chunk.nextOffset
            loadedLength = chunk.nextOffset ?? chunk.totalLength
        } catch {
            failure = error.localizedDescription
            nextOffset = nil
        }
    }

    private func append(_ text: String, isLast: Bool) {
        var parts = text.components(separatedBy: "\n")
        let endsOnLineBreak = parts.last == ""
        // A chunk that ends on a line break leaves one empty part after it.
        if !isLast, endsOnLineBreak { parts.removeLast() }
        var added: [Line] = []
        for (index, part) in parts.enumerated() {
            var rest = Substring(part)
            let continuing = index == 0 && continuesLine
            var number: Int? = continuing ? nil : nextNumber
            repeat {
                added.append(Line(id: lines.count + added.count, number: number, text: String(rest.prefix(Self.segmentLength))))
                rest = rest.dropFirst(Self.segmentLength)
                number = nil
            } while !rest.isEmpty
            if !continuing { nextNumber += 1 }
        }
        continuesLine = !isLast && !endsOnLineBreak
        lines += added
    }

    private func fullText() async -> String? {
        try? await BoardTaskManager(modelContext: modelContext).rawInputText(
            taskID, turnID: turnID, homes: .forThisApp, agent: agent, item: item, offset: 0, length: Int.max
        ).text
    }

    private func copyAll() async {
        guard let text = await fullText() else { return }
        Platform.services.copyToClipboard(text)
    }

    private func openInEditor() async {
        guard let text = await fullText() else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("playhouse-raw-input-\(item).txt")
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        Platform.services.open(file)
    }
}

/// A pop-up picker with its title beside it, the way a macOS `Picker` shows
/// one, in a fixed width the pop-up stretches to fill.
private struct LabeledMenuPicker: PHView {
    let title: String
    let options: [SegmentedProps.Option]
    let selected: String
    let testID: String
    let width: Double
    let onChange: (String) -> Void
    /// What the title leaves the pop-up, measured once it lays out.
    @PHState private var menuWidth: Double?

    var body: some PHView {
        AtomStack(props: StackProps(axis: "h"), common: AtomCommon(width: width)) {
            AtomText(props: TextProps(text: title), common: AtomCommon(decorative: true))
            AtomStack(common: AtomCommon(fillWidth: true)) {
                AtomSegmented(
                    props: SegmentedProps(options: options, selected: selected, style: "menu"),
                    common: AtomCommon(testID: testID, label: title, width: menuWidth),
                    onChange: onChange
                )
            }
            .onGeometryChange(for: Double.self, of: { Double($0.size.width) }, action: { menuWidth = $0 })
        }
    }

    init(title: String, options: [SegmentedProps.Option], selected: String, testID: String, width: Double, onChange: @escaping (String) -> Void) {
        self.title = title
        self.options = options
        self.selected = selected
        self.testID = testID
        self.width = width
        self.onChange = onChange
    }
}
