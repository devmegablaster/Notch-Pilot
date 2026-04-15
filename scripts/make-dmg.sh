#!/usr/bin/env bash
#
# make-dmg.sh — packages Notch Pilot.app into a distributable DMG.
#
# Uses the stock hdiutil (always present on macOS) to produce a
# drag-to-Applications-style installer DMG. No external tools required.
#
# Prerequisite: run scripts/build.sh first so dist/Notch Pilot.app exists.
#
# Usage: scripts/make-dmg.sh

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Notch Pilot"
# Matches build.sh — CI overrides from the git tag.
VERSION="${VERSION:-0.1.0}"
APP_PATH="dist/${APP_NAME}.app"
DMG_NAME="NotchPilot-${VERSION}.dmg"
DMG_PATH="dist/${DMG_NAME}"
STAGING_DIR="dist/.dmg-staging"

if [ ! -d "${APP_PATH}" ]; then
    echo "❌ ${APP_PATH} not found. Run scripts/build.sh first."
    exit 1
fi

echo "▶ Preparing staging directory..."
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

# Copy the .app and add a symlink to /Applications so the user can just
# drag the app onto it in Finder.
cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "▶ Creating DMG..."
rm -f "${DMG_PATH}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" >/dev/null

rm -rf "${STAGING_DIR}"

echo ""
echo "✅ Built: ${DMG_PATH}"
echo "   Size: $(du -h "${DMG_PATH}" | cut -f1)"
echo ""
echo "Users will:"
echo "  1. Open ${DMG_NAME}"
echo "  2. Drag Notch Pilot.app to Applications"
echo "  3. First launch: right-click → Open (to bypass Gatekeeper)"
