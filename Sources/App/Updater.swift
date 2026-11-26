//
//  Updater.swift
//  Markdown
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import AppKit
import Security
import SwiftUI

// MARK: - Versions

/// A release version such as 1.2.3, parsed from a tag like "v1.2.3".
/// Pre-release tags ("1.2.0-beta") and anything that isn't numeric are ignored.
struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        guard !text.isEmpty, !text.contains("-"), !text.contains("+") else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        components = numbers
    }

    private func padded(to count: Int) -> [Int] {
        components + Array(repeating: 0, count: max(0, count - components.count))
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        return a.padded(to: n).lexicographicallyPrecedes(b.padded(to: n))
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        return a.padded(to: n) == b.padded(to: n)
    }

    var description: String { padded(to: 3).map(String.init).joined(separator: ".") }

    /// The version of the running app.
    static var current: AppVersion {
        AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") ?? AppVersion("0")!
    }
}

// MARK: - GitHub

struct AvailableUpdate {
    let version: AppVersion
    let tag: String
    let notes: String
    /// The disk image attached to the tag's GitHub release, if there is one.
    let downloadURL: URL?
    /// The signature file (`<image>.sig`) attached next to it. Without one, nothing is installed.
    let signatureURL: URL?
    let pageURL: URL
}

enum UpdateError: LocalizedError {
    case server(Int)
    case invalidDownload(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .server(let status): String(localized: "GitHub responded with an error (HTTP \(status)).")
        case .invalidDownload(let reason), .installFailed(let reason): reason
        }
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
    }
    let tagName: String
    let body: String?
    let htmlURL: URL?
    let assets: [Asset]
    enum CodingKeys: String, CodingKey { case body, assets, htmlURL = "html_url", tagName = "tag_name" }
}

// MARK: - Updater

