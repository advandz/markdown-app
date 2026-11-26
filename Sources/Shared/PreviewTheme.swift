//
//  PreviewTheme.swift
//  Markdown
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation

/// The HTML page and stylesheet used to present rendered Markdown,
/// shared by the app's preview and the QuickLook extension.
enum PreviewTheme {

    /// What a page may load. Documents can contain raw HTML, so a rendered page
    /// never runs scripts, embeds other pages or submits forms, and only loads
    /// files the context allows.
    enum ContentPolicy: Equatable {
        /// The app's preview and PDF export: files near the document (served by
        /// the app through `mdpreview:`), plus web images when allowed.
        case app(remoteImages: Bool)
        /// QuickLook: only the images attached to the preview.
        case quickLook

        var header: String {
            switch self {
            case .app(let remoteImages):
                let images = "mdpreview: data:" + (remoteImages ? " https: http:" : "")
                return "default-src 'none'; img-src \(images); media-src mdpreview: data:; "
                    + "font-src mdpreview: data:; style-src 'unsafe-inline' mdpreview:; "
                    + "object-src 'none'; frame-src 'none'; form-action 'none'; base-uri mdpreview:"
            case .quickLook:
                return "default-src 'none'; img-src cid: data:; media-src cid: data:; font-src data:; "
                    + "style-src 'unsafe-inline'; object-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"
            }
        }
    }

    /// A complete HTML document wrapping a rendered body. Pass `policy` for
    /// every page that's displayed; exported HTML goes without one.
    static func page(body: String, title: String = "", baseURL: URL? = nil, extraCSS: String = "",
                     policy: ContentPolicy? = nil) -> String {
        var head = ""
        if let policy {
            // First, so it governs everything after it, including <base>.
            head += "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy.header)\">\n"
        }
        head += """
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>\(MarkdownRenderer.escape(title))</title>
        """
        if let baseURL {
            head += "\n<base href=\"\(MarkdownRenderer.escapeAttribute(baseURL.absoluteString))\">"
        }
        head += "\n<style>\(css)\(extraCSS)</style>"
        return """
        <!doctype html>
        <html>
        <head>
        \(head)
        </head>
        <body>
        <article id="content" class="markdown-body">\(body)</article>
        </body>
        </html>
        """
    }

