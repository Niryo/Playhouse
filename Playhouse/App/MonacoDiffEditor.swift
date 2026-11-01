import AppKit
import Foundation
import SwiftUI
import WebKit

/// Monaco is expensive to boot, so Playhouse loads it once into a single web view that
/// stays alive for the whole session. Opening a diff reuses that warm editor and only
/// swaps its models, instead of paying for the bundle and the workers every time.
///
/// One web view can live in one place at a time, so this assumes a single diff is on
/// screen: the app has one `Window` scene and one `TaskConversationView`, and its diff
/// overlay is the only presenter. A second simultaneous presenter would pull the shared
/// view out of the first one; give each presenter its own host before adding one.
@MainActor
final class MonacoDiffWebViewHost: NSObject {
    static let shared = MonacoDiffWebViewHost()

    /// A crash loop in the web content process must not reload Monaco forever.
    private static let maximumContentProcessRestarts = 3

    private enum Readiness {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// Monaco only builds its diff editor on the first `setDiff`, so the warm-up sends a
    /// placeholder diff that is replaced by the first file the user opens.
    private static let warmUpPayload = """
    {"path":"warmup.txt","original":"","modified":"","isText":true,"message":null,"theme":"vs-dark"}
    """

    private var hostedWebView: WKWebView?
    private var readiness: Readiness = .idle
    private var readyHandlers: [(String?) -> Void] = []
    private var contentProcessRestarts = 0
    /// Counts how often Monaco has been loaded, which stays at one for a warm session.
    private var loadCount = 0

    /// True once Monaco has finished loading, so the next diff opens without loading anything.
    private(set) var isWarm = false

    /// The diff currently showing this editor, told when the web content process dies.
    weak var activeObserver: MonacoDiffEditor.Coordinator?

    /// Starts loading Monaco ahead of the first diff. Safe to call repeatedly.
    func prewarm() {
        _ = webView()
    }

    /// The loaded web view, if there is one. Unlike `webView()`, asking doesn't load Monaco.
    var currentWebView: WKWebView? { hostedWebView }

    /// The shared web view, creating and loading it on first use. Returns nil only when the
    /// bundled editor is missing; the reason is delivered to `whenReady` observers.
    @discardableResult
    func webView() -> WKWebView? {
        if let hostedWebView { return hostedWebView }
        guard case .idle = readiness else { return hostedWebView }

        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("Monaco", isDirectory: true),
              let workerSourceScript = workerSourceScript(in: resources) else {
            fail(with: "The bundled Monaco diff workers are missing.")
            return nil
        }
        let entryPoint = resources.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: entryPoint.path) else {
            fail(with: "The bundled Monaco diff editor is missing.")
            return nil
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(WKUserScript(
            source: workerSourceScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        // A realistic warm-up size lets Monaco lay out before the view is on screen.
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        webView.navigationDelegate = self
        webView.setAccessibilityIdentifier("workspace-monaco-webview")
        loadCount += 1
        // The tag travels with the view, so a diff can report the editor it actually rendered in.
        webView.identifier = NSUserInterfaceItemIdentifier("\(loadCount)")
        hostedWebView = webView
        readiness = .loading
        webView.loadFileURL(entryPoint, allowingReadAccessTo: resources)
        return webView
    }

    /// Calls `handler` once Monaco can accept a diff, immediately when it already can.
    /// The handler receives nil on success and a message describing the failure otherwise.
    func whenReady(_ handler: @escaping (String?) -> Void) {
        switch readiness {
        case .ready:
            handler(nil)
        case .loading:
            readyHandlers.append(handler)
        case .idle:
            readyHandlers.append(handler)
            webView()
        case .failed:
            // A failure belongs to the diff that hit it; the next one loads Monaco again
            // instead of inheriting a broken editor for the rest of the session.
            readiness = .idle
            readyHandlers.append(handler)
            webView()
        }
    }

    /// Throws the loaded editor away so the next diff rebuilds it from scratch.
    func reset() {
        tearDownWebView()
        readiness = .idle
        isWarm = false
        // Nothing can answer a waiting diff once the editor it waited for is gone.
        flushReadyHandlers(failure: "Monaco couldn't load this diff: the editor was reloaded.")
    }

    private func tearDownWebView() {
        guard let hostedWebView else { return }
        hostedWebView.navigationDelegate = nil
        hostedWebView.stopLoading()
        hostedWebView.removeFromSuperview()
        self.hostedWebView = nil
    }

    private func fail(with message: String) {
        tearDownWebView()
        readiness = .failed(message)
        isWarm = false
        flushReadyHandlers(failure: message)
    }

    private func flushReadyHandlers(failure: String?) {
        let handlers = readyHandlers
        readyHandlers.removeAll()
        for handler in handlers { handler(failure) }
    }

    private func workerSourceScript(in resources: URL) -> String? {
        let workerFiles = [
            "editorWorkerService": "editor.worker.js",
            "json": "json.worker.js"
        ]
        var workerSources: [String: String] = [:]
        for (label, filename) in workerFiles {
            let url = resources.appendingPathComponent(filename)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            workerSources[label] = source
        }
        guard let data = try? JSONEncoder().encode(workerSources),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "window.playhouseMonacoWorkerSources = \(json);"
    }

    private func checkScriptReady(attempt: Int) {
        guard let hostedWebView else { return }
        hostedWebView.evaluateJavaScript("window.playhouseDiffReady === true") { [weak self] value, error in
            MainActor.assumeIsolated {
                guard let self, self.hostedWebView === hostedWebView else { return }
                if error == nil, value as? Bool == true {
                    self.warmUpDiffEditor()
                } else if attempt < 60 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        MainActor.assumeIsolated { self.checkScriptReady(attempt: attempt + 1) }
                    }
                } else {
                    self.fail(with: self.loadFailureMessage(
                        error ?? NSError(
                            domain: "MonacoDiffEditor",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Monaco didn't finish loading."]
                        )
                    ))
                }
            }
        }
    }

