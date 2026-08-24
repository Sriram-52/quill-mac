#!/bin/bash
# Build the release binary and assemble Quill.app.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/Quill.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Quill "$APP/Contents/MacOS/Quill"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signing. Apple Development identities refuse to launch outside
# Xcode's provisioning flow (launchd error 163), so ad-hoc it is. Cost: after
# a rebuild macOS may drop the Accessibility grant — remove and re-add Quill
# in System Settings > Privacy & Security > Accessibility.
codesign --force --sign - "$APP"

# Install to /Applications so it behaves like a real app (Spotlight,
# Launchpad, login items).
rm -rf /Applications/Quill.app
ditto "$APP" /Applications/Quill.app

echo "Built $APP"
echo "Installed to /Applications/Quill.app"
echo "Run:  open /Applications/Quill.app"
