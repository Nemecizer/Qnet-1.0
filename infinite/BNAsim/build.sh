#!/bin/bash
#
# Build script for Jackson Network Simulator
# Compiles the C simulation engines and the macOS GUI application
#

set -e

echo "=== Jackson Network Simulator Build ==="
echo

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Configuration
CC=clang
CFLAGS="-Wall -O2 -std=c99"
LDFLAGS="-lm"

APP_NAME="JacksonNetworkSimulator"
APP_BUNDLE="${APP_NAME}.app"

# Clean previous builds
if [ "$1" = "clean" ]; then
    echo "Cleaning..."
    rm -f jackson_sim jackson_sim_finite
    rm -rf "${APP_BUNDLE}"
    echo "Clean complete."
    exit 0
fi

# Build simulation engines
echo "Building infinite buffer simulator..."
${CC} ${CFLAGS} -o jackson_sim jackson_sim.c ${LDFLAGS}
echo "  -> jackson_sim built"

echo "Building finite buffer simulator..."
${CC} ${CFLAGS} -o jackson_sim_finite jackson_sim_finite.c ${LDFLAGS}
echo "  -> jackson_sim_finite built"

# Build macOS GUI application
echo
echo "Building macOS GUI application..."

# Create app bundle structure
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Write Info.plist
cat > "${APP_BUNDLE}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>JacksonNetworkSimulator</string>
    <key>CFBundleIconFile</key>
    <string></string>
    <key>CFBundleIdentifier</key>
    <string>com.simnet.jacksonsimulator</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Jackson Network Simulator</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.13</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>jnet</string>
            </array>
            <key>CFBundleTypeName</key>
            <string>Jackson Network Document</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
        </dict>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>sim</string>
            </array>
            <key>CFBundleTypeName</key>
            <string>Simulation Input File</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Compile Objective-C sources
echo "  Compiling GUI sources..."
GUI_SOURCES=(
    "GUI/main.m"
    "GUI/AppDelegate.m"
    "GUI/NetworkModel.m"
    "GUI/NetworkEditorView.m"
    "GUI/ToolPalette.m"
    "GUI/PropertiesPanel.m"
    "GUI/ConsoleView.m"
)

OBJ_FILES=()
for src in "${GUI_SOURCES[@]}"; do
    obj="${src%.m}.o"
    echo "    Compiling $src..."
    ${CC} -c -fobjc-arc -Wall -O2 -o "$obj" "$src"
    OBJ_FILES+=("$obj")
done

# Link
echo "  Linking..."
${CC} -fobjc-arc -o "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" \
    "${OBJ_FILES[@]}" \
    -framework Cocoa -framework AppKit -framework Foundation

# Clean up object files
rm -f "${OBJ_FILES[@]}"

# Copy simulators into the bundle
echo "  Copying simulators into bundle..."
cp jackson_sim "${APP_BUNDLE}/Contents/MacOS/"
cp jackson_sim_finite "${APP_BUNDLE}/Contents/MacOS/"

echo "  -> ${APP_BUNDLE} built"

echo
echo "=== Build Complete ==="
echo
echo "To run the simulator engines directly:"
echo "  ./jackson_sim input.sim"
echo "  ./jackson_sim_finite input.sim"
echo
echo "To run the GUI application:"
echo "  open ${APP_BUNDLE}"
echo "  - or -"
echo "  ./${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
echo
