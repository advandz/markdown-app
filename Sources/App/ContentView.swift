//
//  ContentView.swift
//  Markdown
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import AppKit
import SwiftUI
import WebKit

struct ContentView: View {
    @Bindable var model: EditorModel
    @AppStorage(Preferences.showWordCount) private var showWordCount = true

    var body: some View {
        GeometryReader { geometry in
            let topInset = geometry.safeAreaInsets.top
            HStack(spacing: 0) {
                if model.mode != .preview {
                    EditorView(model: model)
                        .frame(width: model.mode == .split
                               ? max(240, (geometry.size.width * model.splitFraction).rounded())
                               : nil)
                }
                if model.mode == .split {
                    SplitDivider(fraction: $model.splitFraction, totalWidth: geometry.size.width)
                }
                if model.mode != .edit {
                    PreviewView(controller: model.preview, topInset: topInset)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottomTrailing) {
            if showWordCount || model.matchCount != nil {
                StatusPill(stats: model.stats, matchCount: model.matchCount)
                    .padding(16)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.smooth(duration: 0.25), value: model.mode)
        .animation(.smooth(duration: 0.2), value: showWordCount)
        .animation(.smooth(duration: 0.2), value: model.matchCount == nil)
        .frame(minWidth: 520, minHeight: 360)
    }
}

// MARK: - Pieces

/// Floating Liquid Glass capsule with document statistics. Click to cycle.
private struct StatusPill: View {
    let stats: TextStats
    var matchCount: Int?
    @AppStorage(Preferences.statusStyle) private var style = 0

    var body: some View {
        Button {
            if matchCount == nil { style = (style + 1) % 3 }
        } label: {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .padding(.horizontal, 4)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .help("Click to show words, characters or lines")
        .animation(.snappy, value: stats)
    }

    private var label: String {
        if let matchCount {
            switch matchCount {
            case 0: return String(localized: "No matches")
            case 1: return String(localized: "1 match")
            default: return String(localized: "\(matchCount.formatted()) matches")
            }
        }
        switch style {
        case 1:
            return stats.characters == 1
                ? String(localized: "1 character")
                : String(localized: "\(stats.characters.formatted()) characters")
        case 2:
            return stats.lines == 1
                ? String(localized: "1 line")
                : String(localized: "\(stats.lines.formatted()) lines")
        default:
            let words = stats.words == 1
                ? String(localized: "1 word")
                : String(localized: "\(stats.words.formatted()) words")
            return stats.words == 0 ? words : String(localized: "\(words) · \(stats.readingMinutes) min read")
        }
    }
}

private struct SplitDivider: View {
    @Binding var fraction: CGFloat
    let totalWidth: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    // SwiftUI owns the cursor, so it can't stick when the divider goes away mid-hover.
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                guard totalWidth > 0 else { return }
                                let proposed = value.location.x / totalWidth
                                fraction = min(max(proposed, 0.2), 0.8)
                            }
                    )
                    .onTapGesture(count: 2) { fraction = 0.5 }
            }
            .ignoresSafeArea()
    }
}

// MARK: - AppKit bridges

private struct EditorView: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> NSScrollView {
        model.scrollView.removeFromSuperview()
        return model.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

private struct PreviewView: NSViewRepresentable {
    let controller: PreviewController
    let topInset: CGFloat

    func makeNSView(context: Context) -> WKWebViewContainer {
        let container = WKWebViewContainer(webView: controller.webView)
        controller.setTopInset(topInset)
        return container
    }

    func updateNSView(_ nsView: WKWebViewContainer, context: Context) {
        controller.setTopInset(topInset)
    }
}

/// Hosts the shared web view so it can move between representable instances.
final class WKWebViewContainer: NSView {
    init(webView: WKWebView) {
        super.init(frame: .zero)
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
