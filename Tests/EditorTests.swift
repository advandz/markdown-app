//
//  EditorTests.swift
//  Markdown
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

// Headless checks for editor logic and rendering. Run with ./build.sh test
import AppKit
import CryptoKit

@main
enum EditorTests {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition { print("  ✓ \(name)") } else { failures += 1; print("  ✗ \(name) \(detail())") }
    }

    static func editor(_ text: String, caret: Int? = nil) -> MarkdownTextView {
        let (_, view) = MarkdownTextView.makeScrollable()
        view.string = text
        view.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        return view
    }

    static func main() {
        _ = NSApplication.shared
        Preferences.registerDefaults()

        print("List continuation")
        var v = editor("- [ ] Apples")
        v.insertNewline(nil)
        check("checklist continues", v.string == "- [ ] Apples\n- [ ] ", v.string.debugDescription)
        v = editor("1. One")
        v.insertNewline(nil)
        check("numbered list increments", v.string == "1. One\n2. ", v.string.debugDescription)
        v = editor("  * Nested")
        v.insertNewline(nil)
        check("indent and marker kept", v.string == "  * Nested\n  * ", v.string.debugDescription)
        v = editor("- one\n- ")
        v.insertNewline(nil)
        check("empty item ends list", v.string == "- one\n", v.string.debugDescription)
        v = editor("> quote")
        v.insertNewline(nil)
        check("quote continues", v.string == "> quote\n> ", v.string.debugDescription)
        v = editor("plain")
        v.insertNewline(nil)
        check("plain newline", v.string == "plain\n", v.string.debugDescription)

        print("Formatting")
        v = editor("word")
        v.setSelectedRange(NSRange(location: 0, length: 4))
        v.mdBold(nil)
        check("bold wraps", v.string == "**word**", v.string)
        v.mdBold(nil)
        check("bold toggles off", v.string == "word", v.string)
        v = editor("a\nb")
        v.setSelectedRange(NSRange(location: 0, length: 3))
        v.mdBulletList(nil)
        check("bullets added", v.string == "- a\n- b", v.string.debugDescription)
        v.setSelectedRange(NSRange(location: 0, length: 7))
        v.mdBulletList(nil)
        check("bullets removed", v.string == "a\nb", v.string.debugDescription)
        v.setSelectedRange(NSRange(location: 0, length: 3))
        v.mdNumberedList(nil)
        check("numbered list", v.string == "1. a\n2. b", v.string.debugDescription)
        v = editor("Title")
        v.mdHeading2(nil)
        check("heading 2", v.string == "## Title", v.string)
        v.mdHeading1(nil)
        check("heading 1 replaces level", v.string == "# Title", v.string)
        v.mdHeading1(nil)
        check("heading toggles off", v.string == "Title", v.string)
        v = editor("- item")
        v.insertTab(nil)
        check("tab indents list item", v.string == "    - item", v.string.debugDescription)
        v.insertBacktab(nil)
        check("shift-tab outdents", v.string == "- item", v.string.debugDescription)

        print("Highlighting & rendering")
        let sample = (try? String(contentsOfFile: "Samples/Welcome.md", encoding: .utf8)) ?? MarkdownGuide.text
        v = editor(sample)
        v.applyPreferences()
        check("highlighter ran", v.textStorage?.length == (sample as NSString).length)
        let fences = MarkdownHighlighter.fencedBlocks(in: "---\na: 1\n---\ntext\n```js\nx\n```\n~~~\nopen" as NSString)
        check("front matter + 2 fences", fences.count == 3, "\(fences.count)")
        check("closed fence has 2 lines", fences.count == 3 && fences[1].fences.count == 2)
        check("unclosed fence runs to end", fences.count == 3 && fences[2].fences.count == 1)
        let rule = MarkdownHighlighter.fencedBlocks(in: "---\nnot front matter\n```\ncode\n```" as NSString)
        check("unclosed '---' is a rule", rule.count == 1, "\(rule.count)")
        let inline = MarkdownHighlighter.fencedBlocks(in: "```not`a fence\ntext" as NSString)
        check("backticks in info string", inline.isEmpty)

        let html = MarkdownRenderer.html(from: sample)
        for needle in ["<h1 id=", "<table>", "<pre><code class=\"language-swift\"", "type=\"checkbox\" disabled checked",
                       "<blockquote>", "<hr>", "<details>", "<del>", "<ol>"] {
            check("renders \(needle)", html.contains(needle))
        }
        let badge = MarkdownRenderer.html(from: "[![b](x.svg)](https://a.b)")
        check("linked image", badge.contains("<a href=\"https://a.b\"><img src=\"x.svg\""), badge)
        let table = MarkdownRenderer.html(from: "| a | b |\n|--|--|\n| 1 |  |\n")
        check("empty cells padded", table.contains("<td>1</td><td></td>"), table)
        let script = MarkdownRenderer.html(from: "Hi <b>there</b> & `<x>`")
        check("escaping", script.contains("&amp;") && script.contains("<code>&lt;x&gt;</code>"), script)

        print("Update versions")
        check("parses v-prefixed tag", AppVersion("v1.2.3")?.components == [1, 2, 3])
        check("parses bare tag", AppVersion("2.0")?.description == "2.0.0")
        check("ignores pre-releases", AppVersion("1.3.0-beta.1") == nil)
        check("ignores non-version tags", AppVersion("latest") == nil && AppVersion("v1..2") == nil)
        check("numeric, not text, order", AppVersion("1.10.0")! > AppVersion("1.9.9")!)
        check("1.0 equals 1.0.0", AppVersion("1.0")! == AppVersion("1.0.0")!)
        check("patch is newer", AppVersion("v1.0.1")! > AppVersion("1.0.0")!)
        let release = "https://github.com/\(Updater.repository)/releases/download/v1.0.1/Markdown-1.0.1.dmg"
        check("release download trusted", Updater.isTrusted(URL(string: release)!))
        check("repository match ignores case",
              Updater.isTrusted(URL(string: "https://GitHub.com/Advandz/Markdown-App/releases/download/v1/a.dmg")!))
        check("other GitHub paths refused", !Updater.isTrusted(URL(string: "https://github.com/a.dmg")!)
              && !Updater.isTrusted(URL(string: "https://github.com/someone/else/releases/download/v1/a.dmg")!))
        check("other hosts refused",
              !Updater.isTrusted(URL(string: "https://example.com/\(Updater.repository)/releases/download/v1/a.dmg")!))
        check("plain http refused", !Updater.isTrusted(URL(string: release.replacingOccurrences(of: "https:", with: "http:"))!))
        check("this Mac allowed for testing", Updater.isTrusted(URL(string: "http://127.0.0.1:8000/a.dmg")!))

        print("Update signatures")
        let signingKey = Curve25519.Signing.PrivateKey()
        let publicKey = signingKey.publicKey.rawRepresentation
        let dmgFile = FileManager.default.temporaryDirectory.appendingPathComponent("MarkdownTests-\(UUID().uuidString).dmg")
        let imageData = Data((0..<4096).map { UInt8($0 % 251) })
        try? imageData.write(to: dmgFile)
        defer { try? FileManager.default.removeItem(at: dmgFile) }
        let signature = try! signingKey.signature(for: imageData)
        check("genuine update verifies", UpdateSignature.isValid(signature, of: dmgFile, publicKey: publicKey))
        var tampered = imageData; tampered[100] ^= 0xFF
        try? tampered.write(to: dmgFile)
        check("tampered update refused", !UpdateSignature.isValid(signature, of: dmgFile, publicKey: publicKey))
        try? imageData.write(to: dmgFile)
        let otherKey = Curve25519.Signing.PrivateKey()
        check("update signed by another key refused",
              !UpdateSignature.isValid(try! otherKey.signature(for: imageData), of: dmgFile, publicKey: publicKey))
        let sigFile = Data((signature.base64EncodedString() + "\n").utf8)
        check(".sig file decodes", UpdateSignature.decodeSignature(sigFile) == signature)
        check("malformed .sig refused", UpdateSignature.decodeSignature(Data("not a signature".utf8)) == nil
              && UpdateSignature.decodeSignature(Data(String(repeating: "A", count: 2000).utf8)) == nil)
        check("public key decodes", UpdateSignature.decodeKey(publicKey.base64EncodedString()) == publicKey
              && UpdateSignature.decodeKey("short") == nil)
        let unsigned = AvailableUpdate(version: AppVersion("9.9.9")!, tag: "v9.9.9", notes: "",
                                       downloadURL: URL(string: release)!, signature: nil, pageURL: URL(string: release)!)
        check("unsigned update isn't installable", !unsigned.canVerify)

        print("Text encodings")
        let latin1 = "# Café crème\n"
        let decodedLatin1 = TextDecoding.decode(latin1.data(using: .isoLatin1)!)
        check("Latin-1 reads as text", decodedLatin1.text == latin1, decodedLatin1.text.debugDescription)
        let quotes = "He said \u{201C}hi\u{201D} \u{2014} ok\n"
        let decodedQuotes = TextDecoding.decode(quotes.data(using: .windowsCP1252)!)
        check("Windows-1252 reads as text", decodedQuotes.text == quotes && decodedQuotes.encoding == .windowsCP1252,
              decodedQuotes.text.debugDescription)
        check("UTF-16 needs its byte-order mark", TextDecoding.decode("# Café\n".data(using: .utf16)!) == ("# Café\n", .utf16))
        check("UTF-8 stays UTF-8", TextDecoding.decode(Data("# Café ✓\n".utf8)) == ("# Café ✓\n", .utf8))
        let document = MarkdownDocument()
        let original = quotes.data(using: .windowsCP1252)!
        try? document.read(from: original, ofType: MarkdownDocument.markdownType)
        check("saves in the file's encoding", (try? document.data(ofType: MarkdownDocument.markdownType)) == original)

        print("Links")
        func link(_ string: String) -> LinkPolicy.Action { LinkPolicy.action(for: URL(string: string)!) }
        check("web and mail open", link("https://a.b/c") == .open && link("mailto:a@b.c") == .open)
        check("Markdown opens here", link("file:///tmp/notes/readme.md") == .openDocument)
        check("viewable files open", link("file:///tmp/x/photo.png") == .openFile && link("file:///tmp/x/doc.pdf") == .openFile)
        check("scripts and apps are only revealed",
              ["run.command", "tool.sh", "setup.pkg", "Thing.app", "page.html", "art.svg", "disk.dmg"].allSatisfy {
                  link("file:///tmp/x/\($0)") == .reveal
              })
        check("other schemes need a yes", link("smb://server/share") == .confirm && link("ssh://host") == .confirm)
        check("script links do nothing", link("javascript:alert(1)") == .ignore && link("data:text/html,x") == .ignore)

        print("Document folders")
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("MarkdownTests-\(UUID().uuidString)")
        let repo = sandbox.appendingPathComponent("repo"), docs = repo.appendingPathComponent("docs")
        let plain = sandbox.appendingPathComponent("plain"), outside = sandbox.appendingPathComponent("outside")
        for folder in [repo.appendingPathComponent(".git"), docs, repo.appendingPathComponent("images"), plain, outside] {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try? fm.createSymbolicLink(at: repo.appendingPathComponent("escape"), withDestinationURL: outside)
        fm.createFile(atPath: outside.appendingPathComponent("b.png").path, contents: Data([0x89]))
        defer { try? fm.removeItem(at: sandbox) }
        let docsRoot = DocumentFolder.root(for: docs)
        check("repository is the root", docsRoot.resolvingSymlinksInPath().path == repo.resolvingSymlinksInPath().path, docsRoot.path)
        check("plain folder is its own root",
              DocumentFolder.root(for: plain).resolvingSymlinksInPath().path == plain.resolvingSymlinksInPath().path)
        check("files in the repository allowed", DocumentFolder.contains(docsRoot, repo.appendingPathComponent("images/a.png")))
        check("files outside refused", !DocumentFolder.contains(docsRoot, outside.appendingPathComponent("b.png"))
              && !DocumentFolder.contains(docsRoot, docs.appendingPathComponent("../../outside/b.png")))
        check("links out of the folder refused", !DocumentFolder.contains(docsRoot, repo.appendingPathComponent("escape/b.png")))

        print("Page policy")
        let quickLook = PreviewTheme.page(body: "<p>x</p>", policy: .quickLook)
        check("QuickLook forbids scripts and remote loads", quickLook.contains("default-src 'none'")
              && quickLook.contains("img-src cid: data:;") && !quickLook.contains("script-src"))
        let notesBase = LocalResources.baseURL(for: URL(fileURLWithPath: "/tmp/notes"))
        let app = PreviewTheme.page(body: "", baseURL: notesBase, policy: .app(remoteImages: false))
        let policyIndex = app.range(of: "Content-Security-Policy")?.lowerBound
        let baseIndex = app.range(of: "<base ")?.lowerBound
        check("policy comes before <base>", policyIndex != nil && baseIndex != nil && policyIndex! < baseIndex!)
        check("remote images follow the setting", !app.contains("https:")
              && PreviewTheme.page(body: "", policy: .app(remoteImages: true)).contains("img-src mdpreview: data: https:"))
        check("exports carry no policy", !PreviewTheme.page(body: "").contains("Content-Security-Policy"))

        print("Sanitizing for QuickLook")
        let hostile = """
        <p align="center"><img src="logo.png" width="80" onerror="alert(1)"></p>
        <script>steal()</script><style>@import url(https://x.y/a.css)</style>
        <iframe src="https://x.y"></iframe><svg onload="x()"><circle/></svg>
        <a href="javascript:alert(1)">bad</a> <a href="https://ok.example">good</a> <a href="&#106;avascript:x">enc</a>
        <img src="https://tracker.example/p.png"><img src="data:image/png;base64,AA"><details open><summary>More</summary>Hidden</details>
        <meta http-equiv="refresh" content="0;url=https://x.y"><form action="https://x.y"><input name="q"></form>

        [md link](javascript:alert(2)) and [fine](https://fine.example) and ![remote](https://tracker.example/q.png)
        """
        let safe = MarkdownRenderer.html(from: hostile, imageSource: { $0 == "logo.png" ? "cid:image-0" : nil }, sanitize: true)
        let forbidden = ["<script", "steal()", "<style", "@import", "<iframe", "<svg", "onload", "onerror",
                         "javascript:", "&#106;", "tracker.example", "<meta", "<form", "<input"]
        check("no scripts, frames, remote loads or handlers", forbidden.allSatisfy { !safe.contains($0) },
              forbidden.filter { safe.contains($0) }.joined(separator: ", "))
        let kept = ["<p align=\"center\">", "<img src=\"cid:image-0\" width=\"80\">", "href=\"https://ok.example\"",
                    "data:image/png", "<details open=\"\">", "<summary>", "href=\"https://fine.example\""]
        check("safe formatting kept", kept.allSatisfy { safe.contains($0) }, kept.filter { !safe.contains($0) }.joined(separator: ", "))
        check("app rendering untouched", MarkdownRenderer.html(from: "<b onclick=\"x\">b</b>").contains("onclick"))

        print("QuickLook images")
        var asked: [String] = []
        _ = MarkdownRenderer.html(from: "![a](a.png)\n\n[![b](b.png)](https://x.y)\n") { asked.append($0); return nil }
        check("linked images reach the image hook", asked == ["b.png", "a.png"] || asked == ["a.png", "b.png"], "\(asked)")

        print("Local resources")
        let base = LocalResources.baseURL(for: URL(fileURLWithPath: "/Volumes/My Disk/Notes"))
        check("base URL", base.absoluteString == "mdpreview://local/Volumes/My%20Disk/Notes/", base.absoluteString)
        let image = URL(string: "img/a%20b.png", relativeTo: base)!.absoluteURL
        check("relative image maps to file", LocalResources.fileURL(for: image)?.path == "/Volumes/My Disk/Notes/img/a b.png",
              String(describing: LocalResources.fileURL(for: image)?.path))
        let anchor = LocalResources.fileURL(for: URL(string: "#intro", relativeTo: base)!.absoluteURL)
        check("fragment kept", anchor?.fragment == "intro" && anchor?.path == "/Volumes/My Disk/Notes",
              String(describing: anchor))
        check("other schemes ignored", LocalResources.fileURL(for: URL(string: "https://a.b/c.png")!) == nil)
        let servable = ["png", "svg", "jpg", "gif", "mp4", "css", "woff2", "ttf"].allSatisfy {
            LocalResources.mimeType(forExtension: $0) != nil
        }
        let refused = ["md", "txt", "swift", "plist", "html", ""].allSatisfy {
            LocalResources.mimeType(forExtension: $0) == nil
        }
        check("serves media, not documents", servable && refused)

        print(failures == 0 ? "All tests passed" : "\(failures) test(s) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
