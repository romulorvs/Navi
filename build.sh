#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check macOS version (requires 14.0+)
MACOS_VERSION=$(sw_vers -productVersion)
MACOS_MAJOR=$(echo "$MACOS_VERSION" | cut -d. -f1)

if [ "$MACOS_MAJOR" -lt 14 ]; then
    echo -e "${RED}Error: Navi requires macOS 14.0 or later.${NC}"
    echo "Your version: macOS $MACOS_VERSION"
    exit 1
fi

echo "Building Navi..."

swift build -c release \
    -Xswiftc -Osize \
    -Xswiftc -whole-module-optimization \
    -Xswiftc -enforce-exclusivity=unchecked

APP_NAME="Navi"
APP_DIR=".build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"
cp ".build/release/${APP_NAME}" "${MACOS_DIR}/"
strip -x "${MACOS_DIR}/${APP_NAME}"
cp "Info.plist" "${CONTENTS_DIR}/"

if [ -f "icon.png" ]; then
    echo "Generating app icon from icon.png..."
    cp "icon.png" "${RESOURCES_DIR}/"
    ICONSET_DIR=".build/AppIcon.iconset"
    rm -rf "${ICONSET_DIR}"
    mkdir -p "${ICONSET_DIR}"

    sips -z 16 16     icon.png --out "${ICONSET_DIR}/icon_16x16.png" > /dev/null 2>&1
    sips -z 32 32     icon.png --out "${ICONSET_DIR}/icon_16x16@2x.png" > /dev/null 2>&1
    sips -z 32 32     icon.png --out "${ICONSET_DIR}/icon_32x32.png" > /dev/null 2>&1
    sips -z 64 64     icon.png --out "${ICONSET_DIR}/icon_32x32@2x.png" > /dev/null 2>&1
    sips -z 128 128   icon.png --out "${ICONSET_DIR}/icon_128x128.png" > /dev/null 2>&1
    sips -z 256 256   icon.png --out "${ICONSET_DIR}/icon_128x128@2x.png" > /dev/null 2>&1
    sips -z 256 256   icon.png --out "${ICONSET_DIR}/icon_256x256.png" > /dev/null 2>&1
    sips -z 512 512   icon.png --out "${ICONSET_DIR}/icon_256x256@2x.png" > /dev/null 2>&1
    sips -z 512 512   icon.png --out "${ICONSET_DIR}/icon_512x512.png" > /dev/null 2>&1
    sips -z 1024 1024 icon.png --out "${ICONSET_DIR}/icon_512x512@2x.png" > /dev/null 2>&1
    
    iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"
    rm -rf "${ICONSET_DIR}"
    echo "App icon generated successfully"
elif [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${RESOURCES_DIR}/"
fi

echo "✅ Build complete: ${APP_DIR}"
echo ""
echo "To install, run:"
echo "  cp -r \"${APP_DIR}\" /Applications/"
echo ""
echo "Or run directly:"
echo "  open \"${APP_DIR}\""
