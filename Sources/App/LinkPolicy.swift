//
//  LinkPolicy.swift
//  Markdown
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation
import UniformTypeIdentifiers

/// Decides what clicking a link in a document does. Documents can come from
/// anywhere, so a link must never launch an app or run a script by itself.
enum LinkPolicy {
    enum Action: Equatable {
        /// Web and mail links open in the user's browser or mail app.
        case open
        /// Markdown files open in this app.
        case openDocument
        /// Images, PDFs, audio and video open in their usual viewer.
        case openFile
        /// Anything else on disk (apps, scripts, installers, folders) is shown in Finder.
        case reveal
        /// Other URL schemes hand control to another app, so the user confirms first.
        case confirm
        /// Links that can't do anything useful from here.
        case ignore
    }

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdtext"]

    static func action(for url: URL) -> Action {
        guard let scheme = url.scheme?.lowercased() else { return .ignore }
        switch scheme {
        case "http", "https", "mailto":
            return .open
        case "file":
            return fileAction(for: url)
        case "javascript", "data", "about", "blob":
            return .ignore
        default:
            return .confirm
        }
    }

    private static func fileAction(for url: URL) -> Action {
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return .openDocument }
        // Bundles (apps, plug-ins) are folders; judge them by type, not by being a folder.
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true { return .reveal }
        guard let type = values?.contentType ?? UTType(filenameExtension: ext) else { return .reveal }
        let viewable: [UTType] = [.image, .pdf, .audiovisualContent]
        // SVG can carry scripts and usually opens in a web browser.
        let runnable: [UTType] = [.executable, .script, .application, .applicationBundle, .package, .svg]
        if runnable.contains(where: type.conforms(to:)) { return .reveal }
        return viewable.contains(where: type.conforms(to:)) ? .openFile : .reveal
    }
}
