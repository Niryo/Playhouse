import AppKit
import SwiftData
import SwiftUI

private extension ProviderSessionHomes {
    static var forThisApp: ProviderSessionHomes {
        let configuration = DaemonClient.Configuration.fromEnvironment()
        return .resolve(claudeConfigDirectory: configuration.claudeConfigDirectory, codexHome: configuration.codexHome)
    }
}

/// What the raw input sheet opens on: one agent's item, or the start of its transcript.
struct RawInputFocus: Identifiable {
    let id = UUID()
    let agent: String?
    let item: Int?
    let inFinalTranscript: Bool
}

/// The `ChoiceBar` atom over a string-backed choice, so the raw input sheet's
/// scope and export bars share the Token Stats section bar's view.
private struct ChoiceBar<Choice: RawRepresentable & Hashable>: View where Choice.RawValue == String {
    let choices: [(value: Choice, title: String, id: String)]
    @Binding var selection: Choice

    var body: some View {
        AtomChoiceBar(
            props: ChoiceBarProps(options: choices.map { .init(value: $0.value.rawValue, label: $0.title, testID: $0.id) }, selected: selection.rawValue)
        ) { value in
            if let choice = Choice(rawValue: value) { selection = choice }
        }
    }
}

/// The board's Token Stats modal: a task's token accounting, re-read every
/// two seconds while it is open, around the atom-built `TokenStatsView`. It
/// holds the selected section and opens the raw input sheet.
struct TokenStatsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    let taskTitle: String
    let modelContext: ModelContext
    @State private var summary: TaskTokenUsageSummary?
    @State private var waste: TaskTokenWasteReport?
    @State private var didLoad = false
    @State private var section = "overview"
    @State private var rawInputFocus: RawInputFocus?

    var body: some View {
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
            while !Task.isCancelled {
                let manager = BoardTaskManager(modelContext: modelContext)
                summary = try? manager.tokenUsageSummary(taskID)
                waste = try? await manager.tokenWasteReport(taskID, homes: .forThisApp)
                didLoad = true
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(item: $rawInputFocus) { focus in
            RawInputSheet(taskID: taskID, taskTitle: taskTitle, modelContext: modelContext, focus: focus)
        }
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
struct RawInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    let taskTitle: String
    let modelContext: ModelContext
    let focus: RawInputFocus
    @State private var agent: String?
    @State private var scope: TaskRawInputScope
    @State private var order = TaskRawInputOrder.transcript
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var page: TaskRawInputPage?
    @State private var rows: [TaskRawInputPage.Row] = []
    @State private var isLoading = false
    @State private var selected: Int?
    /// In a single request, which copy of the selected item is highlighted.
    @State private var selectedPosition: Int?
    @State private var scrollTarget: Int?
    /// `nil` is the request the final transcript was read from.
    @State private var requestNumber: Int?
    @State private var requestField = ""
    @State private var exportFormat = TaskRawInputExportFormat.text
    @State private var exportStatus: String?

    private static let pageSize = 100
    private static let number = IntegerFormatStyle<Int>().grouping(.automatic)

    /// Wide enough for the list beside the text, but never wider or taller than the screen.
    private static var size: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        return CGSize(width: min(1120, max(800, visible.width - 60)), height: min(720, max(480, visible.height - 80)))
    }

    init(taskID: UUID, taskTitle: String, modelContext: ModelContext, focus: RawInputFocus) {
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.modelContext = modelContext
        self.focus = focus
        _agent = State(initialValue: focus.agent)
        _scope = State(initialValue: focus.inFinalTranscript ? .finalTranscript : .everything)
        _selected = State(initialValue: focus.item)
    }

    private var hasMore: Bool { rows.count < (page?.total ?? 0) }
    private var reloadKey: String {
        "\(agent ?? "")|\(scope.rawValue)|\(order.rawValue)|\(submittedQuery)|\(scope == .request ? requestNumber ?? 0 : 0)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Raw input")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text(taskTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let page {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(page.total) \(page.total == 1 ? "item" : "items") · \(page.totalTokens.formatted(Self.number)) tokens")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("raw-input-summary")
                        Text("\(rows.count) of \(page.total) loaded")
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
            HStack(alignment: .top, spacing: 0) {
                list
                    .frame(width: min(460, Self.size.width * 0.42))
                Divider()
                Group {
                    if let selected {
                        RawInputTextPane(taskID: taskID, modelContext: modelContext, agent: page?.agent ?? agent, item: selected)
                            .id("\(page?.agent ?? agent ?? "")#\(selected)")
                    } else {
                        Text("Select an item to read the full text the model received.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("raw-input-no-selection")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
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

    private var controls: some View {
        HStack(spacing: 10) {
            if let page, page.agents.count > 1 {
                Picker("Agent", selection: Binding(get: { agent ?? page.agent ?? "" }, set: { agent = $0 })) {
                    ForEach(page.agents) { Text($0.label).tag($0.id) }
                }
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
            Picker("Order", selection: $order) {
                Text("Transcript order").tag(TaskRawInputOrder.transcript)
                Text("Largest first").tag(TaskRawInputOrder.size)
                Text("Most tokens carried").tag(TaskRawInputOrder.rent)
            }
            .frame(width: 220)
            .accessibilityIdentifier("raw-input-order-picker")
            TextField("Search the full text", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submittedQuery = query }
                .accessibilityIdentifier("raw-input-search-field")
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows, id: \.listKey) { row in
                        RawInputRowView(
                            row: row, maxTokens: page?.maxTokens ?? 0,
                            isSelected: row.position.map { $0 == selectedPosition } ?? (row.id == selected)
                        )
                        .id(row.listKey)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selected = row.id
                            selectedPosition = row.position
                        }
                        .onAppear {
                            if row.listKey == rows.last?.listKey { Task { await loadMore() } }
                        }
                    }
                    if hasMore {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .accessibilityIdentifier("raw-input-loading-more")
                    } else if page != nil, rows.isEmpty {
                        Text(submittedQuery.isEmpty ? "Nothing was sent yet." : "No item contains “\(submittedQuery)”.")
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
            taskID, homes: .forThisApp, agent: agent, scope: scope, order: order, query: submittedQuery,
            offset: offset, limit: Self.pageSize, focus: item, request: scope == .request ? requestNumber : nil
        )
    }

    /// Which request is shown, how the provider measured it, how exact the
    /// rebuild is, and the whole request's export.
    private func requestBar(_ request: TaskRawInputPage.Request) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button("Previous request", systemImage: "chevron.left") { requestNumber = request.number - 1 }
                    .labelStyle(.iconOnly)
                    .buttonHoverPointer()
                    .nativeHelp("Show the request before this one")
                    .disabled(request.number <= 1)
                    .accessibilityIdentifier("raw-input-request-previous")
                Text("Request \(request.number) of \(request.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .accessibilityIdentifier("raw-input-request-number")
                Button("Next request", systemImage: "chevron.right") { requestNumber = request.number + 1 }
                    .labelStyle(.iconOnly)
                    .buttonHoverPointer()
                    .nativeHelp("Show the request after this one")
                    .disabled(request.number >= request.count)
                    .accessibilityIdentifier("raw-input-request-next")
                TextField("Go to #", text: $requestField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit {
                        if let number = Int(requestField.trimmingCharacters(in: .whitespaces)) {
                            requestNumber = min(max(1, number), request.count)
                        }
                        requestField = ""
                    }
                    .accessibilityIdentifier("raw-input-request-field")
                Button("Latest") { requestNumber = nil }
                    .buttonHoverPointer()
                    .nativeHelp("Show the request the final transcript was read from")
                    .controlSize(.small)
                    .disabled(request.number == request.latest)
                    .accessibilityIdentifier("raw-input-request-latest")
                Text(request.exact ? "Exact" : "Reconstructed")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(request.exact ? Color.green : Color.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill((request.exact ? Color.green : Color.orange).opacity(0.15)))
                    .nativeHelp(request.note)
                    .accessibilityIdentifier("raw-input-request-exactness")
                if let timestamp = request.timestamp {
                    Text(Self.displayTime(timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("raw-input-request-time")
                }
                Spacer(minLength: 8)
                ChoiceBar(
                    choices: [
                        (TaskRawInputExportFormat.text, "Text", "raw-input-export-format-text"),
                        (TaskRawInputExportFormat.json, "JSON", "raw-input-export-format-json"),
                    ],
                    selection: $exportFormat
                )
                Button("Copy all", systemImage: "doc.on.doc") { Task { await exportRequest(request, open: false) } }
                    .buttonHoverPointer()
                    .nativeHelp("Copy this whole request, every item in order")
                    .controlSize(.small)
                    .accessibilityIdentifier("raw-input-request-copy-button")
                Button("Open in editor", systemImage: "square.and.pencil") { Task { await exportRequest(request, open: true) } }
                    .buttonHoverPointer()
                    .nativeHelp("Write this whole request to a file and open it")
                    .controlSize(.small)
                    .accessibilityIdentifier("raw-input-request-open-editor-button")
            }
            // The bar keeps one height whatever it shows: a bar that grows
            // resizes the lazy list below it while it lays out its rows.
            HStack(spacing: 8) {
                Text(Self.usageLine(request))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityIdentifier("raw-input-request-usage")
                Spacer(minLength: 8)
                Text(exportStatus ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("raw-input-request-export-status")
            }
            Text("\(request.note) \(request.tokenNote)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(2, reservesSpace: true)
                .nativeHelp("\(request.note) \(request.tokenNote)")
                .accessibilityIdentifier("raw-input-request-note")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
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
                taskID, homes: .forThisApp, agent: page?.agent ?? agent, request: request.number, format: format
            )
            let name = format == .json ? "JSON" : "text"
            if open {
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("playhouse-request-\(taskID.uuidString.prefix(8))-\(export.agent.replacingOccurrences(of: "/", with: "-"))-\(export.request).\(format == .json ? "json" : "txt")")
                try export.text.write(to: file, atomically: true, encoding: .utf8)
                NSWorkspace.shared.open(file)
                exportStatus = "Opened request \(export.request) as \(name): \(export.items) items"
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(export.text, forType: .string)
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

private struct RawInputRowView: View {
    let row: TaskRawInputPage.Row
    let maxTokens: Int
    let isSelected: Bool

    private static let number = IntegerFormatStyle<Int>().grouping(.automatic)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(contextKindName(row.kind))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                if let position = row.position {
                    Text("#\(position + 1)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Text(row.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .accessibilityIdentifier("\(row.accessibilityID)-label")
                if !row.inFinalTranscript {
                    Text("removed")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 6)
                Text("×\(row.requests)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(row.tokens.formatted(Self.number))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .accessibilityIdentifier("\(row.accessibilityID)-tokens")
            }
            HStack(spacing: 6) {
                TokenShareBar(bar: TokenStatsModel.bar(row.tokens, largest: maxTokens))
                Text(row.preview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Every row of a single request keeps this line, flagged or not: rows
            // of one height keep the lazy list's placement from oscillating.
            if row.position != nil {
                if let repeated = row.repeated {
                    Text("Duplicate \(repeated.copy) of \(repeated.copies)\(repeated.copy > 1 ? " · first at #\(repeated.first + 1)" : "")")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.red)
                        .lineLimit(1)
                        .accessibilityIdentifier("\(row.accessibilityID)-repeat")
                } else {
                    Text(" ")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(background))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(row.accessibilityID)
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        return row.repeated == nil ? .clear : Color.red.opacity(0.08)
    }
}

/// One item's full text, line-numbered, read from the session file a chunk at
/// a time as it scrolls; a chunk always ends on a line break.
private struct RawInputTextPane: View {
    private struct Line: Identifiable {
        let id: Int
        let number: Int?
        let text: String
    }

    let taskID: UUID
    let modelContext: ModelContext
    let agent: String?
    let item: Int
    @State private var header: TaskRawInputText?
    @State private var lines: [Line] = []
    @State private var nextOffset: Int? = 0
    @State private var nextNumber = 1
    /// A chunk with no line break in its second half ends mid-line; the next one continues that line.
    @State private var continuesLine = false
    @State private var loadedLength = 0
    @State private var isLoading = false
    @State private var failure: String?

    private static let number = IntegerFormatStyle<Int>().grouping(.automatic)
    /// A very long line (minified JSON, a base64 blob) wraps across rows of this many characters.
    private static let segmentLength = 2_000

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(header.label)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .accessibilityIdentifier("raw-input-text-label")
                    Text(contextKindName(header.kind))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Copy all", systemImage: "doc.on.doc") { Task { await copyAll() } }
                        .buttonHoverPointer()
                        .nativeHelp("Copy this item's full text")
                        .controlSize(.small)
                        .accessibilityIdentifier("raw-input-copy-button")
                    Button("Open in editor", systemImage: "square.and.pencil") { Task { await openInEditor() } }
                        .buttonHoverPointer()
                        .nativeHelp("Write this item's full text to a file and open it")
                        .controlSize(.small)
                        .accessibilityIdentifier("raw-input-open-editor-button")
                }
                Text("\(header.tokens.formatted(Self.number)) tokens · carried in \(header.requests) \(header.requests == 1 ? "request" : "requests") · \(header.totalLength.formatted(Self.number)) characters")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("raw-input-text-size")
                Text("\(loadedLength.formatted(Self.number)) of \(header.totalLength.formatted(Self.number)) characters loaded")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("raw-input-text-loaded")
                if let call = header.call {
                    Text("Called as \(call)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("raw-input-text-call")
                }
                Divider()
            } else if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("raw-input-text-failure")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 10) {
                            Text(line.number.map(String.init) ?? "")
                                .foregroundStyle(.tertiary)
                                .frame(width: 52, alignment: .trailing)
                            Text(line.text.isEmpty ? " " : line.text)
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
                taskID, homes: .forThisApp, agent: agent, item: item, offset: offset, length: ProviderTokenMap.defaultTextChunk
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
            taskID, homes: .forThisApp, agent: agent, item: item, offset: 0, length: Int.max
        ).text
    }

    private func copyAll() async {
        guard let text = await fullText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openInEditor() async {
        guard let text = await fullText() else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("playhouse-raw-input-\(item).txt")
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        NSWorkspace.shared.open(file)
    }
}