/// Checks the GitHub repository's latest release for a newer version and
/// offers to install it, remind later, or skip that version.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()
    nonisolated static let repository = "advandz/markdown-app"

    private var isChecking = false
    private var pendingUpdate: AvailableUpdate?
    private var installer: UpdateInstaller?
    private var timer: Timer?

    /// The API base URL. A hidden `UpdateFeedURL` default can point it elsewhere
    /// for testing, over HTTPS or to this Mac only. Downloads still have to come
    /// from this repository's releases or this Mac (see `isTrusted`).
    private var feedBase: String {
        if let custom = UserDefaults.standard.string(forKey: "UpdateFeedURL"),
           let url = URL(string: custom), url.scheme == "https" || Self.isLocal(url) {
            return custom
        }
        return "https://api.github.com/repos/\(Self.repository)"
    }

    // MARK: Scheduling

    /// When automatic checks are on: checks every time Markdown starts, then
    /// once a day for as long as it stays open.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkAtLaunch() }
        // Hourly ticks; a check only runs once a day has passed since the last one.
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // An update found while the app was in the background waits until it's in front.
                guard let self, let update = self.pendingUpdate else { return }
                self.pendingUpdate = nil
                self.present(update)
            }
        }
    }

    private func checkAtLaunch() {
        guard UserDefaults.standard.bool(forKey: Preferences.checkForUpdates) else { return }
        check(userInitiated: false)
    }

    private func checkIfDue() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Preferences.checkForUpdates) else { return }
        let last = defaults.double(forKey: Preferences.lastUpdateCheck)
        guard Date().timeIntervalSince1970 - last > 24 * 60 * 60 else { return }
        check(userInitiated: false)
    }

    // MARK: Checking

    @objc func checkForUpdates(_ sender: Any?) {
        check(userInitiated: true)
    }

    func check(userInitiated: Bool) {
        if let installer {
            // An update is downloading or waiting for Markdown to quit.
            if userInitiated { installer.bringToFront() }
            return
        }
        guard !isChecking else { return }
        isChecking = true

        Task {
            defer { isChecking = false }
            do {
                let update = try await fetchNewestUpdate()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Preferences.lastUpdateCheck)

                guard let update, update.version > .current else {
                    if userInitiated { showUpToDate() }
                    return
                }
                // Automatic checks respect "Skip This Version"; asking explicitly always shows it.
                let skipped = UserDefaults.standard.string(forKey: Preferences.skippedVersion)
                if !userInitiated, skipped == update.version.description { return }

                if userInitiated || NSApp.isActive {
                    present(update)
                } else {
                    pendingUpdate = update
                }
            } catch {
                if userInitiated { showCheckFailed(error) }
            }
        }
    }

    /// The latest published release. GitHub leaves out drafts and pre-releases,
    /// so a tag pushed before its release exists is never offered.
    private func fetchNewestUpdate() async throws -> AvailableUpdate? {
        guard let release: GitHubRelease = try await get("releases/latest"),
              let version = AppVersion(release.tagName) else { return nil }

        let encodedTag = release.tagName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? release.tagName
        let dmgAsset = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        let sigAsset = dmgAsset.flatMap { dmg in release.assets.first { $0.name == dmg.name + ".sig" } }
        let page = release.htmlURL
            ?? URL(string: "https://github.com/\(Self.repository)/releases/tag/\(encodedTag)")!

        return AvailableUpdate(
            version: version,
            tag: release.tagName,
            notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            downloadURL: dmgAsset.map(\.browserDownloadURL).flatMap { Self.isTrusted($0) ? $0 : nil },
            signatureURL: sigAsset.map(\.browserDownloadURL).flatMap { Self.isTrusted($0) ? $0 : nil },
            pageURL: page
        )
    }

    /// Fetches and decodes a feed resource; nil when it doesn't exist (no release yet).
    private func get<T: Decodable>(_ path: String) async throws -> T? {
        guard let url = URL(string: "\(feedBase)/\(path)") else { throw UpdateError.server(0) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Markdown/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw UpdateError.server(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Updates download from this repository's GitHub releases over HTTPS
    /// (or from this Mac, when testing).
    nonisolated static func isTrusted(_ url: URL) -> Bool {
        if isLocal(url) { return true }
        return url.scheme == "https" && url.host?.lowercased() == "github.com"
            && url.path.lowercased().hasPrefix("/\(repository.lowercased())/releases/download/")
    }

    nonisolated static func isLocal(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme ?? "") && ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
    }

    // MARK: Prompts

    /// "Install Update", "Later" or "Skip This Version".
    private func present(_ update: AvailableUpdate) {
        NSApp.activate()
        // Unsigned or unverifiable updates are offered as a download page instead,
        // where macOS checks what the user downloads.
        let canInstall = update.downloadURL != nil && update.signatureURL != nil && UpdateInstaller.canReplaceRunningApp

        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        let newVersion = update.version.description, currentVersion = AppVersion.current.description
        alert.messageText = String(localized: "A new version of Markdown is available")
        alert.informativeText = canInstall
            ? String(localized: "Markdown \(newVersion) is available. You have \(currentVersion). Would you like to install it now? Markdown will restart when it's done.")
            : String(localized: "Markdown \(newVersion) is available. You have \(currentVersion).")
        if !update.notes.isEmpty {
            alert.accessoryView = Self.notesView(update.notes)
        }
        alert.addButton(withTitle: canInstall ? String(localized: "Install Update") : String(localized: "View Release"))
        let later = alert.addButton(withTitle: String(localized: "Later"))
        later.keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: String(localized: "Skip This Version"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if canInstall {
                install(update)
            } else {
                NSWorkspace.shared.open(update.pageURL)
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(update.version.description, forKey: Preferences.skippedVersion)
        default:
            break   // Later: ask again at the next check
        }
    }

    private func install(_ update: AvailableUpdate) {
        let installer = UpdateInstaller(update: update)
        installer.onFailure = { [weak self] error in
            self?.installer = nil
            self?.showInstallFailed(error, update: update)
        }
        installer.onCancel = { [weak self] in self?.installer = nil }
        self.installer = installer
        installer.start()
    }

    private func showUpToDate() {
        NSApp.activate()
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        let version = AppVersion.current.description
        alert.messageText = String(localized: "You're up to date")
        alert.informativeText = String(localized: "Markdown \(version) is the newest version available.")
        alert.runModal()
    }

    private func showCheckFailed(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn't check for updates")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func showInstallFailed(_ error: Error, update: AvailableUpdate) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn't install the update")
        let version = update.version.description
        alert.informativeText = error.localizedDescription + "\n\n"
            + String(localized: "You can download Markdown \(version) from GitHub instead.")
        alert.addButton(withTitle: String(localized: "Open GitHub"))
        alert.addButton(withTitle: String(localized: "Close"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(update.pageURL)
        }
    }

    /// Release notes from GitHub, shown under the alert text.
    private static func notesView(_ notes: String) -> NSView {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? NSMutableAttributedString(AttributedString(markdown: notes, options: options)))
            ?? NSMutableAttributedString(string: notes)
        let range = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        attributed.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let base = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            let font = (value as? NSFont).map { NSFontManager.shared.convert($0, toSize: base.pointSize) } ?? base
            attributed.addAttribute(.font, value: font, range: subrange)
        }

        // Fit short notes; scroll long ones.
        let width: CGFloat = 360
        let fitted = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        let height = min(max(ceil(fitted) + 12, 28), 160)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.autoresizingMask = [.width]
        text.textStorage?.setAttributedString(attributed)
        scroll.documentView = text
        return scroll
    }
}

// MARK: - Installer

@MainActor
@Observable
private final class InstallProgress {
    var message = ""
    var fraction: Double? = 0
    var canCancel = true
}

/// Downloads the release's disk image, checks the app inside it, and swaps it
/// in for the running copy once Markdown quits, then relaunches.
@MainActor
final class UpdateInstaller: NSObject {
    let update: AvailableUpdate
    var onFailure: ((Error) -> Void)?
    var onCancel: (() -> Void)?

    private let progress = InstallProgress()
    private var window: NSWindow?
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MarkdownUpdate-\(UUID().uuidString)", isDirectory: true)

    init(update: AvailableUpdate) {
        self.update = update
    }

    /// Updating replaces the app in place, so its folder must be writable and
    /// it mustn't be running from a disk image or a translocated copy.
    static var canReplaceRunningApp: Bool {
        let app = Bundle.main.bundleURL
        let path = app.path
        guard !path.contains("/AppTranslocation/") else { return false }
        let fm = FileManager.default
        return fm.isWritableFile(atPath: app.deletingLastPathComponent().path) && fm.isWritableFile(atPath: path)
    }

    /// The release's signature, fetched before the disk image is downloaded.
    private var signature = ""

    func start() {
        guard let url = update.downloadURL, let signatureURL = update.signatureURL else { return }
        showWindow()
        let version = update.version.description
        progress.message = String(localized: "Downloading Markdown \(version)…")
        Task {
            do {
                signature = try await Self.fetchSignature(signatureURL)
            } catch {
                fail(UpdateError.invalidDownload(String(localized: "The downloaded update isn't signed by Markdown's developer.")))
                return
            }
            guard window != nil else { return }   // cancelled meanwhile
            beginDownload(url)
        }
    }

    /// The signature file is a short base64 line.
    nonisolated private static func fetchSignature(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Markdown/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1024,
              let text = String(data: data, encoding: .utf8) else { throw UpdateError.server(0) }
        return text
    }

    private func beginDownload(_ url: URL) {
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let destination = workDirectory.appendingPathComponent("Markdown-\(update.version).dmg")

        let task = URLSession.shared.downloadTask(with: url) { [weak self] location, response, error in
            // Move the file before this handler returns; URLSession deletes it afterwards.
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var outcome: Result<URL, Error>
            if let error {
                outcome = .failure(error)
            } else if let location, status == 200 || status == 0 {
                do {
                    try FileManager.default.moveItem(at: location, to: destination)
                    outcome = .success(destination)
                } catch {
                    outcome = .failure(error)
                }
            } else {
                outcome = .failure(UpdateError.server(status))
            }
            let result = outcome
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.downloadFinished(result) } }
        }
        observation = task.progress.observe(\.fractionCompleted) { [weak self] value, _ in
            let fraction = value.fractionCompleted
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.progress.fraction = fraction } }
        }
        self.task = task
        task.resume()
    }

    func bringToFront() {
        if isWaitingForQuit {
            promptToQuit()
            return
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func cancel() {
        task?.cancel()
        finish()
        onCancel?()
    }

    private func downloadFinished(_ result: Result<URL, Error>) {
        observation = nil
        switch result {
        case .failure(let error):
            if (error as? URLError)?.code == .cancelled { return }
            fail(error)
        case .success(let dmg):
            let versionText = update.version.description
            progress.message = String(localized: "Installing Markdown \(versionText)…")
            progress.fraction = nil
            progress.canCancel = false
            let target = Bundle.main.bundleURL
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            let version = update.version
            let work = workDirectory
            let signature = signature
            Task.detached {
                do {
                    let staged = try Self.stage(dmg: dmg, signature: signature, work: work, version: version,
                                                bundleID: bundleID, target: target)
                    await MainActor.run { self.relaunch(replacing: target, with: staged) }
                } catch {
                    await MainActor.run { self.fail(error) }
                }
            }
        }
    }

    /// Checks the image's signature, mounts it, checks the app inside and copies
    /// it next to the running app (same volume, so the final swap is a quick rename).
    nonisolated private static func stage(dmg: URL, signature: String, work: URL, version: AppVersion,
                                          bundleID: String, target: URL) throws -> URL {
        // Before anything opens the image: it must carry a valid signature from our
        // key, for this version (see UpdateSigning).
        guard UpdateSigning.verify(file: dmg, version: version.description, signature: signature) else {
            throw UpdateError.invalidDownload(String(localized: "The downloaded update isn't signed by Markdown's developer."))
        }

        let mountPoint = work.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

        let apps = (try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "app" }
        guard let app = apps.first, let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID else {
            throw UpdateError.invalidDownload(String(localized: "The downloaded disk image doesn't contain Markdown."))
        }
        let found = AppVersion(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
        guard let found, found == version else {
            let foundVersion = found?.description ?? String(localized: "unknown")
            let expected = version.description
            throw UpdateError.invalidDownload(String(localized: "The downloaded app is version \(foundVersion), not \(expected)."))
        }
        do {
            try run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        } catch {
            throw UpdateError.invalidDownload(String(localized: "The downloaded app's code signature isn't valid."))
        }
        // Once Markdown is signed by a developer (rather than ad hoc), an update
        // must be signed by the same developer, not merely be intact.
        if let team = teamIdentifier(of: target), teamIdentifier(of: app) != team {
            throw UpdateError.invalidDownload(String(localized: "The downloaded app isn't signed by the same developer."))
        }

        let staged = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.deletingPathExtension().lastPathComponent)-update.app")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", [app.path, staged.path])
        return staged
    }

    /// Hands the swap to a small script that waits for Markdown to quit.
    private func relaunch(replacing target: URL, with staged: URL) {
        let script = workDirectory.appendingPathComponent("install.sh")
        do {
            try Self.installScript.write(to: script, atomically: true, encoding: .utf8)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier),
                                target.path, staged.path, workDirectory.path]
            try helper.run()
        } catch {
            let reason = error.localizedDescription
            fail(UpdateError.installFailed(String(localized: "Couldn't start the installer: \(reason)")))
            return
        }
        progress.message = String(localized: "Restarting Markdown…")
        quitToInstall()
    }

    // MARK: Quitting

    /// Set when the update is staged but quitting was put off.
    private var isWaitingForQuit = false
    /// Tells the helper to reopen Markdown: present only when the user chose to restart.
    private var relaunchMarker: URL { workDirectory.appendingPathComponent("relaunch") }

    /// Quits so the helper can swap the app in. A document can put the quit off
    /// (asking about unsaved changes) or cancel it; the update then waits for
    /// the next time Markdown quits.
    private func quitToInstall() {
        FileManager.default.createFile(atPath: relaunchMarker.path, contents: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            NSApp.terminate(nil)
            // Still running, so the quit didn't go ahead straight away.
            self?.watchForCancelledQuit(idleChecks: 0)
        }
    }

    /// The quit was cancelled once no save prompt has been up for two seconds.
    private func watchForCancelledQuit(idleChecks: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let prompting = NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil }
            let idle = prompting ? 0 : idleChecks + 1
            if idle >= 2 { self.quitWasCancelled() } else { self.watchForCancelledQuit(idleChecks: idle) }
        }
    }

    private func quitWasCancelled() {
        try? FileManager.default.removeItem(at: relaunchMarker)
        isWaitingForQuit = true
        window?.close()
        window = nil
        promptToQuit()
    }

    /// The update is in place and installs whenever Markdown quits.
    private func promptToQuit() {
        NSApp.activate()
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        let version = update.version.description
        alert.messageText = String(localized: "The update is ready to install")
        alert.informativeText = String(localized: "Markdown \(version) will be installed when you quit Markdown.")
        alert.addButton(withTitle: String(localized: "Quit and Install"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn { quitToInstall() }
    }

    private static let installScript = """
    #!/bin/sh
    # Replaces Markdown.app once the running copy has quit, reopens it if the
    # user chose to restart, and removes the download.
    PID="$1"; TARGET="$2"; STAGED="$3"; WORK="$4"
    [ -n "$PID" ] && [ -d "$TARGET" ] && [ -d "$STAGED" ] && [ -d "$WORK" ] || exit 1
    while kill -0 "$PID" 2>/dev/null; do sleep 0.5; done
    BACKUP="${TARGET:?}.previous"
    rm -rf "$BACKUP"
    if mv "$TARGET" "$BACKUP" && mv "$STAGED" "$TARGET"; then
      rm -rf "$BACKUP"
    else
      [ -d "$TARGET" ] || mv "$BACKUP" "$TARGET"
      rm -rf "${STAGED:?}"
    fi
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" >/dev/null 2>&1
    for extension in "$TARGET"/Contents/PlugIns/*.appex; do pluginkit -a "$extension" >/dev/null 2>&1; done
    [ -e "$WORK/relaunch" ] && open "$TARGET"
    rm -rf "${WORK:?}"
    """

    /// The Developer ID team that signed an app, or nil when it's signed ad hoc.
    nonisolated private static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let name = URL(fileURLWithPath: tool).lastPathComponent
            let status = Int(process.terminationStatus)
            throw UpdateError.installFailed(String(localized: "\(name) failed (\(status))."))
        }
    }

    private func fail(_ error: Error) {
        finish()
        onFailure?(error)
    }

    private func finish() {
        observation = nil
        window?.close()
        window = nil
        try? FileManager.default.removeItem(at: workDirectory)
    }

    // MARK: Window

    private func showWindow() {
        let view = UpdateProgressView(progress: progress) { [weak self] in self?.cancel() }
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Updating Markdown")
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct UpdateProgressView: View {
    let progress: InstallProgress
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 12) {
                Text(progress.message)
                    .font(.headline)
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                HStack {
                    Spacer()
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(!progress.canCancel)
                }
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
