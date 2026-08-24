#!/bin/bash
# Build the release binary and assemble Quill.app.
#
#   scripts/make-app.sh              build + install to /Applications
#   scripts/make-app.sh --no-install build only (also implied when CI is set)
#
# Env: QUILL_VERSION (default 0.1.0), QUILL_BUILD (default 1) stamp Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${QUILL_VERSION:-0.1.0}"
BUILD="${QUILL_BUILD:-1}"

swift build -c release

APP="build/Quill.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Quill "$APP/Contents/MacOS/Quill"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $BUILD" \
    "$APP/Contents/Info.plist"

# Ad-hoc signing. Apple Development identities refuse to launch outside
# Xcode's provisioning flow, and there is no Developer ID / notarization yet.
# Cost: after a rebuild macOS may drop the Accessibility grant (remove and
# re-add Quill in System Settings > Privacy & Security > Accessibility), and
# downloaded copies carry a quarantine flag (right-click > Open once).
codesign --force --sign - "$APP"
echo "Built $APP (version $VERSION, build $BUILD)"

if [ "${1:-}" = "--no-install" ] || [ -n "${CI:-}" ]; then
    exit 0
fi

rm -rf /Applications/Quill.app
ditto "$APP" /Applications/Quill.app
echo "Installed to /Applications/Quill.app"
echo "Run:  open /Applications/Quill.app"
