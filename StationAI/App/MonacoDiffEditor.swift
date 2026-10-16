import AppKit
import Foundation
import SwiftUI
import WebKit

struct MonacoDiffEditor: NSViewRepresentable {
    let diff: WorkspaceFileDiff
    let theme: String
    @Binding var isReady: Bool
    @Binding var loadError: String?
    @Binding var diffChangeCount: Int?

    private struct Payload: Encodable {
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
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let resources = Bundle.main.resourceURL?.appendingPathComponent("Monaco", isDirectory: true)
        let workerSourceScript = resources.flatMap { self.workerSourceScript(in: $0) }
        if let workerSourceScript {
            configuration.userContentController.addUserScript(WKUserScript(
                source: workerSourceScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        } else {
            loadError = "The bundled Monaco diff workers are missing."
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(webView)
        webView.setAccessibilityIdentifier("workspace-monaco-webview")
        webView.setAccessibilityLabel("Side-by-side diff for \(diff.path)")
        webView.underPageBackgroundColor = theme == "vs-dark" ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white
        context.coordinator.onReady = { ready in isReady = ready }
        context.coordinator.onError = { message in loadError = message }
        context.coordinator.onDiffComputed = { count in diffChangeCount = count }
        context.coordinator.update(diff: diff, theme: theme)

        guard workerSourceScript != nil else {
            loadError = "The bundled Monaco diff workers are missing."
            return webView
        }

        guard let resources else {
            loadError = "The bundled Monaco diff editor is missing."
            return webView
        }
        let entryPoint = resources.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: entryPoint.path) else {
            loadError = "The bundled Monaco diff editor is missing."
            return webView
        }
        webView.loadFileURL(entryPoint, allowingReadAccessTo: resources)
        return webView
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
        return "window.stationAIMonacoWorkerSources = \(json);"
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.underPageBackgroundColor = theme == "vs-dark" ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white
        webView.setAccessibilityLabel("Side-by-side diff for \(diff.path)")
        context.coordinator.onReady = { ready in isReady = ready }
        context.coordinator.onError = { message in loadError = message }
        context.coordinator.onDiffComputed = { count in diffChangeCount = count }
        context.coordinator.update(diff: diff, theme: theme)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onReady: ((Bool) -> Void)?
        var onError: ((String?) -> Void)?
        var onDiffComputed: ((Int?) -> Void)?

        private var isReady = false
        private var latestDiff: WorkspaceFileDiff?
        private var latestTheme = "vs"
        private var lastSentKey: String?
        private var diffRevision = 0

        func update(diff: WorkspaceFileDiff, theme: String) {
            latestDiff = diff
            latestTheme = theme
            let key = "\(diff.repository)\u{0}\(diff.path)\u{0}\(diff.group.rawValue)\u{0}\(diff.original ?? "")\u{0}\(diff.modified ?? "")\u{0}\(theme)"
            guard key != lastSentKey else { return }
            lastSentKey = key
            diffRevision += 1
            onDiffComputed?(nil)
            sendLatestDiffIfReady()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            attach(webView)
            checkReady(webView, attempt: 0)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportLoadFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportLoadFailure(error)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
        }

        private func checkReady(_ webView: WKWebView, attempt: Int) {
            webView.evaluateJavaScript("window.stationAIDiffReady === true") { [weak self, weak webView] value, error in
                guard let self, let webView else { return }
                if error == nil, value as? Bool == true {
                    self.isReady = true
                    self.onError?(nil)
                    self.onReady?(true)
                    self.sendLatestDiffIfReady()
                } else if attempt < 60 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.checkReady(webView, attempt: attempt + 1)
                    }
                } else {
                    self.reportLoadFailure(error ?? NSError(
                        domain: "MonacoDiffEditor",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Monaco didn't finish loading."]
                    ))
                }
            }
        }

        private func sendLatestDiffIfReady() {
            guard isReady, let diff = latestDiff else { return }
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
            webView?.evaluateJavaScript("window.stationAIDiff && window.stationAIDiff.setDiff(\(json));") { [weak self, weak webView] _, error in
                guard let self else { return }
                if let error {
                    self.reportLoadFailure(error)
                } else if let webView {
                    self.checkDiffComputation(in: webView, revision: revision, attempt: 0)
                }
            }
        }

        private func checkDiffComputation(in webView: WKWebView, revision: Int, attempt: Int) {
            guard revision == diffRevision else { return }
            webView.evaluateJavaScript("window.stationAIDiff && window.stationAIDiff.getLineChangeCount();") { [weak self, weak webView] value, error in
                guard let self, let webView, revision == self.diffRevision else { return }
                if error == nil, let count = value as? Int {
                    self.onDiffComputed?(count)
                } else if attempt < 60 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.checkDiffComputation(in: webView, revision: revision, attempt: attempt + 1)
                    }
                } else {
                    self.onDiffComputed?(nil)
                    self.onError?("Monaco couldn't finish calculating this diff.")
                }
            }
        }

        private weak var webView: WKWebView?

        private func reportLoadFailure(_ error: Error) {
            isReady = false
            onReady?(false)
            onError?("Monaco couldn't load this diff: \(error.localizedDescription)")
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
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
