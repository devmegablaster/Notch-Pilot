#!/usr/bin/env bash
#
# build.sh — produces a distributable Notch Pilot.app bundle.
#
# - Builds a universal (arm64 + x86_64) release binary via SPM
# - Wraps it in a .app bundle with a proper Info.plist
# - LSUIElement=true so the app has no Dock icon (accessory mode)
# - Output: dist/Notch Pilot.app
#
# Usage: scripts/build.sh

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Notch Pilot"
EXECUTABLE_NAME="NotchPilot"
BUNDLE_ID="com.devmegablaster.notchpilot"
# VERSION / BUILD_NUMBER are overridable from the environment so CI can
# stamp them from a git tag. Local builds fall back to the defaults.
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"

echo "▶ Cleaning previous build..."
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

# Universal (arm64 + x86_64) builds require full Xcode. If the user only
# has Command Line Tools installed, SPM's multi-arch flag fails. Try the
# universal path first and fall back to a single-arch host build.
BINARY_PATH=""
echo "▶ Attempting universal build (arm64 + x86_64)..."
if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
    BINARY_PATH=".build/apple/Products/Release/${EXECUTABLE_NAME}"
    echo "   ✓ Universal build succeeded."
else
    HOST_ARCH="$(uname -m)"
    echo "   ℹ️  Universal build failed (needs full Xcode). Falling back to ${HOST_ARCH}-only."
    swift build -c release
    BINARY_PATH=".build/release/${EXECUTABLE_NAME}"
fi

if [ ! -f "${BINARY_PATH}" ]; then
    echo "❌ Expected binary not found at ${BINARY_PATH}"
    exit 1
fi

echo "▶ Creating .app bundle at ${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BINARY_PATH}" "${APP_DIR}/Contents/MacOS/${EXECUTABLE_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${EXECUTABLE_NAME}"

# Render the app icon as an .icns. The icon is described in Swift so
# it's source-controlled, not a binary asset. iconutil is built into
# macOS — no extra tooling needed.
echo "▶ Generating app icon..."
ICONSET_DIR="${DIST_DIR}/AppIcon.iconset"
ICNS_PATH="${APP_DIR}/Contents/Resources/AppIcon.icns"
rm -rf "${ICONSET_DIR}"
swift scripts/generate-icon.swift "${ICONSET_DIR}"
iconutil -c icns "${ICONSET_DIR}" -o "${ICNS_PATH}"
rm -rf "${ICONSET_DIR}"

cat > "${APP_DIR}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 devmegablaster. MIT License.</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

# Sign the bundle. We use a self-signed certificate with a stable CN
# ("Notch Pilot Dev") so macOS recognizes the app across updates for
# permissions like Accessibility. Ad-hoc signing (codesign --sign -)
# generates a new identity on every build, which revokes grants.
CERT_CN="Notch Pilot Dev"
echo "▶ Signing bundle..."
if security find-identity -v -p codesigning | grep -q "${CERT_CN}"; then
    echo "   Using existing '${CERT_CN}' certificate"
    codesign --sign "${CERT_CN}" --force --deep "${APP_DIR}"
else
    echo "   '${CERT_CN}' certificate not found — creating self-signed cert..."
    # Create a temporary keychain for CI or use the login keychain
    CERT_FILE="$(mktemp -d)/cert.pem"
    KEY_FILE="$(mktemp -d)/key.pem"
    openssl req -x509 -newkey rsa:2048 -keyout "${KEY_FILE}" -out "${CERT_FILE}" \
        -days 3650 -nodes -subj "/CN=${CERT_CN}" 2>/dev/null
    security import "${CERT_FILE}" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign 2>/dev/null || true
    security import "${KEY_FILE}" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign 2>/dev/null || true
    rm -f "${CERT_FILE}" "${KEY_FILE}"
    # Allow codesign to use the key without prompting
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
    sleep 1
    if security find-identity -v -p codesigning | grep -q "${CERT_CN}"; then
        echo "   ✓ Certificate created. Signing..."
        codesign --sign "${CERT_CN}" --force --deep "${APP_DIR}"
    else
        echo "   ⚠ Certificate creation failed — falling back to ad-hoc signing"
        codesign --sign - --force --deep "${APP_DIR}"
    fi
fi

# Verify architecture and signature
echo ""
echo "▶ Verification:"
file "${APP_DIR}/Contents/MacOS/${EXECUTABLE_NAME}"
codesign --verify --verbose "${APP_DIR}" 2>&1 | sed 's/^/   /'

echo ""
echo "✅ Built: ${APP_DIR}"
echo "   Size: $(du -sh "${APP_DIR}" | cut -f1)"
echo ""
echo "To test: open '${APP_DIR}'"
echo "To package: scripts/make-dmg.sh"
