//
//  PrintRenderer.swift
//  Markdown
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import AppKit
import WebKit

/// Renders a document into an offscreen web view for printing and PDF export,
/// so both work from any view mode and always use light, print styling.
@MainActor
final class PrintRenderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private var loadContinuation: CheckedContinuation<Void, Error>?

    init(width: CGFloat) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.shouldPrintBackgrounds = true   // code blocks, checked boxes
        LocalResources.install(in: configuration)                  // images next to the document
        let frame = NSRect(x: 0, y: 0, width: max(width, 320), height: 1000)
        webView = WKWebView(frame: frame, configuration: configuration)
        webView.appearance = NSAppearance(named: .aqua)

        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = webView

        super.init()
        webView.navigationDelegate = self
    }

    /// Loads the page and waits until it (and its images) finished loading.
    /// `baseURL` should come from `LocalResources.baseURL(for:)`; local files
    /// are served from inside `root` only (see `DocumentFolder`).
    func load(html: String, baseURL: URL, root: URL?) async throws {
        LocalResources.handler.allow(root, for: webView)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func printOperation(with info: NSPrintInfo) -> NSPrintOperation {
        let operation = webView.printOperation(with: info)
        if let view = operation.view, view.frame.isEmpty {
            view.frame = NSRect(origin: .zero, size: info.paperSize)
        }
        return operation
    }

    func cleanUp() {
        webView.stopLoading()
        window.contentView = nil
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    /// Only the page itself loads: no frames, redirects or links to other pages,
    /// so nothing from elsewhere ends up in the PDF.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType != .linkActivated, let url = navigationAction.request.url else { return .cancel }
        return url.scheme == LocalResources.scheme || url.scheme == "about" ? .allow : .cancel
    }
}
