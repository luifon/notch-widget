#!/usr/bin/env bash
# Build the release binary and wrap it in a minimal .app bundle, so macOS shows
# and remembers the calendar-permission prompt (EventKit needs a bundle with a
# usage-description string; a bare binary gets denied silently). Ad-hoc signed
# so the TCC grant sticks to a stable identity.
set -euo pipefail
cd "$(dirname "$0")/.."   # -> app/
export PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin:$PATH"

swift build -c release

APP="NotchWidget.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotchWidget "$APP/Contents/MacOS/NotchWidget"

# Bundle resources (engine icons) so Bundle.module resolves inside the .app.
if [ -d ".build/release/NotchWidget_NotchWidget.bundle" ]; then
  cp -R ".build/release/NotchWidget_NotchWidget.bundle" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NotchWidget</string>
  <key>CFBundleDisplayName</key><string>Notch Widget</string>
  <key>CFBundleExecutable</key><string>NotchWidget</string>
  <key>CFBundleIdentifier</key><string>com.notchwidget.dev</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCalendarsUsageDescription</key>
  <string>Notch Widget shows your next meeting in the menu bar.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Notch Widget shows your next meeting in the menu bar.</string>
</dict>
</plist>
PLIST

# Sign with a STABLE self-signed identity so the calendar (TCC) grant keys on
# the certificate, not the binary hash — the grant survives rebuilds. Resolve
# an identity: an explicit override, else the dedicated cert (mint it with
# tools/codesign/create-identity.sh), else fall back to any existing one, else
# ad-hoc (grant won't persist).
resolve_identity() {
  if [ -n "${NOTCH_CODESIGN_IDENTITY:-}" ]; then echo "$NOTCH_CODESIGN_IDENTITY"; return; fi
  for cn in "NotchWidget Code Signing" "Nucleus Code Signing"; do
    if security find-identity -p codesigning | grep -qF "$cn"; then echo "$cn"; return; fi
  done
}
IDENTITY="$(resolve_identity)"
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "signed with: $IDENTITY"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "warning: no signing identity found — signed ad-hoc; run tools/codesign/create-identity.sh"
  echo "         (calendar grant will NOT persist across rebuilds until then)"
fi
echo "built $(pwd)/$APP"
