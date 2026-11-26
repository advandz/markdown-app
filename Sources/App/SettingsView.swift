//
//  SettingsView.swift
//  Markdown
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    /// Closes Settings (the Done button).
    let done: () -> Void
    /// A fixed height that makes the form scroll, for windows too short to show
    /// it all; nil sizes Settings to fit its content.
    var height: CGFloat? = nil

    @AppStorage(Preferences.editorFont) private var font = EditorFont.monospaced.rawValue
    @AppStorage(Preferences.fontSize) private var fontSize = 14.0
    @AppStorage(Preferences.limitLineWidth) private var limitLineWidth = true
    @AppStorage(Preferences.checkSpelling) private var checkSpelling = true
    @AppStorage(Preferences.openMode) private var openMode = ViewMode.preview.rawValue
    @AppStorage(Preferences.showWordCount) private var showWordCount = true
    @AppStorage(Preferences.loadRemoteImages) private var loadRemoteImages = true
    @AppStorage(Preferences.checkForUpdates) private var checkForUpdates = true
    @AppStorage(Preferences.lastUpdateCheck) private var lastUpdateCheck = 0.0
    @State private var isDefaultApp = false

    private let markdown = UTType("net.daringfireball.markdown") ?? .plainText

    var body: some View {
        let content = VStack(spacing: 0) {
            form.scrollDisabled(height == nil)
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
        .onAppear(perform: refreshDefault)

        if let height {
            content.frame(height: height)
        } else {
            content.fixedSize(horizontal: false, vertical: true)
        }
    }

    private var form: some View {
        Form {
            Section("Editor") {
                Picker("Font", selection: $font) {
                    ForEach(EditorFont.allCases) { Text($0.title).tag($0.rawValue) }
                }
                LabeledContent("Size") {
                    HStack(spacing: 6) {
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper("Size", value: $fontSize, in: 10...32, step: 1)
                            .labelsHidden()
                    }
                }
                Toggle("Limit line width", isOn: $limitLineWidth)
                Toggle("Check spelling while typing", isOn: $checkSpelling)
            }

            Section("Documents") {
                Picker("Open files in", selection: $openMode) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Show word count", isOn: $showWordCount)
                Toggle("Load remote images", isOn: $loadRemoteImages)
            }

            Section {
                LabeledContent {
                    Button("Extensions…") { openExtensionSettings() }
                } label: {
                    Text("Quick Look previews")
                    Text("Select a Markdown file in Finder and press Space.")
                }
                LabeledContent {
                    Button(isDefaultApp ? String(localized: "Default") : String(localized: "Make Default")) { makeDefault() }
                        .disabled(isDefaultApp)
                } label: {
                    Text("Default app for .md files")
                    Text("Open Markdown files in this app with a double-click.")
                }
            } header: {
                Text("System")
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $checkForUpdates)
                LabeledContent {
                    Button("Check Now") { Updater.shared.checkForUpdates(nil) }
                } label: {
                    Text(verbatim: "Markdown \(AppVersion.current)")
                    Text(lastCheckedDescription)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var lastCheckedDescription: String {
        guard lastUpdateCheck > 0 else { return String(localized: "Not checked yet") }
        let date = Date(timeIntervalSince1970: lastUpdateCheck)
        return String(localized: "Last checked \(date.formatted(.relative(presentation: .named)))")
    }

    private func refreshDefault() {
        let current = NSWorkspace.shared.urlForApplication(toOpen: markdown)
        isDefaultApp = current.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
    }

    private func makeDefault() {
        Task {
            try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: markdown)
            refreshDefault()
        }
    }

    private func openExtensionSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?ExtensionItems",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}
