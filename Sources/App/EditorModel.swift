//
//  EditorModel.swift
//  Markdown
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import AppKit
import Observation

struct TextStats: Equatable {
    var words = 0
    var characters = 0
    var lines = 0

    init() {}

    init(_ text: String) {
        characters = text.count
        words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        lines = text.isEmpty ? 0 : text.reduce(into: 1) { if $1.isNewline { $0 += 1 } }
    }

    var readingMinutes: Int { max(1, Int((Double(words) / 230).rounded(.up))) }
}

/// Per-window state. Owns the editor and preview views so they survive
/// switching between Editor, Split and Preview.
@MainActor
@Observable
final class EditorModel {
    var mode: ViewMode {
        didSet { modeDidChange(from: oldValue) }
    }
    var stats = TextStats()
    var splitFraction: CGFloat = 0.5
    var isEmpty = true

    /// Toolbar search. `matchCount` is nil while nothing is being searched.
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            onSearchTextChange?(searchText)
            scheduleSearch()
        }
    }
    var matchCount: Int?

    // Toolbar hooks, set by the window controller.
    @ObservationIgnored var onModeChange: ((ViewMode) -> Void)?
    @ObservationIgnored var onSearchTextChange: ((String) -> Void)?
    @ObservationIgnored var onSearchFocusRequest: (() -> Void)?

    @ObservationIgnored let textView: MarkdownTextView
    @ObservationIgnored let scrollView: NSScrollView
    @ObservationIgnored let preview: PreviewController
    @ObservationIgnored weak var document: MarkdownDocument?

    @ObservationIgnored private let coordinator = EditorCoordinator()
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var appliedPreferences = EditorPreferences.current
    @ObservationIgnored private var matches: [NSRange] = []

    init(text: String, mode: ViewMode, document: MarkdownDocument) {
        self.mode = mode
        self.document = document

        (scrollView, textView) = MarkdownTextView.makeScrollable()
        preview = PreviewController(baseURL: document.fileURL?.deletingLastPathComponent())

        coordinator.model = self
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        textView.applyPreferences()
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesDidChange() }
        })

        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.editorDidScroll() }
        })

        preview.zoom = Preferences.currentFontSize / 14
        render(immediately: true)
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        renderTask?.cancel()
        searchTask?.cancel()
    }

    var text: String { textView.string }

    // MARK: Text

    func textDidChange() {
        render(immediately: false)
        if !searchText.isEmpty { scheduleSearch(jumping: false) }
    }

    func replaceAllText(_ text: String) {
        guard text != textView.string else { return }
        let selection = textView.selectedRange()
        textView.string = text
        textView.highlightAll()
        let location = min(selection.location, (text as NSString).length)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        render(immediately: true)
    }

    private func render(immediately: Bool) {
        renderTask?.cancel()
        let text = textView.string
        isEmpty = text.isEmpty
        renderTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .milliseconds(120))
                if Task.isCancelled { return }
            }
            let result = await Task.detached(priority: .userInitiated) {
                (MarkdownRenderer.html(from: text), TextStats(text))
            }.value
            guard !Task.isCancelled, let self else { return }
            self.preview.setContent(result.0)
            if self.stats != result.1 { self.stats = result.1 }
        }
    }

    // MARK: Search

    private var searchQuery: String { searchText.trimmingCharacters(in: .newlines) }

    private func scheduleSearch(jumping: Bool = true) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            self?.performSearch(jumping: jumping)
        }
    }

    /// Highlights every match and, when `jumping`, reveals the first one at or after the caret.
    private func performSearch(jumping: Bool) {
        let query = searchQuery
        guard !query.isEmpty else {
            matches = []
            textView.highlightMatches([])
            preview.clearFind()
            matchCount = nil
            return
        }

        matches = textView.ranges(of: query)
        textView.highlightMatches(matches)

        if mode == .preview {
            preview.countMatches(query) { [weak self] count in
                MainActor.assumeIsolated { self?.matchCount = count }
            }
            if jumping { preview.find(query) }
            return
        }

        matchCount = matches.count
        guard jumping, !matches.isEmpty else { return }
        let caret = textView.selectedRange().location
        textView.showMatch(matches.first(where: { $0.location >= caret }) ?? matches[0])
        if mode == .split { preview.find(query) }
    }

    /// ⌘G / ⇧⌘G and Return in the search field.
    func findNext(backwards: Bool = false) {
        let query = searchQuery
        guard !query.isEmpty else {
            requestSearchFocus()
            return
        }
        if mode == .preview {
            preview.find(query, backwards: backwards)
            return
        }
        if matches.isEmpty { matches = textView.ranges(of: query) }
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }
        let selection = textView.selectedRange()
        let target = backwards
            ? matches.last(where: { $0.location < selection.location }) ?? matches[matches.count - 1]
            : matches.first(where: { $0.location > selection.location }) ?? matches[0]
        textView.showMatch(target)
        if mode == .split { preview.find(query, backwards: backwards) }
    }

    func requestSearchFocus() {
        onSearchFocusRequest?()
    }

    /// ⌘E: search for the current selection.
    func useSelectionForSearch() {
        if mode == .preview {
            preview.selectedText { [weak self] text in
                MainActor.assumeIsolated {
                    guard let self, !text.isEmpty else { return }
                    self.searchText = text
                }
            }
        } else {
            let selection = textView.selectedRange()
            guard selection.length > 0 else { return }
            searchText = (textView.string as NSString).substring(with: selection)
        }
    }

    // MARK: Mode, preferences & scrolling

    private func modeDidChange(from old: ViewMode) {
        guard mode != old else { return }
        onModeChange?(mode)
        if mode != .preview {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.textView.window else { return }
                window.makeFirstResponder(self.textView)
            }
        }
        if mode == .split {
            DispatchQueue.main.async { [weak self] in self?.editorDidScroll() }
        }
        if !searchText.isEmpty { scheduleSearch(jumping: true) }
    }

    func documentURLDidChange(_ url: URL?) {
        preview.setBaseURL(url?.deletingLastPathComponent())
    }

    /// Any defaults write lands here (window frames, search fields…), so only
    /// restyle when an editor setting actually changed.
    private func preferencesDidChange() {
        let current = EditorPreferences.current
        guard current != appliedPreferences else { return }
        appliedPreferences = current
        textView.applyPreferences()
        preview.zoom = Preferences.currentFontSize / 14
        preview.setRemoteImages(current.remoteImages)
        if !matches.isEmpty { textView.highlightMatches(matches) }
    }

    private func editorDidScroll() {
        guard mode == .split, let documentView = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let scrollable = documentView.frame.height + insets.top + insets.bottom - clip.bounds.height
        guard scrollable > 1 else { preview.scroll(toFraction: 0); return }
        let fraction = (clip.bounds.origin.y + insets.top) / scrollable
        preview.scroll(toFraction: min(max(fraction, 0), 1))
    }
}

/// Bridges NSTextView delegate callbacks to the model.
final class EditorCoordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    weak var model: EditorModel?

    func textDidChange(_ notification: Notification) {
        MainActor.assumeIsolated { model?.textDidChange() }
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        MainActor.assumeIsolated { model?.document?.undoManager }
    }

    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            model?.textView.highlight(editedRange: editedRange)
        }
    }
}

/// The settings that affect how the editor and preview look.
struct EditorPreferences: Equatable {
    var font: EditorFont
    var size: CGFloat
    var limitLineWidth: Bool
    var checkSpelling: Bool
    var remoteImages: Bool

    static var current: EditorPreferences {
        let defaults = UserDefaults.standard
        return EditorPreferences(
            font: Preferences.currentFont,
            size: Preferences.currentFontSize,
            limitLineWidth: defaults.bool(forKey: Preferences.limitLineWidth),
            checkSpelling: defaults.bool(forKey: Preferences.checkSpelling),
            remoteImages: Preferences.loadsRemoteImages
        )
    }
}
