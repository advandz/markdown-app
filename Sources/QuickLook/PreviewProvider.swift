//
//  PreviewProvider.swift
//  Markdown
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Cocoa
import QuickLookUI
import UniformTypeIdentifiers

/// Data-based QuickLook preview: renders the Markdown file to HTML and hands
/// it to QuickLook, which displays it in its own web view.
@objc(PreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let text = TextDecoding.decode(try Data(contentsOf: url)).text

        let directory = url.deletingLastPathComponent()
        let images = ImageAttachments(directory: directory, root: DocumentFolder.root(for: directory))
        // QuickLook's web view runs scripts and loads remote content, and it
        // ignores the page's Content-Security-Policy, while previews appear
        // without the file being opened. So the HTML itself is cleaned: no
        // scripts, no remote loads, only safe links (see `HTMLSanitizer`).
        let body = MarkdownRenderer.html(from: text, imageSource: { images.source(for: $0) }, sanitize: true)
        let title = url.deletingPathExtension().lastPathComponent
        let html = PreviewTheme.page(body: body, title: title, policy: .quickLook)   // kept in case it's honoured

        let attachments = images.attachments
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 860, height: 1000)) { reply in
            reply.stringEncoding = .utf8
            reply.attachments = attachments
            return Data(html.utf8)
        }
        reply.title = title
        return reply
    }
}

/// Local images can only be shown when they're attached to the reply. Only
/// image files inside the document's folder are attached, within limits that
/// are checked before anything is read.
private final class ImageAttachments {
    static let maxCount = 32
    static let maxImageSize = 20_000_000
    static let maxTotalSize = 60_000_000

    let directory: URL
    let root: URL
    private(set) var attachments: [String: QLPreviewReplyAttachment] = [:]
    private var idsByPath: [String: String] = [:]
    private var totalSize = 0

    init(directory: URL, root: URL) {
        self.directory = directory
        self.root = root
    }

    /// The `cid:` URL for a relative image path, or nil to leave `src` as it is.
    func source(for src: String) -> String? {
        guard !src.contains(":"), !src.hasPrefix("/"), let path = src.removingPercentEncoding else { return nil }
        let file = directory.appendingPathComponent(path).standardizedFileURL
        if let id = idsByPath[file.path] { return "cid:\(id)" }

        guard attachments.count < Self.maxCount,
              DocumentFolder.contains(root, file),
              let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize,
              size <= Self.maxImageSize, totalSize + size <= Self.maxTotalSize,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }

        let id = "image-\(attachments.count)"
        attachments[id] = QLPreviewReplyAttachment(data: data, contentType: type)
        idsByPath[file.path] = id
        totalSize += size
        return "cid:\(id)"
    }
}
