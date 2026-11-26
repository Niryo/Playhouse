import AppKit
import OSLog
import QuartzCore
import SwiftUI

#if PLAYHOUSE_ATOM_BENCHMARK
/// The atom-tree spike's transcript prototype and benchmark (docs/atom-tree-performance.md), run
/// by `scripts/benchmark-transcript-tree.sh`. Test code only: the app's transcript stays native,
/// and this is compiled only into PLAYHOUSE_ATOM_BENCHMARK builds and runs only when
/// `PLAYHOUSE_TRANSCRIPT_TREE_BENCHMARK` names a JSON file to write.
///
/// It renders one transcript (user prompts, Markdown replies with code blocks, lists and tables,
/// and collapsible tool-call rows) in one of five ways (`_VARIANT`):
/// - `native`: hand-written SwiftUI: the transcript's reply body (`AtomMarkdown` with its native
///   `MarkdownTextHost`), its user bubble (`SelectableAnnotationText`) and its `ToolCallTimelineRow`;
/// - `tree`: each message an atom tree with typed props (Stack, Markdown, Text, Button, Icon,
///   Divider) under one lazy Scroll atom, one reconciler per message, so a streaming update
///   rebuilds and reconciles only the last message;
/// - `tree-dynamic`: the same trees sent as plugin-style ops (dictionary props, validated and
///   decoded once per op);
/// - `tree-full`: the naive composite: the whole transcript one spec, rebuilt from the model and
///   reconciled on every update, as a composite that is a pure function of its model would be;
/// - `tree-blocks`: like `tree`, but each reply split into one Markdown atom per block, to show
///   how cost grows with node count.
/// Scenarios (`_SCENARIO`): `open-N` (open N items, jump to the bottom, scroll to the top and
/// back, expand and collapse tool calls, select text in a long reply) and `stream-N` (stream a
/// long reply into the end of N items for 60 seconds, 60 updates a second).
@MainActor
enum TranscriptTreeBenchmark {
    static let signposter = OSSignposter(subsystem: "Playhouse", category: "TranscriptTreeBenchmark")

    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["PLAYHOUSE_TRANSCRIPT_TREE_BENCHMARK"], !output.isEmpty else { return }
        let variant = Variant(rawValue: environment["PLAYHOUSE_TRANSCRIPT_TREE_BENCHMARK_VARIANT"] ?? "") ?? .native
        let scenario = environment["PLAYHOUSE_TRANSCRIPT_TREE_BENCHMARK_SCENARIO"] ?? "open-100"
        let runner = Runner(outputPath: output, variant: variant, scenario: scenario)
        Runner.current = runner
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { runner.start() }
    }

    enum Variant: String {
        case native, tree, treeDynamic = "tree-dynamic", treeFull = "tree-full", treeBlocks = "tree-blocks"
    }

    // MARK: Fixture

    enum Item {
        case user(id: String, text: String)
        case assistant(id: String, text: String)
        case tool(ConversationActivity)

        var id: String {
            switch self {
            case .user(let id, _), .assistant(let id, _): id
            case .tool(let activity): activity.id
            }
        }
    }

    @Observable
    final class ItemBox: Identifiable {
        let id: String
        let index: Int
        var item: Item
        init(_ item: Item, index: Int) {
            id = item.id
            self.index = index
            self.item = item
        }
    }

    @Observable
    final class Model {
        var boxes: [ItemBox]
        init(items: [Item]) { boxes = items.enumerated().map { ItemBox($1, index: $0) } }
    }

    /// `count` items, five a turn: the prompt, a shell call, the reply, a file read, a short
    /// follow-up. The reply in the middle turn is a 24,000-character one (for selection).
    static func fixture(count: Int) -> [Item] {
        var items: [Item] = []
        let middleTurn = count / 10
        var turn = 0
        while items.count < count {
            let base = "t\(turn)"
            let turnItems: [Item] = [
                .user(id: "\(base)-u", text: "Turn \(turn): please look at the failing case and explain what changed since the last run."),
                .tool(ConversationActivity(id: "\(base)-bash", title: "Bash", detail: "", status: "completed", toolKind: "commandExecution", tool: "Bash",
                                           summary: "Run the focused case",
                                           input: "cd ~/git/Playhouse\nscripts/test-e2e.sh --case case-\(turn % 40)\ngit status --short",
                                           output: (0..<12).map { "line \($0) of the output for turn \(turn): PASS case-\(turn % 40) step \($0)" }.joined(separator: "\n"))),
                .assistant(id: "\(base)-a", text: turn == middleTurn ? TranscriptBenchmark.longReply(turn) : TranscriptBenchmark.reply(turn)),
                .tool(ConversationActivity(id: "\(base)-read", title: "Read", detail: "", status: turn % 9 == 4 ? "failed" : "completed", toolKind: "fileRead", tool: "Read",
                                           summary: "Playhouse/App/TranscriptLayout.swift",
                                           input: "Playhouse/App/TranscriptLayout.swift (lines \(turn)–\(turn + 80))",
                                           output: (0..<6).map { "\(turn + $0)\tlet row\($0) = geometry.row(atOrAbove: y) // keeps the sample long" }.joined(separator: "\n"))),
                .assistant(id: "\(base)-f", text: TranscriptBenchmark.paragraph(turn)),
            ]
            items += turnItems.prefix(count - items.count)
            turn += 1
        }
        return items
    }

    /// The streamed reply, repeated past what 60 seconds of streaming needs.
    static let streamed: [Character] = Array(String(repeating: TranscriptBenchmark.streamedReply + "\n\n", count: 8))

    // MARK: Native

    struct NativeRow: View {
        let box: ItemBox
        let expansion: ToolCallExpansionState

        var body: some View {
            switch box.item {
            case .user(_, let text):
                HStack(spacing: 0) {
                    Spacer(minLength: 70)
                    SelectableAnnotationText(text: text, highlightedRanges: [], onSelection: { _, _, _ in })
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(WorkspaceTheme.inputBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(maxWidth: 620, alignment: .trailing)
                }
            case .assistant(let id, let text):
                HStack(spacing: 0) {
                    TranscriptBenchmark.replyBody(text, id: id)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(WorkspaceTheme.conversationText)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("assistant-message-\(id)")
                        .frame(maxWidth: 620, alignment: .leading)
                    Spacer(minLength: 70)
                }
            case .tool(let activity):
                ToolCallTimelineRow(activity: activity, expansion: expansion)
            }
        }
    }

    struct NativeTranscript: View {
        let model: Model
        let expansion: ToolCallExpansionState

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.boxes) { box in NativeRow(box: box, expansion: expansion) }
                }
                .padding(20)
                .hoverRevealScrollers()
            }
            .background(WorkspaceTheme.windowBackground)
        }
    }

    // MARK: Tree

    /// Node ids: message `index` owns `index * 1000 + 100 ..< (index + 1) * 1000 + 100`.
    static func base(_ index: Int) -> Int { index * 1000 + 100 }

    static func statusColor(_ status: String) -> String {
        switch status.lowercased() {
        case "completed": "green"
        case "failed": "red"
        case "interrupted", "stopped": "orange"
        default: "accent"
        }
    }

    /// Splits Markdown into blocks at blank lines outside code fences.
    static func blocks(_ markdown: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring] = []
        var inFence = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") { inFence.toggle() }
            if line.isEmpty, !inFence {
                if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
        return blocks
    }

    /// One item as atoms: what each native row draws, from the atoms there are.
    static func spec(_ box: ItemBox, expanded: Bool, splitBlocks: Bool) -> AtomNodeSpec {
        let id = base(box.index)
        switch box.item {
        case .user(_, let text):
            return AtomNodeSpec(id, StackProps(axis: "h", spacing: 0), children: [
                AtomNodeSpec(id + 1, SpacerProps(minLength: 70)),
                AtomNodeSpec(id + 2, StackProps(align: "leading", fill: "primary", fillOpacity: 0.06, cornerRadius: 10), AtomCommon(padding: 11, paddingX: 5), children: [
                    AtomNodeSpec(id + 3, MarkdownProps(text: text, size: 16, color: "text", selectable: true)),
                ]),
            ])
        case .assistant(let messageID, let text):
            let body: [AtomNodeSpec]
            if splitBlocks {
                body = [AtomNodeSpec(id + 3, StackProps(spacing: 12, align: "leading"), children: blocks(text).enumerated().map { offset, block in
                    AtomNodeSpec(id + 10 + offset, MarkdownProps(text: block, size: 16, color: "text", selectable: true))
                })]
            } else {
                body = [AtomNodeSpec(id + 3, MarkdownProps(text: text, size: 16, color: "text", selectable: true), AtomCommon(testID: "assistant-markdown-\(messageID)"))]
            }
            return AtomNodeSpec(id, StackProps(axis: "h", spacing: 0), children: [
                AtomNodeSpec(id + 2, StackProps(align: "leading", fill: "panel", cornerRadius: 17), AtomCommon(testID: "assistant-message-\(messageID)", padding: 11, paddingX: 4), children: body),
                AtomNodeSpec(id + 1, SpacerProps(minLength: 70)),
            ])
        case .tool(let activity):
            let isShell = activity.tool == "Bash"
            let showsDetails = !isShell || expanded
            let lines = (activity.input ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let preview = lines.first.map { lines.count > 1 ? "\($0) …" : $0 }
            var header = [AtomNodeSpec(id + 4, TextProps(text: activity.tool ?? activity.title, size: 14, weight: "semibold", color: "text"), AtomCommon(testID: "conversation-tool-call-name-\(activity.id)"))]
            if !showsDetails, let preview {
                header.append(AtomNodeSpec(id + 5, TextProps(text: preview, size: 12, design: "monospaced", color: "secondary", lineLimit: 1, truncation: "tail")))
            } else if let summary = activity.summary {
                header.append(AtomNodeSpec(id + 5, TextProps(text: summary, size: 14, color: "secondary", lineLimit: 1, truncation: "middle")))
            }
            header.append(AtomNodeSpec(id + 6, SpacerProps(minLength: 0)))
            header.append(AtomNodeSpec(id + 7, ButtonProps(style: "plain"), AtomCommon(testID: "conversation-tool-call-toggle-\(activity.id)", label: expanded ? "Show less" : "Show full input and output", width: 20, height: 20),
                                       events: ["onPress"], children: [
                                           AtomNodeSpec(id + 8, IconProps(name: expanded ? "chevron.up" : "chevron.down", size: 11, weight: "semibold", color: "secondary")),
                                       ]))
            var column = [AtomNodeSpec(id + 3, StackProps(axis: "h", spacing: 8, align: "baseline"), children: header)]
            if showsDetails {
                func io(_ offset: Int, _ label: String, _ text: String) -> AtomNodeSpec {
                    AtomNodeSpec(id + offset, StackProps(axis: "h", spacing: 12, align: "baseline"), AtomCommon(padding: 8, paddingX: 4), children: [
                        AtomNodeSpec(id + offset + 1, TextProps(text: label, size: 11, weight: "medium", design: "monospaced", color: "secondary"), AtomCommon(width: 30)),
                        AtomNodeSpec(id + offset + 2, TextProps(text: text, size: 12, design: "monospaced", color: "text", lineLimit: expanded ? nil : 3, truncation: "tail"), AtomCommon(fillWidth: true)),
                    ])
                }
                var details: [AtomNodeSpec] = []
                if let input = activity.input { details.append(io(20, "IN", input)) }
                if activity.input != nil, activity.output != nil { details.append(AtomNodeSpec(id + 30, DividerProps())) }
                if let output = activity.output { details.append(io(40, "OUT", output)) }
                column.append(AtomNodeSpec(id + 9, StackProps(spacing: 0, align: "leading", fill: "primary", fillOpacity: 0.05, cornerRadius: 8, stroke: "primary", strokeOpacity: 0.08), children: details))
            }
            return AtomNodeSpec(id, StackProps(axis: "h", spacing: 10, align: "top"), AtomCommon(testID: "conversation-tool-call-\(activity.id)", fillWidth: true, paddingY: 2), children: [
                AtomNodeSpec(id + 1, StackProps(fill: statusColor(activity.status), capsule: true), AtomCommon(width: 7, height: 7)),
                AtomNodeSpec(id + 2, StackProps(spacing: 8, align: "leading"), children: column),
            ])
        }
    }

    /// Keeps the transcript's atom trees in step with the model.
    @MainActor
    final class TreeHost {
        let variant: Variant
        let handlers = AtomEventHandlers()
        let model: Model
        var expanded: Set<String> = []
        private var typed: [TypedAtomTree] = []
        private var dynamic: [DynamicAtomTree] = []
        private var full: TypedAtomTree?
        /// The lazy Scroll every message's root is a child of (in `tree-full`, `full`'s root).
        private(set) var scroll: PluginNode
        var specMs: [Double] = []
        var reconcileMs: [Double] = []

        static let scrollProps = ScrollProps(spacing: 18, inset: 20, lazy: true)

        init(model: Model, variant: Variant) {
            self.model = model
            self.variant = variant
            scroll = PluginNode(id: 1, props: Self.scrollProps)
            if variant == .treeFull {
                full = TypedAtomTree(handlers: handlers)
                full?.onEvent = { [weak self] id, _, _ in self?.toggle(nodeID: id) }
                rebuildFull()
            } else {
                for box in model.boxes { add(box) }
                scroll.children = roots
            }
        }

        private var roots: [PluginNode] {
            variant == .treeDynamic ? dynamic.compactMap(\.root) : typed.compactMap(\.root)
        }

        var nodeCount: Int { Self.count(scroll) }

        /// The text the last item's Markdown node holds, and whether its tree is shown, for checks.
        var lastMarkdown: (characters: Int, shown: Bool) {
            func find(_ node: PluginNode) -> PluginNode? {
                if node.type == AtomType.markdown.rawValue { return node }
                for child in node.children { if let found = find(child) { return found } }
                return nil
            }
            guard let last = scroll.children.last, let markdown = find(last), case .success(let resolved) = markdown.resolved else { return (0, false) }
            let shown = roots.last.map { root in scroll.children.contains { $0 === root } } ?? true
            return ((resolved.atom as? MarkdownProps)?.text?.count ?? 0, shown)
        }
        static func count(_ node: PluginNode) -> Int { 1 + node.children.reduce(0) { $0 + count($1) } }

        private func spec(_ box: ItemBox) -> AtomNodeSpec {
            Self.timed(&specMs) { TranscriptTreeBenchmark.spec(box, expanded: expanded.contains(box.id), splitBlocks: variant == .treeBlocks) }
        }

        private func add(_ box: ItemBox) {
            let spec = spec(box)
            if variant == .treeDynamic {
                let tree = DynamicAtomTree(handlers: handlers)
                tree.onEvent = { [weak self] id, _, _ in self?.toggle(nodeID: id) }
                Self.timed(&reconcileMs) { do { try tree.apply(spec) } catch { assertionFailure("\(error)") } }
                dynamic.append(tree)
            } else {
                let tree = TypedAtomTree(handlers: handlers)
                tree.onEvent = { [weak self] id, _, _ in self?.toggle(nodeID: id) }
                Self.timed(&reconcileMs) { tree.apply(spec) }
                typed.append(tree)
            }
        }

        /// Items appended to the model since the trees were built.
        func appendNew() {
            if variant == .treeFull { return rebuildFull() }
            for box in model.boxes.dropFirst(roots.count) { add(box) }
            scroll.children = roots
        }

        /// Item `index` changed.
        func update(_ index: Int) {
            if variant == .treeFull { return rebuildFull() }
            let spec = spec(model.boxes[index])
            if variant == .treeDynamic {
                Self.timed(&reconcileMs) { do { try dynamic[index].apply(spec) } catch { assertionFailure("\(error)") } }
            } else {
                Self.timed(&reconcileMs) { typed[index].apply(spec) }
            }
        }

        /// The whole transcript as one spec, from the model, reconciled at once.
        private func rebuildFull() {
            let spec = Self.timed(&specMs) {
                AtomNodeSpec(1, Self.scrollProps, children: model.boxes.map { TranscriptTreeBenchmark.spec($0, expanded: expanded.contains($0.id), splitBlocks: false) })
            }
            Self.timed(&reconcileMs) { full?.apply(spec) }
            if let root = full?.root, root !== scroll { scroll = root }
        }

        func toggle(nodeID: Int) {
            let index = (nodeID - 100) / 1000
            guard model.boxes.indices.contains(index) else { return }
            let id = model.boxes[index].id
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            update(index)
        }

        static func timed<T>(_ into: inout [Double], _ work: () -> T) -> T {
            let start = CACurrentMediaTime()
            let result = work()
            into.append((CACurrentMediaTime() - start) * 1000)
            return result
        }
    }

    struct TreeTranscript: View {
        let host: TreeHost

        var body: some View {
            PluginNodeView(node: host.scroll, events: host.handlers)
                .background(WorkspaceTheme.windowBackground)
        }
    }

    // MARK: Running

    @MainActor
    final class Runner: NSObject {
        static var current: Runner?
        let outputPath: String
        let variant: Variant
        let scenario: String
        var results: [String: Any] = [:]
        let meter = AtomTreeBenchmark.BusyMeter()
        var window: NSWindow?
        var frameTimer: Timer?
        var onFrame: (() -> Void)?
        var model: Model!
        var host: TreeHost?
        let expansion = ToolCallExpansionState()

        init(outputPath: String, variant: Variant, scenario: String) {
            self.outputPath = outputPath
            self.variant = variant
            self.scenario = scenario
        }

        func frames(_ handler: @escaping () -> Void) {
            onFrame = handler
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFrame?() }
            }
            RunLoop.main.add(timer, forMode: .common)
            frameTimer = timer
        }

        func stopFrames() {
            frameTimer?.invalidate()
            frameTimer = nil
            onFrame = nil
        }

        func renderNow(_ view: NSView) {
            let state = TranscriptTreeBenchmark.signposter.beginInterval("render")
            view.layoutSubtreeIfNeeded()
            view.window?.displayIfNeeded()
            CATransaction.flush()
            TranscriptTreeBenchmark.signposter.endInterval("render", state)
        }

        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for subview in view.subviews { if let found = scrollView(in: subview) { return found } }
            return nil
        }

        func makeWindow(_ content: some View, title: String, size: NSSize = NSSize(width: 760, height: 900)) -> (NSWindow, NSView) {
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 60), size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = title
            let view = NSHostingView(rootView: content)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            return (window, view)
        }

        func start() {
            results["variant"] = variant.rawValue
            results["scenario"] = scenario
            let parts = scenario.split(separator: "-")
            guard parts.count == 2, let count = Int(parts[1]) else {
                results["error"] = "unknown scenario \(scenario)"
                return finish()
            }
            var items = TranscriptTreeBenchmark.fixture(count: count)
            if parts[0] == "stream" {
                items.append(.user(id: "stream-u", text: "Stream a long answer."))
                items.append(.assistant(id: "stream-a", text: ""))
            }
            let before = TaskItemBenchmark.footprintMB().current
            results["baselineFootprintMB"] = before
            results["fixture"] = ["items": items.count, "characters": items.reduce(0) { total, item in
                switch item {
                case .user(_, let text), .assistant(_, let text): total + text.count
                case .tool(let activity): total + (activity.input?.count ?? 0) + (activity.output?.count ?? 0)
                }
            }]
            let counts = TaskItemBenchmark.ViewCounts()
            let started = CACurrentMediaTime()
            let startedCPU = AtomTreeBenchmark.threadCPUms()
            let state = TranscriptTreeBenchmark.signposter.beginInterval("open transcript")
            model = Model(items: items)
            if variant != .native { host = TreeHost(model: model, variant: variant) }
            let built = CACurrentMediaTime()
            let (window, view): (NSWindow, NSView)
            if let host {
                (window, view) = makeWindow(TreeTranscript(host: host), title: "Transcript tree benchmark (\(variant.rawValue))")
            } else {
                (window, view) = makeWindow(NativeTranscript(model: model, expansion: expansion), title: "Transcript tree benchmark (native)")
            }
            renderNow(view)
            TranscriptTreeBenchmark.signposter.endInterval("open transcript", state)
            results["open"] = [
                "items": items.count,
                "nodes": host?.nodeCount ?? 0,
                "buildMs": (built - started) * 1000,
                "totalMs": (CACurrentMediaTime() - started) * 1000,
                "cpuMs": AtomTreeBenchmark.threadCPUms() - startedCPU,
                "footprintDeltaMB": TaskItemBenchmark.footprintMB().current - before,
                "decodes": counts.decodesSince,
                "nodeBodies": counts.bodiesSince,
                "atomViewBodies": counts.viewsSince,
            ]
            self.window = window
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.jumpToBottom(view) {
                    if parts[0] == "stream" {
                        self.stream(view)
                    } else {
                        self.scroll(view, up: true) { self.scroll(view, up: false) { self.toggles(view) } }
                    }
                }
            }
        }

        /// Scrolls to the end until the lazily measured document stops growing.
        func jumpToBottom(_ view: NSView, then: @escaping () -> Void) {
            guard let scroll = scrollView(in: view) else {
                results["error"] = "no scroll view"
                return finish()
            }
            let start = CACurrentMediaTime()
            var lastHeight: CGFloat = -1
            var frames = 0
            self.frames { [weak self] in
                guard let self else { return }
                let height = scroll.documentView?.frame.height ?? 0
                let maxY = max(0, height - scroll.contentView.bounds.height)
                if height == lastHeight, scroll.contentView.bounds.origin.y >= maxY - 0.5, frames > 2 {
                    self.stopFrames()
                    self.results["jumpToBottom"] = ["ms": (CACurrentMediaTime() - start) * 1000, "frames": frames, "documentHeight": height]
                    return then()
                }
                lastHeight = height
                frames += 1
                scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY))
                scroll.reflectScrolledClipView(scroll.contentView)
                self.renderNow(view)
            }
        }

        /// Scrolls to the top (or back to the bottom) in about 150 frames, as a fast scroll does.
        func scroll(_ view: NSView, up: Bool, then: @escaping () -> Void) {
            guard let scroll = scrollView(in: view) else { return finish() }
            var frameWork: [Double] = []
            let counts = TaskItemBenchmark.ViewCounts()
            _ = meter.take()
            let startedCPU = AtomTreeBenchmark.threadCPUms()
            let height = scroll.documentView?.frame.height ?? 0
            let step = max(240, height / 150)
            frames { [weak self] in
                guard let self else { return }
                let clip = scroll.contentView
                let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
                let done = up ? clip.bounds.origin.y <= 0.5 : clip.bounds.origin.y >= maxY - 0.5
                if (done && frameWork.count > 5) || frameWork.count >= 900 {
                    self.stopFrames()
                    var stats = TaskItemBenchmark.frameStats(frameWork)
                    stats["reachedEnd"] = done
                    stats["cpuMs"] = AtomTreeBenchmark.threadCPUms() - startedCPU
                    stats["mainThreadBusyMs"] = self.meter.take() * 1000
                    stats["atomViewBodies"] = counts.viewsSince
                    stats["nodeBodies"] = counts.bodiesSince
                    self.results[up ? "scrollUp" : "scrollDown"] = stats
                    self.results["afterScrollFootprintMB"] = TaskItemBenchmark.footprintMB().current
                    return then()
                }
                let start = CACurrentMediaTime()
                let target = up ? max(0, clip.bounds.origin.y - step) : min(maxY, clip.bounds.origin.y + step)
                clip.scroll(to: NSPoint(x: 0, y: target))
                scroll.reflectScrolledClipView(clip)
                self.renderNow(view)
                frameWork.append((CACurrentMediaTime() - start) * 1000)
            }
        }

        /// Expands and collapses the last ten tool calls, each change then its frame.
        func toggles(_ view: NSView) {
            let tools = model.boxes.filter { if case .tool = $0.item { true } else { false } }.suffix(10)
            var costs: [Double] = []
            for _ in 0..<2 {
                for box in tools {
                    let start = CACurrentMediaTime()
                    if let host {
                        host.toggle(nodeID: TranscriptTreeBenchmark.base(box.index) + 7)
                    } else if expansion.expandedIDs.contains(box.id) {
                        expansion.expandedIDs.remove(box.id)
                    } else {
                        expansion.expandedIDs.insert(box.id)
                    }
                    renderNow(view)
                    costs.append((CACurrentMediaTime() - start) * 1000)
                }
            }
            results["toggle"] = AtomTreeBenchmark.summary(costs)
            window?.close()
            window = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.selection() }
        }

        static func lettersAndDigits(_ text: String) -> String {
            String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        }

        func textViews(in view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
        }

        /// Selecting text in the long reply: select all in its longest prose run, then a drag
        /// selection grown 100 characters a frame, each change then its frame. The reply is shown on its own, so
        /// every variant selects in the same text.
        func selection() {
            guard let long = model.boxes.first(where: { if case .assistant(_, let text) = $0.item { text.count > 20_000 } else { false } }) else {
                results["selection"] = ["skipped": 1]
                return finish()
            }
            let single = Model(items: [long.item])
            let content: AnyView
            if variant == .native {
                content = AnyView(NativeTranscript(model: single, expansion: expansion))
            } else {
                content = AnyView(TreeTranscript(host: TreeHost(model: single, variant: variant == .treeFull ? .tree : variant)))
            }
            let (window, view) = makeWindow(content.frame(width: 760, height: 900), title: "Selection")
            self.window = window
            renderNow(view)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let texts = self.textViews(in: view).sorted { $0.string.count > $1.string.count }
                guard let text = texts.first else {
                    self.results["selection"] = ["error": "no text view"]
                    return self.finish()
                }
                window.makeFirstResponder(text)
                let start = CACurrentMediaTime()
                text.selectAll(nil)
                self.renderNow(view)
                let selectAll = (CACurrentMediaTime() - start) * 1000
                var steps: [Double] = []
                let length = (text.string as NSString).length
                for end in stride(from: 100, to: min(length, 100 * 60), by: 100) {
                    let stepStart = CACurrentMediaTime()
                    text.setSelectedRange(NSRange(location: 0, length: end))
                    self.renderNow(view)
                    steps.append((CACurrentMediaTime() - stepStart) * 1000)
                }
                self.results["selection"] = ["selectAllMs": selectAll, "step": AtomTreeBenchmark.summary(steps),
                                             "textViews": texts.count, "longestTextView": texts.first?.string.count ?? 0]
                self.finish()
            }
        }

        /// Streams into the last reply for 60 seconds, a few characters a frame (about 90
        /// tokens a second), following the bottom.
        func stream(_ view: NSView) {
            guard let scroll = scrollView(in: view) else { return finish() }
            let last = model.boxes.count - 1
            let chunk = 6
            var sent = 0
            var updateWork: [Double] = []
            var busy: [Double] = []
            let counts = TaskItemBenchmark.ViewCounts()
            host?.specMs = []
            host?.reconcileMs = []
            _ = meter.take()
            let startedCPU = AtomTreeBenchmark.threadCPUms()
            let started = CACurrentMediaTime()
            frames { [weak self] in
                guard let self else { return }
                let wasBusy = self.meter.take() * 1000
                if sent > 0 { busy.append(wasBusy) }
                guard CACurrentMediaTime() - started < 60 else {
                    self.stopFrames()
                    let elapsed = CACurrentMediaTime() - started
                    let cpu = AtomTreeBenchmark.threadCPUms() - startedCPU
                    var stats = TaskItemBenchmark.frameStats(updateWork)
                    stats["updates"] = sent
                    stats["characters"] = min(TranscriptTreeBenchmark.streamed.count, sent * chunk)
                    stats["updateWork"] = AtomTreeBenchmark.summary(updateWork)
                    stats["busyPerUpdate"] = AtomTreeBenchmark.summary(busy)
                    stats["mainThreadCPUms"] = cpu
                    stats["mainThreadPercent"] = cpu / (elapsed * 1000) * 100
                    stats["specWork"] = AtomTreeBenchmark.summary(self.host?.specMs ?? [])
                    stats["reconcileWork"] = AtomTreeBenchmark.summary(self.host?.reconcileMs ?? [])
                    stats["atomViewBodiesPerUpdate"] = Double(counts.viewsSince) / Double(max(1, sent))
                    stats["nodeBodiesPerUpdate"] = Double(counts.bodiesSince) / Double(max(1, sent))
                    stats["decodesPerUpdate"] = Double(counts.decodesSince) / Double(max(1, sent))
                    // What the streamed reply's text views show, to check that every variant drew it.
                    stats["renderedCharacters"] = self.textViews(in: view).filter { $0.string.hasPrefix("Step 0") || $0.string.contains("Check 0 of step 0") }
                        .reduce(0) { $0 + $1.string.count }
                    if let host = self.host {
                        stats["lastMarkdownCharacters"] = host.lastMarkdown.characters
                        stats["lastTreeShown"] = host.lastMarkdown.shown
                    }
                    // The end of what was streamed (its last complete line and the lines before it,
                    // letters and digits only, fence lines dropped) must be on screen, so a variant
                    // that stops redrawing the reply fails instead of reporting fast numbers.
                    let sentText = String(TranscriptTreeBenchmark.streamed[0..<min(TranscriptTreeBenchmark.streamed.count, sent * chunk)])
                    let completeLines = sentText.split(separator: "\n").dropLast().filter { !$0.hasPrefix("```") }
                    let tail = String(Self.lettersAndDigits(completeLines.joined()).suffix(16))
                    let shown = Self.lettersAndDigits(self.textViews(in: view).map(\.string).joined())
                    stats["streamTail"] = tail
                    let clip = scroll.contentView
                    stats["documentHeight"] = scroll.documentView?.frame.height ?? 0
                    stats["scrollOffsetFromBottom"] = (scroll.documentView?.frame.height ?? 0) - clip.bounds.height - clip.bounds.origin.y
                    stats["textViewsShown"] = self.textViews(in: view).count
                    stats["shownTail"] = String(shown.suffix(40))
                    stats["streamTailDrawn"] = !tail.isEmpty && shown.contains(tail)
                    self.results["stream"] = stats
                    if stats["streamTailDrawn"] as? Bool != true {
                        self.results["error"] = "the end of the streamed reply is not on screen"
                    }
                    return self.finish()
                }
                let start = CACurrentMediaTime()
                let state = TranscriptTreeBenchmark.signposter.beginInterval("stream update")
                sent += 1
                let end = min(TranscriptTreeBenchmark.streamed.count, sent * chunk)
                self.model.boxes[last].item = .assistant(id: "stream-a", text: String(TranscriptTreeBenchmark.streamed[0..<end]))
                self.host?.update(last)
                self.renderNow(view)
                let clip = scroll.contentView
                let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
                if clip.bounds.origin.y < maxY - 0.5 {
                    clip.scroll(to: NSPoint(x: 0, y: maxY))
                    scroll.reflectScrolledClipView(clip)
                    self.renderNow(view)
                }
                TranscriptTreeBenchmark.signposter.endInterval("stream update", state)
                updateWork.append((CACurrentMediaTime() - start) * 1000)
            }
        }

        func finish() {
            stopFrames()
            results["peakFootprintMB"] = TaskItemBenchmark.footprintMB().peak
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                FileManager.default.createFile(atPath: outputPath, contents: data)
            }
            exit(0)
        }
    }
}
#endif
