#if os(macOS)
import AppKit
import SwiftUI

// Hover tracking, press areas, accessibility anchors and other pieces of platform behavior
// SwiftCrossUI lacks, built on AppKit views on macOS.

package struct PHHoverTracker: NSViewRepresentable {
    package var onChange: (Bool) -> Void

    package func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    package func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    package final class TrackingView: NSView {
        package var onChange: (Bool) -> Void = { _ in }
        private var area: NSTrackingArea?

        package override func hitTest(_ point: NSPoint) -> NSView? { nil }
        package override func isAccessibilityElement() -> Bool { false }

        package override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            self.area = area
            // A newly installed area does not send an enter for a stationary pointer.
            // Defer the state update until SwiftUI has finished laying out the view.
            DispatchQueue.main.async { [weak self] in self?.syncHover() }
        }

        package override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.syncHover() }
        }

        private func syncHover() {
            guard let window, window.isKeyWindow else { onChange(false); return }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            onChange(visibleRect.contains(point))
        }

        package override func mouseEntered(with event: NSEvent) { onChange(true) }
        package override func mouseExited(with event: NSEvent) { onChange(false) }
    }

    package init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }
}

/// An empty, zero-size AppKit view kept behind what a Page or SidePanel covers.
/// Without a platform view there, accessibility hit tests over the presented
/// content resolve to the covered view underneath: its controls still take
/// clicks, but XCUITest (and so assistive clients) don't find them. Found by
/// bisecting the board's Done archive (#156); the AppKit mechanism is not
/// confirmed. test_task_done_removes_worktree_and_preserves_branch guards it on
/// the board; test_plugin_presentation_atoms_open_modal_page_and_side_panel and
/// test_plugin_done_archive_renders_from_atoms_like_native guard a plugin's
/// SidePanel over a grouped base.
package struct PHAccessibilityHitTestAnchor: NSViewRepresentable {
    package init() {}

    package func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    package func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Shows a hover Popover's content in an `NSPopover` beside its anchor while
/// `isPresented` holds or the pointer has rested on the anchor for `delay`
/// seconds. The popover is application-defined, so it neither takes focus
/// nor closes on clicks, and the tracking view passes every event through.
package struct PHHoverPopoverPresenter: NSViewRepresentable {
    let isPresented: Bool
    let delay: Double
    /// The side of the anchor the popover opens on.
    let edge: PHEdge
    let content: PHAnyView
    /// Gives the content, which the popover hosts outside this tree, what it reads from this
    /// tree's environment; anything else falls back to its default.
    let carryEnvironment: (PHAnyView, PHEnvironmentValues) -> PHAnyView

    package init(isPresented: Bool, delay: Double, edge: PHEdge, content: PHAnyView, carryEnvironment: @escaping (PHAnyView, PHEnvironmentValues) -> PHAnyView) {
        self.isPresented = isPresented
        self.delay = delay
        self.edge = edge
        self.content = content
        self.carryEnvironment = carryEnvironment
    }

    package func makeNSView(context: Context) -> PHHoverPopoverView { PHHoverPopoverView() }

    package func updateNSView(_ view: PHHoverPopoverView, context: Context) {
        view.delay = delay
        view.edge = switch edge {
        case .bottom: .minY
        case .leading: .minX
        case .trailing: .maxX
        case .top: .maxY
        }
        view.content = carryEnvironment(content, context.environment)
        view.isPresented = isPresented
        view.sync()
    }

    package static func dismantleNSView(_ view: PHHoverPopoverView, coordinator: ()) {
        view.teardown()
    }
}

package final class PHHoverPopoverView: NSView {
    package var isPresented = false
    package var delay: Double = 0.4
    package var edge: NSRectEdge = .maxX
    package var content = PHAnyView(PHEmptyView()) {
        didSet { hosting?.rootView = content }
    }

    private var isHovered = false
    private var pending: DispatchWorkItem?
    private var popover: NSPopover?
    private var hosting: NSHostingController<PHAnyView>?
    private var tracking: NSTrackingArea?

    package override func hitTest(_ point: NSPoint) -> NSView? { nil }

    package override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        syncHover()
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { teardown() } else { syncHover() }
    }

    package override func mouseEntered(with event: NSEvent) { setHovered(true) }
    package override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// A view that appears or scrolls under a resting pointer gets no
    /// `mouseEntered`, so its hover state comes from where the pointer is.
    private func syncHover() {
        guard window != nil else { return }
        setHovered(pointerIsInside)
    }

    /// The visible part only, so a row scrolled under the list's edge isn't hovered.
    private var pointerIsInside: Bool {
        guard let window else { return false }
        return visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        pending?.cancel()
        pending = nil
        if hovered {
            // Rows that slid under a resting pointer while laying out have since
            // moved on, so only a pointer still on the anchor opens the hint.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                pending = nil
                if pointerIsInside { sync() } else { setHovered(false) }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            sync()
        }
    }

    package func sync() {
        let shows = isPresented || (isHovered && pending == nil)
        if shows, window != nil, popover?.isShown != true {
            // One hover hint at a time: opening this one closes the last.
            if let shown = Self.shown, shown !== self { shown.yield() }
            Self.shown = self
            let hosting = NSHostingController(rootView: content)
            hosting.sizingOptions = .preferredContentSize
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.contentViewController = hosting
            self.hosting = hosting
            self.popover = popover
            popover.show(relativeTo: bounds, of: self, preferredEdge: edge)
            watchPointer()
        } else if !shows {
            close()
        }
    }

    private static weak var shown: PHHoverPopoverView?

    /// Another hint opened: drop this one's hover unless its owner holds it open.
    private func yield() {
        pending?.cancel()
        pending = nil
        isHovered = false
        if !isPresented { close() }
    }

    /// AppKit misses `mouseExited` when the pointer jumps or lands on the
    /// popover's own window, so an open hint checks the pointer itself.
    private func watchPointer() {
        watch?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncHover() }
        }
        // Common modes, so it keeps checking while the list scrolls.
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    private var watch: Timer?

    private func close() {
        watch?.invalidate()
        watch = nil
        popover?.close()
        popover = nil
        hosting = nil
        if Self.shown === self { Self.shown = nil }
    }

    package func teardown() {
        pending?.cancel()
        pending = nil
        isHovered = false
        close()
    }
}

