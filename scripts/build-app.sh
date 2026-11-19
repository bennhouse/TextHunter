#!/bin/zsh
# Builds TextHunter with SwiftPM, assembles build/TextHunter.app, signs it and installs it
# in ~/Applications.
#   scripts/build-app.sh             build, sign, install
#   NO_INSTALL=1 scripts/build-app.sh  only build/TextHunter.app
#   UNIVERSAL=1 ...                    Apple Silicon + Intel binary (for releases)
#
# Signing uses the local identity in signing/ (not in the repository), so the Screen Recording
# permission survives rebuilds. Without it the build stops; ADHOC=1 signs ad hoc instead
# (macOS will then ask for the permission again after every build).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    swift build -c release --triple arm64-apple-macosx15.0
    swift build -c release --triple x86_64-apple-macosx15.0
    mkdir -p build
    lipo -create -output build/TextHunter-bin \
        .build/arm64-apple-macosx/release/TextHunter \
        .build/x86_64-apple-macosx/release/TextHunter
    BIN="build/TextHunter-bin"
else
    swift build -c release
    BIN=".build/release/TextHunter"
fi
APP="build/TextHunter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TextHunter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

ID="local.texthunter.TextHunter"
KC="$PWD/signing/texthunter.keychain-db"
if [[ "${ADHOC:-0}" == "1" ]]; then
    codesign --force --sign - --identifier "$ID" "$APP"
elif [[ -f "$KC" ]]; then
    security unlock-keychain -p texthunter "$KC"
    # codesign only finds identities in keychains on the search list: add ours for the duration.
    OLD=("${(@f)$(security list-keychains -d user | sed 's/^ *"//; s/"$//')}")
    security list-keychains -d user -s "${OLD[@]}" "$KC"
    codesign --force --keychain "$KC" --sign "TextHunter Local Signing" --identifier "$ID" "$APP" || STATUS=$?
    security list-keychains -d user -s "${OLD[@]}"
    [[ -z "${STATUS:-}" ]] || exit $STATUS
else
    echo "error: signing/texthunter.keychain-db not found. Run with ADHOC=1 to sign ad hoc." >&2
    exit 1
fi
codesign -d -r- "$APP" 2>&1 | grep designated

if [[ "${NO_INSTALL:-0}" != "1" ]]; then
    osascript -e 'tell application id "local.texthunter.TextHunter" to quit' 2>/dev/null || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/TextHunter.app"
    ditto "$APP" "$HOME/Applications/TextHunter.app"
    echo "Installed $HOME/Applications/TextHunter.app"
else
    echo "Built $PWD/$APP"
fi