    private func warmUpDiffEditor() {
        guard let hostedWebView else { return }
        // The warm-up payload is a constant, so it needs no escaping.
        hostedWebView.evaluateJavaScript(
            "window.playhouseDiff && window.playhouseDiff.setDiff(\(Self.warmUpPayload));"
        ) { [weak self] _, error in
            MainActor.assumeIsolated {
                guard let self, self.hostedWebView === hostedWebView else { return }
                if let error {
                    self.fail(with: self.loadFailureMessage(error))
                    return
                }
                self.readiness = .ready
                self.isWarm = true
                self.flushReadyHandlers(failure: nil)
            }
        }
    }

    fileprivate func loadFailureMessage(_ error: Error) -> String {
        "Monaco couldn't load this diff: \(error.localizedDescription)"
    }
}

extension MonacoDiffWebViewHost: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkScriptReady(attempt: 0)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(with: loadFailureMessage(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(with: loadFailureMessage(error))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let observer = activeObserver
        contentProcessRestarts += 1
        reset()
        observer?.reportContentProcessTermination()
        // A repeatedly crashing editor is left for the Reload editor button rather than
        // reloaded in a loop.
        guard contentProcessRestarts <= Self.maximumContentProcessRestarts else { return }
        prewarm()
    }
}

/// What Monaco has actually rendered, as opposed to the diff the app has asked for.
struct MonacoDiffPresentation: Equatable {
    /// Which load of Monaco rendered it: this stays at "1" for a warm session.
    let editorTag: String
    let path: String
    /// True when the editor was already loaded when this diff was opened.
    let reusedWarmEditor: Bool
}

struct MonacoDiffEditor: NSViewRepresentable {
    let diff: WorkspaceFileDiff
    let theme: String
    @Binding var isReady: Bool
    @Binding var loadError: String?
    @Binding var diffChangeCount: Int?
    @Binding var presentation: MonacoDiffPresentation?

    fileprivate struct Payload: Encodable {
        let path: String
        let original: String
        let modified: String
        let isText: Bool
        let message: String?
        let theme: String
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        // The shared host keeps one loaded editor, so reopening a diff reuses this view.
        let webView = MonacoDiffWebViewHost.shared.webView() ?? Self.missingEditorPlaceholder()
        webView.underPageBackgroundColor = theme == "vs-dark" ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white
        context.coordinator.attach(webView)
        bind(context.coordinator)
        context.coordinator.update(diff: diff, theme: theme)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.underPageBackgroundColor = theme == "vs-dark" ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white
        bind(context.coordinator)
        context.coordinator.update(diff: diff, theme: theme)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private func bind(_ coordinator: Coordinator) {
        coordinator.onReady = { ready in isReady = ready }
        coordinator.onError = { message in loadError = message }
        coordinator.onDiffComputed = { count in diffChangeCount = count }
        coordinator.onPresented = { presented in presentation = presented }
    }

    /// Stands in for the editor when the bundled Monaco is missing, so the diff can report
    /// the failure instead of crashing on a view it never got.
    private static func missingEditorPlaceholder() -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.setAccessibilityIdentifier("workspace-monaco-webview")
        return webView
    }

    @MainActor
    final class Coordinator: NSObject {
        var onReady: ((Bool) -> Void)?
        var onError: ((String?) -> Void)?
        var onDiffComputed: ((Int?) -> Void)?
        var onPresented: ((MonacoDiffPresentation?) -> Void)?

        private var latestDiff: WorkspaceFileDiff?
        private var latestTheme = "vs"
        private var lastSentKey: String?
        private var diffRevision = 0
        /// The warm editor still shows the file it rendered last, so it stays hidden until
        /// the file being opened is the one on screen.
        private var presentedFileKey: String?
        /// Whether Monaco was already loaded when this diff was opened.
        private var attachedToWarmEditor = false
        private weak var webView: WKWebView?

        func attach(_ webView: WKWebView) {
            self.webView = webView
            attachedToWarmEditor = MonacoDiffWebViewHost.shared.isWarm
            MonacoDiffWebViewHost.shared.activeObserver = self
        }