/// AppKit's own mouse tracking tells a click from a press and hold: SwiftUI's
/// long-press gesture raced against a tap could stay tracking after a click
/// opened the editor, and the window then ignored every click until it was
/// minimized.
package struct PHPressArea: NSViewRepresentable {
    package let onClick: () -> Void
    package let onLongPress: () -> Void

    package func makeNSView(context: Context) -> PressView { PressView() }

    package func updateNSView(_ view: PressView, context: Context) {
        view.onClick = onClick
        view.onLongPress = onLongPress
    }

    package final class PressView: NSView {
        package static let holdDuration: TimeInterval = 0.45
        package var onClick: () -> Void = {}
        package var onLongPress: () -> Void = {}

        package override func isAccessibilityElement() -> Bool { false }
        package override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Tracks the press to its mouse-up here, so no gesture state outlives it.
        package override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let deadline = Date(timeIntervalSinceNow: Self.holdDuration)
            var held = false
            while true {
                let next = window.nextEvent(
                    matching: [.leftMouseUp, .leftMouseDragged],
                    until: held ? .distantFuture : deadline,
                    inMode: .eventTracking,
                    dequeue: true
                )
                guard let next else {
                    held = true
                    onLongPress()
                    continue
                }
                guard next.type == .leftMouseUp else { continue }
                if !held, bounds.contains(convert(next.locationInWindow, from: nil)) { onClick() }
                return
            }
        }
    }

    package init(onClick: @escaping () -> Void, onLongPress: @escaping () -> Void) {
        self.onClick = onClick
        self.onLongPress = onLongPress
    }
}

