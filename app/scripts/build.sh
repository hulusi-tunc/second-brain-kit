#!/bin/bash
# Builds Brain.app, signs it, installs it in ~/Applications and keeps it running with launchd
# (starts at login, back after a crash).
#   scripts/build.sh                 build and install
#   scripts/build.sh --uninstall     stop it and remove the app and its launch agent
# Signing: a stable signature keeps the Microphone and Accessibility permissions across rebuilds.
# It uses BRAIN_SIGN_IDENTITY if set, else your first "Apple Development" certificate (free with
# an Apple ID in Xcode), else an ad-hoc signature: that works, but macOS asks for the permissions
# again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
LABEL=local.secondbrain.app
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$AGENT"; rm -rf "$HOME/Applications/Brain.app"
  echo "removed. Your notes and history in the brain repo are untouched."; exit 0
fi
REPO="$(cd .. && pwd)"
[ -d "$REPO/raw" ] || { echo "app/ must sit inside your second brain repo (no raw/ in $REPO)"; exit 1; }
[ -f vendor/whisper.cpp/build/src/libwhisper.a ] || scripts/whisper.sh
LOGB="${TMPDIR:-/tmp}/brain-build.log"
swift build -c release > "$LOGB" 2>&1 || { grep -E "error" "$LOGB" | head -5; echo "BUILD FAILED, nothing installed (full log: $LOGB)"; exit 1; }
APP=build/Brain.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Brain "$APP/Contents/MacOS/Brain"
cp Resources/Geist-Variable.ttf Resources/Geist-LICENSE.txt "$APP/Contents/Resources/"
VERSION=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo 1)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>Brain</string>
  <key>CFBundleDisplayName</key><string>Brain</string>
  <key>CFBundleExecutable</key><string>Brain</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>BrainRepo</key><string>${REPO}</string>
  <key>NSMicrophoneUsageDescription</key><string>Brain listens only while you hold the talk key and during calls you have. It turns speech into text on this Mac.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Brain reads your calendar to prepare you five minutes before a call and to name the call's notes.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Brain records your calls' audio on this Mac, so the notes hear the other side clearly. Audio is deleted after 7 days.</string>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Brain</string><key>CFBundleURLSchemes</key><array><string>brain</string></array></dict></array>
  <key>NSServices</key><array>
    <dict><key>NSMenuItem</key><dict><key>default</key><string>Ask Brain</string></dict><key>NSMessage</key><string>askBrain</string><key>NSPortName</key><string>Brain</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>NSStringPboardType</string></array><key>NSRequiredContext</key><dict/></dict>
    <dict><key>NSMenuItem</key><dict><key>default</key><string>Save to Brain</string></dict><key>NSMessage</key><string>saveToBrain</string><key>NSPortName</key><string>Brain</string>
      <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>NSStringPboardType</string></array><key>NSRequiredContext</key><dict/></dict>
  </array>
</dict></plist>
PLIST
IDENTITY="${BRAIN_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | awk '{print $2}' || true)}"
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP" 2>&1 | grep -v "replacing existing" || true
  echo "signed with your Apple Development certificate"
else
  codesign --force --sign - "$APP" 2>&1 | grep -v "replacing existing" || true
  echo "signed ad-hoc: macOS will ask for Microphone and Accessibility again after each rebuild"
fi
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
# an older build under another launch agent would start a second copy of the same app: retire it
for old in "$HOME"/Library/LaunchAgents/*.plist; do
  [ -f "$old" ] && [ "$old" != "$AGENT" ] || continue
  grep -q "Applications/Brain.app" "$old" || continue
  launchctl bootout "gui/$(id -u)" "$old" 2>/dev/null || true
  rm -f "$old"; echo "removed an older launch agent: $(basename "$old")"
done
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for i in $(seq 1 20); do pgrep -x Brain >/dev/null || break; sleep 0.2; done
rm -rf "$HOME/Applications/Brain.app" && cp -R "$APP" "$HOME/Applications/Brain.app"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>Program</key><string>$HOME/Applications/Brain.app/Contents/MacOS/Brain</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/Brain-launchd.log</string>
</dict></plist>
PLIST
for i in $(seq 1 25); do launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break; sleep 0.2; done
for i in 1 2 3; do launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null && break; sleep 1; done
for i in $(seq 1 25); do pgrep -x Brain >/dev/null && break; sleep 0.2; done
pgrep -x Brain >/dev/null && echo "installed and running: ~/Applications/Brain.app" || echo "installed, but not running: see ~/Library/Logs/Brain.log"
