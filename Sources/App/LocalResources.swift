//
//  LocalResources.swift
//  Markdown
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves files that sit next to a document (images, media, stylesheets) to
/// the preview and print web views.
///
/// WebKit's web content process can't read files on other volumes (such as an
/// external disk), whatever read access it's granted. So pages use a private
/// `mdpreview://` base URL and this handler reads the files in the app instead.
enum LocalResources {
    static let scheme = "mdpreview"

    /// One handler, shared by every preview and print web view.
    @MainActor static let handler = SchemeHandler()

    @MainActor
    static func install(in configuration: WKWebViewConfiguration) {
        configuration.setURLSchemeHandler(handler, forURLScheme: scheme)
    }

    /// The base URL for a document's folder, e.g. `mdpreview://local/Volumes/Disk/Notes/`.
    static func baseURL(for directory: URL?) -> URL {
        let folder = (directory ?? FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL.path
        var components = URLComponents()
        components.scheme = scheme
        components.host = "local"
        components.path = folder.hasSuffix("/") ? folder : folder + "/"
        return components.url ?? URL(string: "\(scheme)://local/")!
    }

    /// The file a preview URL refers to, keeping any `#fragment`.
    static func fileURL(for url: URL) -> URL? {
        guard url.scheme == scheme else { return nil }
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/") else { return nil }
        let file = URL(fileURLWithPath: path)
        guard let fragment = url.fragment(percentEncoded: true),
              var components = URLComponents(url: file, resolvingAgainstBaseURL: false) else { return file }
        components.percentEncodedFragment = fragment
        return components.url ?? file
    }

    /// The MIME type to serve a file with, or nil if it isn't something a page
    /// displays (images, audio, video, fonts, stylesheets). Other files are refused.
    static func mimeType(forExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "css": return "text/css"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: break
        }
        guard let type = UTType(filenameExtension: fileExtension),
              [UTType.image, .audiovisualContent, .font].contains(where: { type.conforms(to: $0) }) else { return nil }
        return type.preferredMIMEType ?? "application/octet-stream"
    }

    @MainActor
    final class SchemeHandler: NSObject, WKURLSchemeHandler {
        /// Requests in flight. The task objects stay on the main thread; only
        /// their IDs travel to the background read.
        private var pending: [ObjectIdentifier: any WKURLSchemeTask] = [:]
        /// The folder each web view may read from (see `DocumentFolder`).
        private let roots = NSMapTable<WKWebView, NSURL>.weakToStrongObjects()

        /// Lets `webView` load files inside `root` only; nil serves nothing
        /// (an untitled document has no folder of its own).
        func allow(_ root: URL?, for webView: WKWebView) {
            if let root { roots.setObject(root as NSURL, forKey: webView) } else { roots.removeObject(forKey: webView) }
        }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url, let file = LocalResources.fileURL(for: url) else {
                task.didFailWithError(URLError(.badURL))
                return
            }
            let root = roots.object(forKey: webView) as URL?
            let id = ObjectIdentifier(task)
            pending[id] = task
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.read(file, inside: root)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Gone if WebKit cancelled it meanwhile.
                        guard let task = self.pending.removeValue(forKey: id) else { return }
                        switch result {
                        case .success(let (data, mimeType)):
                            let response = HTTPURLResponse(
                                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": mimeType, "Content-Length": String(data.count)]
                            ) ?? URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil)
                            task.didReceive(response)
                            task.didReceive(data)
                            task.didFinish()
                        case .failure(let error):
                            task.didFailWithError(error)
                        }
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
            pending.removeValue(forKey: ObjectIdentifier(task))
        }

        nonisolated private static func read(_ file: URL, inside root: URL?) -> Result<(Data, String), Error> {
            guard let root, DocumentFolder.contains(root, file),
                  let mimeType = LocalResources.mimeType(forExtension: file.pathExtension) else {
                return .failure(URLError(.noPermissionsToReadFile))
            }
            do {
                return .success((try Data(contentsOf: file, options: .mappedIfSafe), mimeType))
            } catch {
                return .failure(error)
            }
        }
    }
}
