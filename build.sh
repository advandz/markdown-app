#!/bin/zsh
#
#  build.sh
#  Markdown
#
#  Copyright © 2026 Advandz Technologies, LLC.
#

# Builds "Markdown.app" (with its QuickLook preview extension) as a universal
# app for Apple silicon and Intel, and packs it into a DMG. Uses Apple's
# command-line tools only; there is no Xcode project.
#
#   ./build.sh            build the app and DMG into ./build
#   ./build.sh install    build, copy to ~/Applications and register QuickLook
#   ./build.sh run        install, then launch the app
#   ./build.sh test       run the headless editor & renderer tests
#
#   ARCHS=arm64 ./build.sh   build for one architecture only (faster while developing)
set -euo pipefail
cd "${0:A:h}"

APP_NAME="Markdown"
BUNDLE_ID="com.mdreader.MDReader"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
OBJ_DIR="$BUILD_DIR/obj"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/App-Info.plist)"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
DEPLOYMENT_TARGET="26.0"
ARCHS=(${=ARCHS:-arm64 x86_64})
SDK="$(xcrun --sdk macosx --show-sdk-path)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

SWIFTFLAGS=(-sdk "$SDK" -swift-version 5 -O -whole-module-optimization -parse-as-library)

if [[ "${1:-}" == "test" ]]; then
  mkdir -p "$BUILD_DIR"
  echo "› Compiling tests"
  APP_SOURCES=(Sources/App/*.swift)
  mkdir -p "$OBJ_DIR/strings"
  swiftc -sdk "$SDK" -target "$(uname -m)-apple-macos$DEPLOYMENT_TARGET" -swift-version 5 -parse-as-library \
    -module-name Markdown Sources/Shared/*.swift ${APP_SOURCES:#*/main.swift} Tests/*.swift \
    -emit-localized-strings -emit-localized-strings-path "$OBJ_DIR/strings" \
    -o "$BUILD_DIR/EditorTests"
  "$BUILD_DIR/EditorTests"
  echo "Localizations"
  swift Tools/CheckLocalizations.swift "$OBJ_DIR/strings" Support/Localization/App
  exit $?
fi

echo "› Cleaning"
rm -rf "$APP" "$OBJ_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns" "$OBJ_DIR"

# Compiles once per architecture (in parallel) and merges the slices with lipo.
#   compile <output> <swiftc arguments…>
compile() {
  local output="$1"; shift
  local slices=() pids=()
  for arch in $ARCHS; do
    local slice="$OBJ_DIR/${output:t}-$arch"
    swiftc "${SWIFTFLAGS[@]}" -target "$arch-apple-macos$DEPLOYMENT_TARGET" "$@" -o "$slice" &
    pids+=($!)
    slices+=("$slice")
  done
  for pid in $pids; do wait $pid; done
  lipo -create "${slices[@]}" -output "$output"
}

echo "› Compiling MarkdownQuickLook (${(j:, :)ARCHS})"
APPEX="$APP/Contents/PlugIns/MarkdownQuickLook.appex"
mkdir -p "$APPEX/Contents/MacOS"
compile "$APPEX/Contents/MacOS/MarkdownQuickLook" \
  -application-extension -module-name MarkdownQuickLook \
  Sources/Shared/*.swift Sources/QuickLook/*.swift -framework QuickLookUI \
  -Xlinker -e -Xlinker _NSExtensionMain
cp Support/QuickLook-Info.plist "$APPEX/Contents/Info.plist"
mkdir -p "$APPEX/Contents/Resources"
ditto Support/Localization/QuickLook "$APPEX/Contents/Resources"
codesign --force --sign - --timestamp=none --entitlements Support/Extension.entitlements "$APPEX"

echo "› Compiling $APP_NAME (${(j:, :)ARCHS})"
compile "$APP/Contents/MacOS/Markdown" -module-name Markdown Sources/Shared/*.swift Sources/App/*.swift

cp Support/App-Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Translations: one <language>.lproj folder per language.
ditto Support/Localization/App "$APP/Contents/Resources"

# App icon. Support/AppIcon.icon is an Icon Composer document (Liquid Glass,
# with Default, Dark, Clear and Tinted appearances). Compiling it needs Xcode's
# actool; without Xcode the static AppIcon.icns rendered from it is used.
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if xcrun --find actool >/dev/null 2>&1; then
  echo "› Compiling Liquid Glass icon"
  if xcrun actool Support/AppIcon.icon \
      --compile "$APP/Contents/Resources" \
      --platform macosx --target-device mac --minimum-deployment-target "$DEPLOYMENT_TARGET" \
      --app-icon AppIcon --include-all-app-icons \
      --output-partial-info-plist "$OBJ_DIR/AppIcon-partial.plist" \
      --errors --warnings >/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist"
  else
    echo "  actool failed; using the static AppIcon.icns" >&2
  fi
else
  echo "› Using static icon (install Xcode to compile the Liquid Glass AppIcon.icon)"
fi

echo "› Signing (ad-hoc)"
codesign --force --sign - --timestamp=none --entitlements Support/App.entitlements "$APP"
codesign --verify --strict "$APP"

# Keep LaunchServices from registering this build copy as a second app.
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
echo "✓ Built $APP ($(lipo -archs "$APP/Contents/MacOS/Markdown"))"

# Disk image: the app plus a shortcut to /Applications to drag it onto.
echo "› Packing $DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE:?}"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "✓ Packed $DMG"

# Update signature. Installed copies only install an update whose disk image is
# signed with the key matching MarkdownUpdatePublicKey (see Tools/SignUpdate.swift).
rm -f "$DMG.sig"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :MarkdownUpdatePublicKey' Support/App-Info.plist 2>/dev/null || true)"
if [[ -z "$PUBLIC_KEY" ]]; then
  echo "  No MarkdownUpdatePublicKey in Support/App-Info.plist: this build won't install updates by itself." >&2
elif swift Tools/SignUpdate.swift sign "$DMG" --expect "$PUBLIC_KEY" >/dev/null; then
  echo "✓ Signed $DMG.sig"
else
  echo "  $DMG is unsigned, so installed copies won't install it as an update." >&2
fi

if [[ "${1:-}" == "install" || "${1:-}" == "run" ]]; then
  DEST="$HOME/Applications/$APP_NAME.app"
  echo "› Installing to $DEST"
  mkdir -p "$HOME/Applications"
  # Quit only the copy being replaced; other copies (say, in /Applications) keep running.
  pkill -f "^$DEST/Contents/MacOS/$APP_NAME( |\$)" 2>/dev/null || true
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  "$LSREGISTER" -f -R "$DEST"
  for ext in "$DEST"/Contents/PlugIns/*.appex; do
    pluginkit -a "$ext"
  done
  pluginkit -e use -i "$BUNDLE_ID.QuickLook" || true
  qlmanage -r >/dev/null 2>&1 || true
  qlmanage -r cache >/dev/null 2>&1 || true
  echo "✓ Installed. QuickLook extension registered."
  if [[ "${1:-}" == "run" ]]; then
    open "$DEST"
  fi
fi
