#!/bin/bash
set -e

APP_NAME="Navi"
REPO_URL="https://github.com/romulorvs/Navi.git"
INSTALL_DIR="/Applications"
WORK_DIR=""
SOURCE_DIR=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check macOS version (requires 14.0+)
MACOS_VERSION=$(sw_vers -productVersion)
MACOS_MAJOR=$(echo "$MACOS_VERSION" | cut -d. -f1)

if [ "$MACOS_MAJOR" -lt 14 ]; then
    echo -e "${RED}Error: Navi requires macOS 14.0 or later.${NC}"
    echo "Your version: macOS $MACOS_VERSION"
    exit 1
fi

# Cleanup function
cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        echo "Cleaning up temporary files..."
        rm -rf "$WORK_DIR"
    fi
}

# Ensure cleanup runs on exit (success or failure)
trap cleanup EXIT

echo -e "${BLUE}Starting Navi installation...${NC}"

# Create temp working directory
WORK_DIR=$(mktemp -d)
SOURCE_DIR="$WORK_DIR/Navi"
echo "Working in temporary directory: $WORK_DIR"

# Check if we are in the repo directory by looking for required files
if [ -f "Package.swift" ] && [ -f "icon.png" ] && [ -f "Info.plist" ] && [ -f "main.swift" ]; then
    echo "Copying source files to temp directory..."
    mkdir -p "$SOURCE_DIR"
    rsync -a --exclude '.build' ./ "$SOURCE_DIR/"
else
    echo "Cloning Navi repository..."
    git clone "$REPO_URL" "$SOURCE_DIR"
fi

cd "$SOURCE_DIR"

swift build -c release \
    -Xswiftc -Osize \
    -Xswiftc -whole-module-optimization \
    -Xswiftc -enforce-exclusivity=unchecked

BUILD_APP_DIR=".build/${APP_NAME}.app"
CONTENTS_DIR="${BUILD_APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf "${BUILD_APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"
cp ".build/release/${APP_NAME}" "${MACOS_DIR}/"
strip -x "${MACOS_DIR}/${APP_NAME}"

# Handle Info.plist
if [ -f "Info.plist" ]; then
    cp "Info.plist" "${CONTENTS_DIR}/"
else
    echo "Warning: Info.plist not found."
fi

# Handle Icon
if [ -f "icon.png" ]; then
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
elif [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${RESOURCES_DIR}/"
fi

# 3. Install to /Applications
echo -e "${BLUE}Installing to ${INSTALL_DIR}...${NC}"
rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
cp -r "${BUILD_APP_DIR}" "${INSTALL_DIR}/"

# 4. Execute with prompt for login items
echo -e "${GREEN}Installation complete! Navi is running.${NC}"
open "${INSTALL_DIR}/${APP_NAME}.app"