    static let css = """
    :root {
      color-scheme: light dark;
      --text: #1d1d1f;
      --secondary: #6e6e73;
      --tertiary: #86868b;
      --background: #ffffff;
      --fill: rgba(0, 0, 0, 0.04);
      --fill-strong: rgba(0, 0, 0, 0.07);
      --separator: rgba(0, 0, 0, 0.1);
      --accent: #0071e3;
      --mark: rgba(255, 214, 10, 0.35);
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --text: #f5f5f7;
        --secondary: #a1a1a6;
        --tertiary: #8e8e93;
        --background: #1e1e1e;
        --fill: rgba(255, 255, 255, 0.06);
        --fill-strong: rgba(255, 255, 255, 0.1);
        --separator: rgba(255, 255, 255, 0.12);
        --accent: #2997ff;
        --mark: rgba(255, 214, 10, 0.3);
      }
    }

    * { box-sizing: border-box; }

    html {
      background: var(--background);
      -webkit-text-size-adjust: 100%;
    }

    body {
      margin: 0;
      color: var(--text);
      background: var(--background);
      font: 16px/1.65 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
      -webkit-font-smoothing: antialiased;
      text-rendering: optimizeLegibility;
      font-feature-settings: "kern";
    }

    .markdown-body {
      max-width: 46rem;
      margin: 0 auto;
      padding: var(--top-inset, 48px) 48px 120px;
      overflow-wrap: break-word;
    }

    .markdown-body > :first-child { margin-top: 0 !important; }

    h1, h2, h3, h4, h5, h6 {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
      font-weight: 700;
      line-height: 1.2;
      margin: 1.8em 0 0.6em;
      scroll-margin-top: calc(var(--top-inset, 48px) + 8px);
    }
    h1 { font-size: 2.15em; letter-spacing: -0.022em; }
    h2 { font-size: 1.6em; letter-spacing: -0.018em; padding-bottom: 0.3em; border-bottom: 1px solid var(--separator); }
    h3 { font-size: 1.28em; letter-spacing: -0.012em; }
    h4 { font-size: 1.06em; }
    h5 { font-size: 0.94em; }
    h6 { font-size: 0.88em; color: var(--secondary); text-transform: uppercase; letter-spacing: 0.04em; }

    p, ul, ol, blockquote, pre, .table-wrap, details { margin: 0 0 1.1em; }

    a { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; text-underline-offset: 0.18em; }

    strong { font-weight: 650; }
    del { color: var(--secondary); }
    mark { background: var(--mark); color: inherit; border-radius: 3px; padding: 0 2px; }

    ul, ol { padding-left: 1.6em; }
    li { margin: 0.28em 0; }
    li > p { margin: 0 0 0.4em; }
    li > p:last-child { margin-bottom: 0; }
    li > ul, li > ol { margin: 0.28em 0 0; }
    li::marker { color: var(--tertiary); }

    ul:has(> li.task-list-item) { padding-left: 0.4em; }
    li.task-list-item { list-style: none; }
    li.task-list-item input[type="checkbox"] {
      -webkit-appearance: none;
      appearance: none;
      width: 1.05em; height: 1.05em;
      margin: 0 0.6em 0 0;
      vertical-align: -0.18em;
      border-radius: 50%;
      border: 1.5px solid var(--tertiary);
      background: transparent;
      opacity: 1;
    }
    li.task-list-item input[type="checkbox"]:checked {
      border-color: var(--accent);
      background: var(--accent) url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M4.5 8.4l2.3 2.3 4.7-5' fill='none' stroke='white' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E") center / 100% no-repeat;
    }
    li.task-list-item:has(> input:checked) { color: var(--secondary); }

    blockquote {
      margin-left: 0;
      padding: 0.15em 0 0.15em 1.1em;
      color: var(--secondary);
      border-left: 3px solid var(--separator);
    }
    blockquote > :last-child { margin-bottom: 0; }

    code, kbd, pre, samp {
      font-family: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace;
      font-size: 0.86em;
    }
    :not(pre) > code {
      padding: 0.15em 0.4em;
      border-radius: 6px;
      background: var(--fill-strong);
    }
    kbd {
      padding: 0.1em 0.45em;
      border-radius: 6px;
      border: 1px solid var(--separator);
      box-shadow: inset 0 -1px 0 var(--separator);
      background: var(--fill);
    }
    pre {
      position: relative;
      padding: 16px 18px;
      border-radius: 14px;
      background: var(--fill);
      overflow-x: auto;
      line-height: 1.5;
    }
    pre code { font-size: 0.86rem; background: none; padding: 0; white-space: pre; }
    pre code[data-lang]::before {
      content: attr(data-lang);
      position: absolute;
      top: 8px; right: 12px;
      font: 600 10px/1 -apple-system, sans-serif;
      letter-spacing: 0.06em;
      text-transform: uppercase;
      color: var(--tertiary);
    }

    hr {
      height: 1px;
      margin: 2.2em 0;
      border: 0;
      background: var(--separator);
    }

    img, video { max-width: 100%; height: auto; border-radius: 10px; }
    a img { border-radius: 4px; }
    p > img:only-child { display: block; margin: 0 auto; }

    .table-wrap { overflow-x: auto; }
    table {
      border-collapse: collapse;
      font-size: 0.94em;
      min-width: 50%;
      font-variant-numeric: tabular-nums;
    }
    th, td {
      padding: 0.55em 0.9em;
      border-bottom: 1px solid var(--separator);
      text-align: left;
      vertical-align: top;
    }
    th { font-weight: 600; border-bottom-width: 1.5px; }
    tbody tr:last-child td { border-bottom: 0; }

    details {
      padding: 0.6em 1em;
      border-radius: 12px;
      background: var(--fill);
    }
    summary { cursor: pointer; font-weight: 600; }

    ::selection { background: color-mix(in srgb, var(--accent) 28%, transparent); }

    @media print {
      :root {
        --text: #000; --secondary: #444; --tertiary: #666; --background: #fff;
        --fill: #f4f4f4; --fill-strong: #ececec; --separator: #ddd; --accent: #0066cc;
      }
      .markdown-body { max-width: none; padding: 0; }
      * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
      pre, pre code { white-space: pre-wrap; overflow-wrap: anywhere; }
      .table-wrap { overflow: visible; }
      pre, blockquote, table, img { break-inside: avoid; }
      h1, h2, h3 { break-after: avoid; }
    }
    """
}
