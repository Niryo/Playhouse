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
        PHVStack(alignment: .leading, spacing: 12) {
            PHHStack(alignment: .firstTextBaseline) {
                PHVStack(alignment: .leading, spacing: 4) {
                    PHText("Raw input")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                    PHText(taskTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                PHSpacer()
                if let page {
                    PHVStack(alignment: .trailing, spacing: 2) {
                        PHText("\(page.total) \(page.total == 1 ? "item" : "items") · \(page.totalTokens.formatted(Self.number)) tokens")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("raw-input-summary")
                        PHText("\(rows.count) of \(page.total) loaded")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .accessibilityIdentifier("raw-input-loaded-rows")
                    }
                }
            }
            controls
            if scope == .request, let request = page?.request {
                requestBar(request)
            }
            PHHStack(alignment: .top, spacing: 0) {
                list
                    .frame(width: min(460, Self.size.width * 0.42))
                PHDivider()
                PHGroup {
                    if let selected {
                        RawInputTextPane(taskID: taskID, turnID: turnID, modelContext: modelContext, agent: page?.agent ?? agent, item: selected)
                            .id("\(page?.agent ?? agent ?? "")#\(selected)")
                    } else {
                        PHText("Select an item to read the full text the model received.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("raw-input-no-selection")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            PHHStack {
                PHSpacer()
                PHButton("Done") { dismiss() }
                    .buttonHoverPointer()
                    .shortcutHelp("Done", shortcut: "default")
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("close-raw-input-button")
            }
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height)
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
        PHHStack(spacing: 10) {
            if let page, page.agents.count > 1 {
                PHPicker("Agent", selection: PHBinding(get: { agent ?? page.agent ?? "" }, set: { agent = $0 })) {
                    PHForEach(page.agents) { PHText($0.label).tag($0.id) }
                }
                .buttonHoverPointer()
                .frame(width: 240)
                .accessibilityIdentifier("raw-input-agent-picker")
            }
            ChoiceBar(
                choices: [
                    (TaskRawInputScope.finalTranscript, "Final transcript", "raw-input-scope-final"),
                    (TaskRawInputScope.everything, "Everything sent", "raw-input-scope-all"),
                    (TaskRawInputScope.request, "Single request", "raw-input-scope-request"),
                ],
                selection: $scope
            )
            PHPicker("Order", selection: $order) {
                PHText("Transcript order").tag(TaskRawInputOrder.transcript)
                PHText("Largest first").tag(TaskRawInputOrder.size)
                PHText("Most tokens carried").tag(TaskRawInputOrder.rent)
            }
            .buttonHoverPointer()
            .frame(width: 220)
            .accessibilityIdentifier("raw-input-order-picker")
            PHTextField("Search the full text", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submittedQuery = query }
                .accessibilityIdentifier("raw-input-search-field")
        }
    }

    private var list: some PHView {
        PHScrollViewReader { proxy in
            PHScrollView {
                PHLazyVStack(alignment: .leading, spacing: 2) {
                    PHForEach(rows, id: \.listKey) { row in
                        RawInputRowView(
                            row: row, maxTokens: page?.maxTokens ?? 0,
                            isSelected: row.position.map { $0 == selectedPosition } ?? (row.id == selected)
                        )
                        .id(row.listKey)
                        .contentShape(PHRectangle())
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
                        PHProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .accessibilityIdentifier("raw-input-loading-more")
                    } else if page != nil, rows.isEmpty {
                        PHText(submittedQuery.isEmpty ? "Nothing was sent yet." : "No item contains “\(submittedQuery)”.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .accessibilityIdentifier("raw-input-empty")
                    }
                }
                .padding(.trailing, 8)
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
        PHVStack(alignment: .leading, spacing: 4) {
            PHHStack(spacing: 8) {
                PHButton("Previous request", icon: .chevronLeft) { requestNumber = request.number - 1 }
                    .labelStyle(.iconOnly)
                    .buttonHoverPointer()
                    .nativeHelp("Show the request before this one")
                    .disabled(request.number <= 1)
                    .accessibilityIdentifier("raw-input-request-previous")
                PHText("Request \(request.number) of \(request.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .accessibilityIdentifier("raw-input-request-number")
                PHButton("Next request", icon: .chevronRight) { requestNumber = request.number + 1 }
                    .labelStyle(.iconOnly)
                    .buttonHoverPointer()
                    .nativeHelp("Show the request after this one")
                    .disabled(request.number >= request.count)
                    .accessibilityIdentifier("raw-input-request-next")
                PHTextField("Go to #", text: $requestField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit {
                        if let number = Int(requestField.trimmingCharacters(in: .whitespaces)) {
                            requestNumber = min(max(1, number), request.count)
                        }
                        requestField = ""
                    }
                    .accessibilityIdentifier("raw-input-request-field")
                PHButton("Latest") { requestNumber = nil }
                    .buttonHoverPointer()
                    .nativeHelp("Show the request the final transcript was read from")
                    .controlSize(.small)
                    .disabled(request.number == request.latest)
                    .accessibilityIdentifier("raw-input-request-latest")
                PHText(request.exact ? "Exact" : "Reconstructed")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(request.exact ? PHColor.green : PHColor.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(PHCapsule().fill((request.exact ? PHColor.green : PHColor.orange).opacity(0.15)))
                    .nativeHelp(request.note)
                    .accessibilityIdentifier("raw-input-request-exactness")
                if let timestamp = request.timestamp {
                    PHText(Self.displayTime(timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("raw-input-request-time")
                }
                PHSpacer(minLength: 8)
                ChoiceBar(
                    choices: [
                        (TaskRawInputExportFormat.text, "Text", "raw-input-export-format-text"),
                        (TaskRawInputExportFormat.json, "JSON", "raw-input-export-format-json"),
                    ],
                    selection: $exportFormat
                )
                PHButton("Copy all", icon: .docOnDoc) { Task { await exportRequest(request, open: false) } }
                    .buttonHoverPointer()
                    .nativeHelp("Copy this whole request, every item in order")
                    .controlSize(.small)
                    .accessibilityIdentifier("raw-input-request-copy-button")
                PHButton("Open in editor", icon: .squareAndPencil) { Task { await exportRequest(request, open: true) } }
                    .buttonHoverPointer()
                    .nativeHelp("Write this whole request to a file and open it")
                    .controlSize(.small)
                    .accessibilityIdentifier("raw-input-request-open-editor-button")
            }
            // The bar keeps one height whatever it shows: a bar that grows
            // resizes the lazy list below it while it lays out its rows.
            PHHStack(spacing: 8) {
                PHText(Self.usageLine(request))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityIdentifier("raw-input-request-usage")
                PHSpacer(minLength: 8)
                PHText(exportStatus ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("raw-input-request-export-status")
            }
            PHText("\(request.note) \(request.tokenNote)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(2, reservesSpace: true)
                .nativeHelp("\(request.note) \(request.tokenNote)")
                .accessibilityIdentifier("raw-input-request-note")
        }
        .padding(8)
        .background(PHRoundedRectangle(cornerRadius: 7).fill(PHColor.primary.opacity(0.04)))
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
        PHVStack(alignment: .leading, spacing: 3) {
            PHHStack(spacing: 6) {
                PHText(contextKindName(row.kind))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(PHCapsule().fill(PHColor.primary.opacity(0.07)))
                if let position = row.position {
                    PHText("#\(position + 1)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                PHText(row.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .accessibilityIdentifier("\(row.accessibilityID)-label")
                if !row.inFinalTranscript {
                    PHText("removed")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
                PHSpacer(minLength: 6)
                PHText("×\(row.requests)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                PHText(row.tokens.formatted(Self.number))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .accessibilityIdentifier("\(row.accessibilityID)-tokens")
            }
            PHHStack(spacing: 6) {
                TokenShareBar(bar: TokenStatsModel.bar(row.tokens, largest: maxTokens))
                PHText(row.preview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Every row of a single request keeps this line, flagged or not: rows
            // of one height keep the lazy list's placement from oscillating.
            if row.position != nil {
                if let repeated = row.repeated {
                    PHText("Duplicate \(repeated.copy) of \(repeated.copies)\(repeated.copy > 1 ? " · first at #\(repeated.first + 1)" : "")")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(PHColor.red)
                        .lineLimit(1)
                        .accessibilityIdentifier("\(row.accessibilityID)-repeat")
                } else {
                    PHText(" ")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(PHRoundedRectangle(cornerRadius: 6).fill(background))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(row.accessibilityID)
    }

    private var background: PHColor {
        if isSelected { return PHColor.accentColor.opacity(0.18) }
        return row.repeated == nil ? .clear : PHColor.red.opacity(0.08)
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
        PHVStack(alignment: .leading, spacing: 8) {
            if let header {
                PHHStack(alignment: .firstTextBaseline, spacing: 8) {
                    PHText(header.label)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .accessibilityIdentifier("raw-input-text-label")
                    PHText(contextKindName(header.kind))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    PHSpacer()
                    PHButton("Copy all", icon: .docOnDoc) { Task { await copyAll() } }
                        .buttonHoverPointer()
                        .nativeHelp("Copy this item's full text")
                        .controlSize(.small)
                        .accessibilityIdentifier("raw-input-copy-button")
                    PHButton("Open in editor", icon: .squareAndPencil) { Task { await openInEditor() } }
                        .buttonHoverPointer()
                        .nativeHelp("Write this item's full text to a file and open it")
                        .controlSize(.small)
                        .accessibilityIdentifier("raw-input-open-editor-button")
                }
                PHText("\(header.tokens.formatted(Self.number)) tokens · carried in \(header.requests) \(header.requests == 1 ? "request" : "requests") · \(header.totalLength.formatted(Self.number)) characters")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("raw-input-text-size")
                PHText("\(loadedLength.formatted(Self.number)) of \(header.totalLength.formatted(Self.number)) characters loaded")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("raw-input-text-loaded")
                if let call = header.call {
                    PHText("Called as \(call)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("raw-input-text-call")
                }
                PHDivider()
            } else if let failure {
                PHText(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("raw-input-text-failure")
            }
            PHScrollView {
                PHLazyVStack(alignment: .leading, spacing: 0) {
                    PHForEach(lines) { line in
                        PHHStack(alignment: .top, spacing: 10) {
                            PHText(line.number.map(String.init) ?? "")
                                .foregroundStyle(.tertiary)
                                .frame(width: 52, alignment: .trailing)
                            PHText(line.text.isEmpty ? " " : line.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(line.number.map { "raw-input-text-line-\($0)" } ?? "")
                        .onAppear {
                            if line.id == lines.last?.id { Task { await loadNextChunk() } }
                        }
                    }
                }
                .padding(.trailing, 8)
                .hoverRevealScrollers()
            }
            .accessibilityIdentifier("raw-input-text")
        }
        .padding(.leading, 12)
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