/// Closes a sheet when its parent window is clicked outside the sheet. The parent refuses clicks
/// while a sheet is attached, but they still pass through the app's local event monitors first.
package struct PHSheetOutsideClickDismissal: NSViewRepresentable {
    package let onDismiss: () -> Void

    package func makeNSView(context: Context) -> MonitorView { MonitorView() }
    package func updateNSView(_ view: MonitorView, context: Context) { view.onDismiss = onDismiss }

    package final class MonitorView: NSView {
        package var onDismiss: (() -> Void)?
        private var monitor: Any?

        package override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                // The sheet is attached after its content joins its window, so look up the parent per click.
                guard let self, let parent = self.window?.sheetParent, event.window === parent else { return event }
                self.onDismiss?()
                return nil
            }
        }

        package override func hitTest(_ point: NSPoint) -> NSView? { nil }
        package override func isAccessibilityElement() -> Bool { false }
    }

    package init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }
}

package struct PHEscapeKeyMonitor: NSViewRepresentable {
    let windowScoped: Bool
    let onEscape: () -> Void

    package init(windowScoped: Bool = false, onEscape: @escaping () -> Void) {
        self.windowScoped = windowScoped
        self.onEscape = onEscape
    }

    package func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
    }

    package func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.startMonitoring(in: windowScoped ? view : nil)
        return view
    }

    package func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    package static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    package final class Coordinator {
        var onEscape: () -> Void
        private var eventMonitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        func startMonitoring(in view: NSView?) {
            guard eventMonitor == nil else { return }
            let windowScoped = view != nil
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                guard event.keyCode == 53, let self else { return event }
                if windowScoped {
                    guard let anchorWindow = view?.window, event.window === anchorWindow else { return event }
                }
                self.onEscape()
                return nil
            }
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

/// Accepts an item dragged as its UUID text (a task card) and reports it, through AppKit's own
/// drag destination, which doesn't animate the drag image back after the drop.
package struct PHMoveDropDestination<Content: PHView>: NSViewRepresentable {
    let onMoveTask: (UUID) -> Void
    @PHViewBuilder let content: Content

    package init(onMoveTask: @escaping (UUID) -> Void, @PHViewBuilder content: () -> Content) {
        self.onMoveTask = onMoveTask
        self.content = content()
    }

    package func makeNSView(context: Context) -> PHMoveDropContainer<Content> {
        PHMoveDropContainer(rootView: content, onMoveTask: onMoveTask)
    }

    package func updateNSView(_ nsView: PHMoveDropContainer<Content>, context: Context) {
        nsView.rootView = content
        nsView.onMoveTask = onMoveTask
    }
}

@MainActor
package final class PHMoveDropContainer<Content: PHView>: NSView {
    private let hostingView: NSHostingView<Content>
    var onMoveTask: (UUID) -> Void

    var rootView: Content {
        get { hostingView.rootView }
        set { hostingView.rootView = newValue }
    }

    private let textPasteboardTypes: [NSPasteboard.PasteboardType] = [
        .string,
        NSPasteboard.PasteboardType("public.plain-text"),
        NSPasteboard.PasteboardType("public.utf8-plain-text")
    ]

    init(rootView: Content, onMoveTask: @escaping (UUID) -> Void) {
        hostingView = NSHostingView(rootView: rootView)
        self.onMoveTask = onMoveTask
        super.init(frame: .zero)

        registerForDraggedTypes(textPasteboardTypes)
        addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    package required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    package override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        offeredMoveOperation(for: sender)
    }

    package override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        offeredMoveOperation(for: sender)
    }

    package override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard offeredMoveOperation(for: sender) != [],
              taskID(from: sender) != nil else {
            return false
        }

        // AppKit otherwise animates the drag image to its destination after the drop.
        sender.animatesToDestination = false
        return true
    }

    package override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard offeredMoveOperation(for: sender) != [],
              let taskID = taskID(from: sender) else {
            return false
        }

        onMoveTask(taskID)
        return true
    }

    private func offeredMoveOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard taskID(from: sender) != nil else {
            return []
        }

        return sender.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    private func taskID(from sender: NSDraggingInfo) -> UUID? {
        guard let type = sender.draggingPasteboard.availableType(from: textPasteboardTypes),
              let identifier = sender.draggingPasteboard.string(forType: type) else {
            return nil
        }

        return UUID(uuidString: identifier)
    }
}
#endif
