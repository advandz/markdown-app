//
//  DocumentFolder.swift
//  Markdown
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation

/// Which local files a document may show (images, media, stylesheets).
///
/// A document reaches files in its own folder and below. When it sits in a
/// Git repository, it reaches the whole repository, so `../images/a.png`
/// works the way it does on GitHub. Nothing else on the disk is served, so a
/// document can't pull in, say, photos from elsewhere in the home folder.
enum DocumentFolder {
    /// The top of the tree a document in `directory` may read from.
    static func root(for directory: URL) -> URL {
        let start = resolved(directory)
        let home = resolved(FileManager.default.homeDirectoryForCurrentUser)
        var folder = start
        for _ in 0..<32 {
            // The home folder and the disk itself are never a repository root here.
            if folder.path == home.path || folder.path == "/" { break }
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) {
                return folder
            }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        return start
    }

    /// Whether `file` lies inside `root`, after resolving `..` and symbolic links.
    static func contains(_ root: URL, _ file: URL) -> Bool {
        let rootPath = resolved(root).path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return resolved(file).path.hasPrefix(prefix)
    }

    private static func resolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
