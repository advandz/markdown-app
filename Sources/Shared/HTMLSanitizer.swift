//
//  HTMLSanitizer.swift
//  Markdown
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation

/// Cleans raw HTML from a document for places that can't switch scripts off
/// (QuickLook's web view runs them and ignores a page's Content-Security-Policy).
///
/// Works on an allowlist: formatting tags people use in READMEs (`details`,
/// `img`, tables, `<p align>`…) stay; scripts, styles, frames, embeds, forms
/// and anything unknown go, with every attribute that isn't known to be safe.
/// Links keep web, mail and in-document targets only; images go through the
/// caller's `imageSource`, which decides what may load.
enum HTMLSanitizer {
    static func clean(_ html: String, imageSource: (String) -> String?) -> String {
        var output = ""
        var skipping: String?          // inside <script>, <style>… until its closing tag
        let ns = html as NSString
        var cursor = 0
        for match in token.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if skipping == nil {
                output += escapeText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            cursor = NSMaxRange(match.range)
            guard match.range(at: 2).location != NSNotFound else { continue }   // comment
            let closing = match.range(at: 1).length > 0
            let name = ns.substring(with: match.range(at: 2)).lowercased()
            let attributes = match.range(at: 3).location == NSNotFound ? "" : ns.substring(with: match.range(at: 3))

            if let open = skipping {
                if closing && name == open { skipping = nil }
                continue
            }
            if droppedWithContent.contains(name) {
                if !closing && !attributes.hasSuffix("/") { skipping = name }
                continue
            }
            guard allowedTags.contains(name) else { continue }
            output += closing ? "</\(name)>" : "<\(name)\(cleanAttributes(attributes, tag: name, imageSource: imageSource))>"
        }
        if skipping == nil {
            output += escapeText(ns.substring(from: cursor))
        }
        return output
    }

    /// Whether a link target is safe to keep: web, mail, or a path or anchor in the document.
    static func isSafeLink(_ value: String) -> Bool {
        guard let scheme = scheme(of: value) else { return !value.contains("&#") && !value.contains("\\") }
        return ["http", "https", "mailto"].contains(scheme)
    }

    // MARK: - Details

    /// A comment, or an opening or closing tag with its attributes.
    private static let token = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->|<(/?)([A-Za-z][A-Za-z0-9-]*)((?:\s+[^<>]*?)?)\s*/?>"#
    )
    private static let attribute = try! NSRegularExpression(
        pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#
    )

    private static let allowedTags: Set<String> = [
        "a", "abbr", "b", "bdi", "bdo", "blockquote", "br", "caption", "center", "cite", "code", "col",
        "colgroup", "dd", "del", "details", "dfn", "div", "dl", "dt", "em", "figcaption", "figure",
        "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "img", "ins", "kbd", "li", "mark", "ol", "p",
        "picture", "pre", "q", "rp", "rt", "ruby", "s", "samp", "small", "source", "span", "strike",
        "strong", "sub", "summary", "sup", "table", "tbody", "td", "tfoot", "th", "thead", "time", "tr",
        "tt", "u", "ul", "var", "wbr",
    ]
    private static let droppedWithContent: Set<String> = [
        "script", "style", "template", "iframe", "frame", "frameset", "object", "embed", "applet",
        "svg", "math", "noscript", "noembed", "textarea", "select", "title", "head", "xmp", "plaintext",
    ]
    private static let allowedAttributes: Set<String> = [
        "align", "alt", "title", "width", "height", "colspan", "rowspan", "open", "dir", "lang",
        "start", "reversed", "type", "valign", "datetime", "cite", "media", "id",
    ]

    private static func cleanAttributes(_ text: String, tag: String, imageSource: (String) -> String?) -> String {
        var result = ""
        let ns = text as NSString
        for match in attribute.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let value = [2, 3, 4].lazy.map { match.range(at: $0) }
                .first { $0.location != NSNotFound }
                .map { decodeEntities(ns.substring(with: $0)) } ?? ""

            var kept: String?
            switch name {
            case "href" where tag == "a":
                kept = isSafeLink(value) ? value : nil
            case "src" where tag == "img" || tag == "source":
                kept = safeImageSource(value, imageSource: imageSource)
            case "srcset" where tag == "source" || tag == "img":
                // A single image path only; lists with size descriptors are dropped.
                kept = value.contains(",") || value.trimmingCharacters(in: .whitespaces).contains(" ")
                    ? nil : safeImageSource(value, imageSource: imageSource)
            default:
                kept = allowedAttributes.contains(name) ? value : nil
            }
            if let kept { result += " \(name)=\"\(MarkdownRenderer.escapeAttribute(kept))\"" }
        }
        return result
    }

    /// Where an image may load from: an attachment, inline image data, or a local
    /// path (after the caller's mapping). Nil for anything remote or unsafe.
    static func safeImageSource(_ value: String, imageSource: (String) -> String?) -> String? {
        let mapped = imageSource(value) ?? value
        switch scheme(of: mapped) {
        case "cid": return mapped
        case "data": return mapped.lowercased().hasPrefix("data:image/") ? mapped : nil
        case nil: return mapped.contains("&#") || mapped.contains("\\") ? nil : mapped
        default: return nil
        }
    }

    /// The URL scheme, ignoring the whitespace and control characters browsers skip.
    private static func scheme(of value: String) -> String? {
        let compact = value.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }
        let text = String(String.UnicodeScalarView(compact))
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let candidate = text[..<colon]
        // A "/", "?" or "#" before the colon makes it part of a path, not a scheme.
        guard !candidate.isEmpty, !candidate.contains(where: { "/?#".contains($0) }) else { return nil }
        return candidate.lowercased()
    }

    private static func decodeEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&colon;", with: ":")
            .replacingOccurrences(of: "&Tab;", with: "\t")
            .replacingOccurrences(of: "&NewLine;", with: "\n")
    }

    /// Text between tags keeps its entities but never forms new markup.
    private static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
