<p align="center">
  <img src="Support/AppIcon.png" width="128" height="128" alt="Markdown app icon">
</p>

<h1 align="center">Markdown</h1>

<p align="center">A native Markdown reader and editor for macOS, with a Liquid Glass design.</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
    <img src="docs/screenshot-light.png" width="760" alt="Markdown in Split view: the Markdown source on the left and the rendered preview on the right">
  </picture>
</p>

## Features

- **Editor, Split and Preview** views (⌘1 / ⌘2 / ⌘3), with a live preview that follows the editor as you scroll
- Syntax highlighting, smart lists and checklists, and formatting shortcuts
- GitHub-style rendering: tables, task lists, fenced code, raw HTML and front matter
- **Search** across the editor and the preview, from the toolbar
- **Export as PDF** or HTML, and print
- **QuickLook**: press Space on a `.md` file in Finder to see it rendered
- **Automatic, signed updates** from this repository's releases
- In English, Spanish, French, German, Italian, Portuguese (Brazil), Japanese, Korean and Chinese (Simplified), following your Mac's language

## Install

Download the latest `Markdown-x.y.z.dmg` from [Releases](https://github.com/advandz/markdown-app/releases), open it and drag **Markdown** to **Applications**.

Requires macOS 26 or later; the app runs natively on Apple silicon and Intel. It isn't notarized, so if macOS can't verify it, choose **Open Anyway** in **System Settings → Privacy & Security**.

## macOS Gatekeeper

Markdown isn't notarized by Apple, so macOS Gatekeeper may stop it the first time you open it. You may see a message such as:

- “Markdown” is damaged and can't be opened. You should move it to the Trash.
- “Markdown” can't be opened because Apple cannot check it for malicious software.
- “Markdown” is not safe to open.

The download isn't corrupt. macOS marks every app downloaded from the internet as quarantined, and Gatekeeper blocks quarantined apps that aren't notarized.

**To open it**

1. Drag **Markdown** to **Applications**, then open it. When macOS blocks it, click **Done** (not **Move to Trash**).
2. Open **System Settings → Privacy & Security** and scroll down to **Security**.
3. Next to the message about Markdown, click **Open Anyway**, then confirm with your password or Touch ID.

**If it says the app is damaged**

That message has no **Open Anyway** button. Remove the quarantine flag in Terminal, then open the app normally:

```bash
xattr -dr com.apple.quarantine "/Applications/Markdown.app"
```

If the app isn't in **Applications**, use its actual path. Only do this for a copy you downloaded from this repository's [Releases](https://github.com/advandz/markdown-app/releases) page.

## Build from source

You need Xcode 26. The Command Line Tools alone also work, but give the app a static icon instead of the Liquid Glass one. Select Xcode once:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -runFirstLaunch
```

Then build:

| Command | What it does |
|:--|:--|
| `./build.sh` | Builds the universal app and `build/Markdown-<version>.dmg` |
| `./build.sh install` | Also installs to `~/Applications` and registers QuickLook |
| `./build.sh test` | Runs the tests and checks that every string is translated |
| `./Tools/make-icon.sh` | Re-renders the icon files from `Support/AppIcon.icon` |

Translations live in `Support/Localization/App/<language>.lproj/Localizable.strings`, keyed by the English text. To add a language, add a folder with every key translated.

## Release

Updates are signed: the app only installs a disk image whose signature matches the public key built into it (`Sources/App/UpdateSigning.swift`), so a forged or tampered download is rejected.

1. One time: `swift Tools/sign-update.swift keygen` creates the private key in `~/.com.advandz.markdown/` (outside this repository) and prints the public key to put in `UpdateSigning.swift`. Back the key up and never commit it. Losing it means existing installs can't be updated automatically.
2. Set the version (`CFBundleShortVersionString` and `CFBundleVersion`) in `Support/App-Info.plist` and `Support/QuickLook-Info.plist`.
3. Run `./build.sh`. It builds the app and DMG and signs the DMG, writing `build/Markdown-<version>.dmg.sig`.
4. Tag and publish, attaching **both** files:

   ```bash
   git tag v1.0.1 && git push origin v1.0.1
   gh release create v1.0.1 build/Markdown-1.0.1.dmg build/Markdown-1.0.1.dmg.sig --title "Markdown 1.0.1"
   ```

The app checks the latest release each time it starts, and once a day while it stays open, and offers to install its DMG after checking the signature. A release without the `.sig` file isn't installed automatically; the app sends people to the release page instead.

## License

Copyright © 2026 Advandz Technologies, LLC. Released under the [MIT License](LICENSE.md).
