#!/bin/bash

# Build script for Twoggler.app

set -e

echo "Building Twoggler..."

# Build release binary with size optimizations
swift build -c release \
    -Xswiftc -Osize \
    -Xswiftc -whole-module-optimization \
    -Xswiftc -enforce-exclusivity=unchecked

# Create app bundle structure
APP_NAME="Twoggler"
APP_DIR=".build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

# Clean previous build
rm -rf "${APP_DIR}"

# Create directories
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy executable (stripped of debug symbols)
cp ".build/release/${APP_NAME}" "${MACOS_DIR}/"
strip -x "${MACOS_DIR}/${APP_NAME}"

# Copy Info.plist
    cp "Info.plist" "${CONTENTS_DIR}/"

# Generate app icon from icon.png if it exists
if [ -f "icon.png" ]; then
        echo "Generating app icon from icon.png..."
        
        # Copy original icon for menu bar usage
        cp "icon.png" "${RESOURCES_DIR}/"
        
        ICONSET_DIR=".build/AppIcon.iconset"
        rm -rf "${ICONSET_DIR}"
        mkdir -p "${ICONSET_DIR}"
        
        # Generate all required icon sizes
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
        
        # Convert iconset to icns
    iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"
        
        # Cleanup
        rm -rf "${ICONSET_DIR}"
        
        echo "App icon generated successfully"
elif [ -f "AppIcon.icns" ]; then
    # Fall back to pre-made icns file
    cp "AppIcon.icns" "${RESOURCES_DIR}/"
fi

echo "✅ Build complete: ${APP_DIR}"
echo ""
echo "To install, run:"
echo "  cp -r \"${APP_DIR}\" /Applications/"
echo ""
echo "Or run directly:"
echo "  open \"${APP_DIR}\""
