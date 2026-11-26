//
//  MarkdownRenderer.swift
//  Markdown
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation

/// Converts Markdown into HTML using Foundation's CommonMark/GFM parser
/// (`AttributedString(markdown:)`), walking its presentation intents to
/// rebuild the block structure. Shared by the app and the QuickLook extension.
enum MarkdownRenderer {

    /// Renders `markdown` to an HTML fragment.
    /// - Parameters:
    ///   - imageSource: optional hook that can rewrite an image `src`
    ///     (used by QuickLook to attach local images). Return `nil` to keep it.
    ///   - sanitize: clean raw HTML and keep only safe links and local images,
    ///     for viewers that run scripts (QuickLook). See `HTMLSanitizer`.
    static func html(from markdown: String, imageSource: ((String) -> String?)? = nil, sanitize: Bool = false) -> String {
        let source = preprocess(markdown, imageSource: imageSource)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let attributed = try? AttributedString(markdown: source, options: options) else {
            return "<pre><code>\(escape(markdown))</code></pre>"
        }
        var builder = HTMLBuilder(imageSource: imageSource, sanitize: sanitize)
        builder.render(attributed)
        return builder.output
    }

    // MARK: - Pre-processing

    /// Smooths over a few things Foundation's parser doesn't handle the way
    /// people expect from GitHub-flavoured Markdown.
    static func preprocess(_ text: String, imageSource: ((String) -> String?)? = nil) -> String {
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        // YAML front matter → fenced code block, so it doesn't become a <hr> + heading.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().prefix(200).firstIndex(where: {
               let t = $0.trimmingCharacters(in: .whitespaces)
               return t == "---" || t == "..."
           }), end > 1 {
            lines[0] = "```yaml"
            lines[end] = "```"
        }

        // Linked images ([![alt](src)](href)) lose their image when nested in a
        // link, so turn them into inline HTML. Skip fenced code blocks.
        var inFence = false
        var fenceMarker = ""
        for i in lines.indices {
            let trimmed = lines[i].drop(while: { $0 == " " })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if !inFence { inFence = true; fenceMarker = marker }
                else if marker == fenceMarker { inFence = false }
                continue
            }
            if !inFence, lines[i].contains("[![") {
                lines[i] = replaceLinkedImages(in: lines[i], imageSource: imageSource)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static let linkedImage = try! NSRegularExpression(
        pattern: #"\[!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#
    )

    private static func replaceLinkedImages(in line: String, imageSource: ((String) -> String?)?) -> String {
        let ns = line as NSString
        var result = ""
        var cursor = 0
        for match in linkedImage.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let alt = ns.substring(with: match.range(at: 1))
            let raw = ns.substring(with: match.range(at: 2))
            let src = imageSource?(raw) ?? raw
            let href = ns.substring(with: match.range(at: 3))
            result += "<a href=\"\(escapeAttribute(href))\"><img src=\"\(escapeAttribute(src))\" alt=\"\(escapeAttribute(alt))\"></a>"
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    // MARK: - Escaping

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    static func escapeAttribute(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - HTML builder

private struct HTMLBuilder {
    struct OpenBlock {
        let identity: Int
        let kind: PresentationIntent.Kind
        var tagIndex: Int = 0          // index of this block's opening tag in `parts`
        var children: Int = 0          // list items / table cells emitted so far
        var tbodyOpen = false
    }

    let imageSource: ((String) -> String?)?
    let sanitize: Bool
    private(set) var parts: [String] = []
    private var stack: [OpenBlock] = []
    private var openLink: URL?
    private var lastImage: URL?
    private var headerText = ""
    private var pendingTaskCheck = false
    private var usedSlugs: [String: Int] = [:]

    init(imageSource: ((String) -> String?)?, sanitize: Bool) {
        self.imageSource = imageSource
        self.sanitize = sanitize
    }

    /// Raw HTML from the document: as written, or cleaned when sanitizing.
    private func rawHTML(_ text: String) -> String {
        sanitize ? HTMLSanitizer.clean(text) { imageSource?($0) } : text
    }

    var output: String { parts.joined() }

    mutating func render(_ attributed: AttributedString) {
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            let components = Array((run.presentationIntent?.components ?? []).reversed())

            var common = 0
            while common < stack.count, common < components.count,
                  stack[common].identity == components[common].identity {
                common += 1
            }
            if common < stack.count || common < components.count {
                closeLink()
                lastImage = nil
            }
            while stack.count > common { close(stack.removeLast()) }
            for component in components[common...] { open(component) }

            emit(run: run, text: text)
        }
        closeLink()
        while let block = stack.popLast() { close(block) }
    }

    // MARK: Blocks

    private mutating func open(_ intent: PresentationIntent.IntentType) {
        var block = OpenBlock(identity: intent.identity, kind: intent.kind)
        block.tagIndex = parts.count

        switch intent.kind {
        case .paragraph:
            parts.append("<p>")
        case .header:
            parts.append("")              // filled in on close, once we know the slug
            headerText = ""
        case .orderedList:
            parts.append("<ol>\n")
        case .unorderedList:
            parts.append("<ul>\n")
        case .listItem(let ordinal):
            if let parentIndex = stack.indices.last {
                if case .orderedList = stack[parentIndex].kind,
                   stack[parentIndex].children == 0, ordinal != 1 {
                    parts[stack[parentIndex].tagIndex] = "<ol start=\"\(ordinal)\">\n"
                }
                stack[parentIndex].children += 1
            }
            block.tagIndex = parts.count
            parts.append("<li>")
            pendingTaskCheck = true
        case .blockQuote:
            parts.append("<blockquote>\n")
        case .codeBlock(let language):
            if let language, !language.isEmpty {
                let lang = MarkdownRenderer.escapeAttribute(language)
                parts.append("<pre><code class=\"language-\(lang)\" data-lang=\"\(lang)\">")
            } else {
                parts.append("<pre><code>")
            }
        case .thematicBreak:
            parts.append("<hr>\n")
        case .table:
            parts.append("<div class=\"table-wrap\"><table>\n")
        case .tableHeaderRow:
            parts.append("<thead>\n<tr>")
        case .tableRow:
            if let t = tableIndex, !stack[t].tbodyOpen {
                stack[t].tbodyOpen = true
                parts.append("<tbody>\n")
            }
            parts.append("<tr>")
        case .tableCell(let column):
            if let r = stack.indices.last {
                while stack[r].children < column {
                    parts.append(emptyCell(at: stack[r].children, header: isHeaderRow(stack[r])))
                    stack[r].children += 1
                }
                stack[r].children = column + 1
                let header = isHeaderRow(stack[r])
                block.tagIndex = parts.count
                parts.append("<\(header ? "th" : "td")\(alignment(column))>")
            }
        default:
            parts.append("<div>")
        }
        stack.append(block)
    }

    private mutating func close(_ block: OpenBlock) {
        closeLink()
        switch block.kind {
        case .paragraph:
            parts.append("</p>\n")
        case .header(let level):
            let slug = makeSlug(headerText)
            parts[block.tagIndex] = "<h\(level) id=\"\(slug)\">"
            parts.append("</h\(level)>\n")
        case .orderedList:
            parts.append("</ol>\n")
        case .unorderedList:
            parts.append("</ul>\n")
        case .listItem:
            parts.append("</li>\n")
        case .blockQuote:
            parts.append("</blockquote>\n")
        case .codeBlock:
            if let last = parts.indices.last, parts[last].hasSuffix("\n") {
                parts[last].removeLast()
            }
            parts.append("</code></pre>\n")
        case .thematicBreak:
            break
        case .table:
            if block.tbodyOpen { parts.append("</tbody>\n") }
            parts.append("</table></div>\n")
        case .tableHeaderRow, .tableRow:
            let columns = tableColumns.count
            var emitted = block.children
            while emitted < columns {
                parts.append(emptyCell(at: emitted, header: isHeaderRow(block)))
                emitted += 1
            }
            parts.append(isHeaderRow(block) ? "</tr>\n</thead>\n" : "</tr>\n")
        case .tableCell:
            let header = stack.last.map(isHeaderRow) ?? false
            parts.append(header ? "</th>" : "</td>")
        default:
            parts.append("</div>")
        }
    }

    // MARK: Inline content

    private mutating func emit(run: AttributedString.Runs.Run, text: String) {
        let intent = run.inlinePresentationIntent ?? []

        guard let inner = stack.last else {
            // Block-level HTML (or stray text) outside any block.
            parts.append(intent.contains(.blockHTML) || intent.contains(.inlineHTML)
                         ? rawHTML(text) : MarkdownRenderer.escape(text))
            return
        }

        switch inner.kind {
        case .thematicBreak:
            return
        case .codeBlock:
            parts.append(MarkdownRenderer.escape(text))
            return
        default:
            break
        }

        var text = text
        if pendingTaskCheck {
            pendingTaskCheck = false
            checkTaskMarker(&text)
        }

        if intent.contains(.inlineHTML) || intent.contains(.blockHTML) {
            parts.append(rawHTML(text))
            return
        }

        if run.link != openLink {
            closeLink()
            if let link = run.link, !sanitize || HTMLSanitizer.isSafeLink(link.absoluteString) {
                parts.append("<a href=\"\(MarkdownRenderer.escapeAttribute(link.absoluteString))\">")
                openLink = link
            }
        }

        if let image = run.imageURL {
            guard image != lastImage else { return }   // multi-run alt text
            lastImage = image
            let raw = image.absoluteString
            let src = sanitize
                ? HTMLSanitizer.safeImageSource(raw) { imageSource?($0) } ?? ""
                : imageSource?(raw) ?? raw
            let alt = text == "\u{FFFC}" ? "" : text
            parts.append("<img src=\"\(MarkdownRenderer.escapeAttribute(src))\" alt=\"\(MarkdownRenderer.escapeAttribute(alt))\">")
            if case .header = inner.kind { headerText += alt }
            return
        }
        lastImage = nil

        if intent.contains(.softBreak) {
            parts.append("\n")
            if case .header = inner.kind { headerText += " " }
            return
        }
        if intent.contains(.lineBreak) {
            parts.append("<br>\n")
            return
        }

        if case .header = inner.kind { headerText += text }

        var html = MarkdownRenderer.escape(text)
        if intent.contains(.code) { html = "<code>\(html)</code>" }
        if intent.contains(.strikethrough) { html = "<del>\(html)</del>" }
        if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
        if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
        parts.append(html)
    }

    /// Turns a leading `[ ]` / `[x]` in the first line of a list item into a checkbox.
    private mutating func checkTaskMarker(_ text: inout String) {
        guard let itemIndex = stack.lastIndex(where: {
            if case .listItem = $0.kind { return true } else { return false }
        }), stack.count - itemIndex == 2 else { return }   // item > paragraph

        let markers: [(String, Bool)] = [("[ ] ", false), ("[x] ", true), ("[X] ", true)]
        for (marker, checked) in markers where text.hasPrefix(marker) || text == marker.trimmingCharacters(in: .whitespaces) {
            text = String(text.dropFirst(min(marker.count, text.count)))
            parts[stack[itemIndex].tagIndex] = "<li class=\"task-list-item\">"
            parts.append("<input type=\"checkbox\" disabled\(checked ? " checked" : "")> ")
            return
        }
    }

    private mutating func closeLink() {
        if openLink != nil {
            parts.append("</a>")
            openLink = nil
        }
    }

    // MARK: Helpers

    private var tableIndex: Int? {
        stack.lastIndex(where: { if case .table = $0.kind { return true } else { return false } })
    }

    private var tableColumns: [PresentationIntent.TableColumn] {
        guard let t = tableIndex, case .table(let columns) = stack[t].kind else { return [] }
        return columns
    }

    private func isHeaderRow(_ block: OpenBlock) -> Bool {
        if case .tableHeaderRow = block.kind { return true }
        return false
    }

    private func alignment(_ column: Int) -> String {
        let columns = tableColumns
        guard column < columns.count else { return "" }
        switch columns[column].alignment {
        case .center: return " style=\"text-align:center\""
        case .right: return " style=\"text-align:right\""
        default: return ""
        }
    }

    private func emptyCell(at column: Int, header: Bool) -> String {
        let tag = header ? "th" : "td"
        return "<\(tag)\(alignment(column))></\(tag)>"
    }

    private mutating func makeSlug(_ text: String) -> String {
        var slug = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                slug.unicodeScalars.append(scalar)
            } else if scalar == " " {
                slug += "-"
            }
        }
        if slug.isEmpty { slug = "section" }
        if let count = usedSlugs[slug] {
            usedSlugs[slug] = count + 1
            return MarkdownRenderer.escapeAttribute("\(slug)-\(count)")
        }
        usedSlugs[slug] = 1
        return MarkdownRenderer.escapeAttribute(slug)
    }
}
