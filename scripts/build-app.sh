#!/bin/bash
# Builds the optimized binary and wraps it into build/MicroDiff.app.
#   scripts/build-app.sh
# Then:  open build/MicroDiff.app --args /path/to/repo
#   or:  build/MicroDiff.app/Contents/MacOS/MicroDiff /path/to/repo
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/MicroDiff.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Copy next to the target and rename over it: a window that is still open keeps running its old copy
# instead of having its program file rewritten underneath it.
cp .build/release/MicroDiff "$APP/Contents/MacOS/MicroDiff.new"
mv -f "$APP/Contents/MacOS/MicroDiff.new" "$APP/Contents/MacOS/MicroDiff"
# The app icon (rebuild it from the Figma exports with scripts/make-icon.sh).
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# LSMultipleInstancesProhibited: opened through LaunchServices (Finder, `open`) a running copy is brought forward
# instead of starting a second one. Starts from the terminal (scripts/microdiff) find the running copy themselves.
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MicroDiff</string>
    <key>CFBundleDisplayName</key><string>MicroDiff</string>
    <key>CFBundleIdentifier</key><string>dev.microdiff.app</string>
    <key>CFBundleExecutable</key><string>MicroDiff</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSMultipleInstancesProhibited</key><true/>
</dict>
</plist>
EOF

# Ad-hoc signature: enough to run on this Mac.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "note: codesign failed; the app still runs from Terminal"

echo "$APP"