        func detach() {
            if MonacoDiffWebViewHost.shared.activeObserver === self {
                MonacoDiffWebViewHost.shared.activeObserver = nil
            }
            // The shared view's visibility belongs to whichever diff is presenting it now.
            webView = nil
            // A reply still in flight must not report into the diff that replaced this one.
            onReady = nil
            onError = nil
            onDiffComputed = nil
            onPresented = nil
        }

        func reportContentProcessTermination() {
            report(failure: "Monaco couldn't load this diff: the editor stopped unexpectedly.")
        }

        func update(diff: WorkspaceFileDiff, theme: String) {
            latestDiff = diff
            latestTheme = theme
            let key = "\(diff.repository)\u{0}\(diff.path)\u{0}\(diff.group.rawValue)\u{0}\(diff.original ?? "")\u{0}\(diff.modified ?? "")\u{0}\(theme)"
            guard key != lastSentKey else { return }
            lastSentKey = key
            diffRevision += 1
            onDiffComputed?(nil)
            if fileKey(for: diff) != presentedFileKey {
                // Hide the file the warm editor still shows until this one has been applied.
                webView?.alphaValue = 0
                presentedFileKey = nil
                onPresented?(nil)
            }
            webView?.setAccessibilityLabel("Side-by-side diff for \(diff.path)")
            webView?.setAccessibilityValue("Loading the side-by-side diff.")
            let revision = diffRevision
            MonacoDiffWebViewHost.shared.whenReady { [weak self] failure in
                guard let self, revision == self.diffRevision else { return }
                if let failure {
                    self.report(failure: failure)
                } else {
                    self.sendLatestDiff()
                }
            }
        }

        private func sendLatestDiff() {
            guard let webView, let diff = latestDiff else { return }
            guard MonacoDiffWebViewHost.shared.currentWebView === webView else {
                // The editor was rebuilt while this diff waited, so this view is dead.
                report(failure: "Monaco couldn't load this diff: the editor was reloaded.")
                return
            }
            let payload = Payload(
                path: diff.path,
                original: diff.original ?? "",
                modified: diff.modified ?? "",
                isText: diff.isText,
                message: diff.message,
                theme: latestTheme
            )
            guard let data = try? JSONEncoder().encode(payload),
                  let json = String(data: data, encoding: .utf8) else {
                onError?("The selected diff couldn't be prepared for display.")
                return
            }
            // The JSON encoder escapes all string data before it is passed to JavaScript.
            let revision = diffRevision
            webView.evaluateJavaScript("window.playhouseDiff && window.playhouseDiff.setDiff(\(json));") { [weak self] _, error in
                MainActor.assumeIsolated {
                    guard let self, revision == self.diffRevision else { return }
                    if let error {
                        self.report(failure: MonacoDiffWebViewHost.shared.loadFailureMessage(error))
                        return
                    }
                    self.presentedFileKey = self.fileKey(for: diff)
                    self.webView?.alphaValue = 1
                    // Accessibility reports the diff Monaco rendered, not the one requested.
                    self.webView?.setAccessibilityValue(Self.accessibilityDiffValue(diff))
                    self.onError?(nil)
                    self.onReady?(true)
                    self.onPresented?(MonacoDiffPresentation(
                        editorTag: webView.identifier?.rawValue ?? "unknown",
                        path: diff.path,
                        reusedWarmEditor: self.attachedToWarmEditor
                    ))
                    self.checkDiffComputation(revision: revision, attempt: 0)
                }
            }
        }

        private func checkDiffComputation(revision: Int, attempt: Int) {
            guard revision == diffRevision, let webView else { return }
            webView.evaluateJavaScript("window.playhouseDiff && window.playhouseDiff.getLineChangeCount();") { [weak self] value, error in
                MainActor.assumeIsolated {
                    guard let self, revision == self.diffRevision else { return }
                    if error == nil, let count = value as? Int {
                        self.onDiffComputed?(count)
                    } else if attempt < 60 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            MainActor.assumeIsolated { self.checkDiffComputation(revision: revision, attempt: attempt + 1) }
                        }
                    } else {
                        self.onDiffComputed?(nil)
                        self.onError?("Monaco couldn't finish calculating this diff.")
                    }
                }
            }
        }

        private func fileKey(for diff: WorkspaceFileDiff) -> String {
            "\(diff.repository)\u{0}\(diff.path)\u{0}\(diff.group.rawValue)"
        }

        private static func accessibilityDiffValue(_ diff: WorkspaceFileDiff) -> String {
            guard diff.isText else { return diff.message ?? "Text diff unavailable." }
            return "Original:\n\(diff.original ?? "")\nModified:\n\(diff.modified ?? "")"
        }

        private func report(failure: String) {
            webView?.alphaValue = 1
            onReady?(false)
            onPresented?(nil)
            onError?(failure)
        }
    }
}

struct EscapeKeyMonitor: NSViewRepresentable {
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        var onEscape: () -> Void
        private var eventMonitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        func startMonitoring() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self else { return event }
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
