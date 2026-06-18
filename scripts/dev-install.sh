#!/bin/bash

# Build and install Papuga DEV to /Applications for fast permission/feature testing.
# Default behavior:
# - kills running app
# - resets TCC grants for DEV bundle id
# - builds Debug with DEV bundle id
# - installs app as /Applications/papuga-dev.app
#
# Usage:
#   ./scripts/dev-install.sh
#   ./scripts/dev-install.sh --build-only
#   ./scripts/dev-install.sh --install-name papuga-dev-local
#   ./scripts/dev-install.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

PROJECT_NAME="papuga"
PROJECT_FILE="${PROJECT_NAME}.xcodeproj"
SCHEME="papuga"
CONFIG="Debug"

APP_DISPLAY_NAME="Papuga DEV"
TARGET_PRODUCT_NAME="papuga"
INSTALL_APP_NAME="papuga-dev"
BUNDLE_ID="ua.com.rmarinsky.papuga.dev"

BUILD_DIR="$PROJECT_DIR/build/dev-install"
DERIVED_DATA_PATH="$BUILD_DIR/DerivedData"
CONFIG_BUILD_DIR="$BUILD_DIR/$CONFIG"
APP_PATH="$CONFIG_BUILD_DIR/${TARGET_PRODUCT_NAME}.app"
INSTALL_PATH="/Applications/${INSTALL_APP_NAME}.app"
DESTINATION="platform=macOS,arch=$(uname -m)"
LOG_PATH="$BUILD_DIR/xcodebuild.log"

RESET_TCC=true
BUILD_ONLY=false

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --build-only   Build only, skip install to /Applications.
  --install-name Override installed app folder name (default: papuga-dev).
  --no-reset-tcc Skip TCC reset (default is reset).
  --help         Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-only)
            BUILD_ONLY=true
            shift
            ;;
        --install-name)
            if [[ $# -lt 2 ]]; then
                echo "--install-name requires a value"
                exit 1
            fi
            if [[ "$2" == */* || "$2" == *..* ]]; then
                echo "--install-name must be a simple name (no path separators or traversal patterns)"
                exit 1
            fi
            INSTALL_APP_NAME="$2"
            INSTALL_PATH="/Applications/${INSTALL_APP_NAME}.app"
            shift 2
            ;;
        --no-reset-tcc)
            RESET_TCC=false
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

echo "=== Papuga DEV build/install ==="
echo "Project:      $PROJECT_FILE"
echo "Scheme:       $SCHEME"
echo "Configuration:$CONFIG"
echo "Build product:$TARGET_PRODUCT_NAME.app"
echo "Display name: $APP_DISPLAY_NAME"
echo "Install name: $INSTALL_APP_NAME.app"
echo "Bundle id:    $BUNDLE_ID"
echo ""

if [ "$RESET_TCC" = true ]; then
    echo "Resetting TCC grants for $BUNDLE_ID ..."
    tccutil reset Accessibility "$BUNDLE_ID" || true
    tccutil reset ListenEvent "$BUNDLE_ID" || true
    echo "TCC reset done."
    echo ""
fi

echo "Killing running Papuga processes if any..."
pkill -x "papuga-dev" 2>/dev/null || true
pkill -x "papuga" 2>/dev/null || true
sleep 1

if [ "$BUILD_ONLY" = false ] && [ -d "$INSTALL_PATH" ]; then
    echo "Removing existing install at $INSTALL_PATH ..."
    rm -rf "$INSTALL_PATH"
fi

if [ ! -f "$PROJECT_DIR/$PROJECT_FILE/project.pbxproj" ]; then
    echo "Xcode project not found: $PROJECT_DIR/$PROJECT_FILE"
    exit 1
fi

if [ -f "$PROJECT_DIR/project.yml" ]; then
    echo "project.yml detected, regenerating Xcode project..."
    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "xcodegen is required (brew install xcodegen)."
        exit 1
    fi
    xcodegen generate --spec "$PROJECT_DIR/project.yml"
fi

echo "Cleaning previous build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "Resolving package dependencies..."
xcodebuild -resolvePackageDependencies \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME"

echo ""
echo "Building $APP_DISPLAY_NAME ..."
set +e
xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CONFIGURATION_BUILD_DIR="$CONFIG_BUILD_DIR" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    clean build \
    2>&1 | tee "$LOG_PATH" \
    | grep -E "^(Build|Compile|Compiling|Ld|Linking|error:|warning:|\\*\\*)"
XCODEBUILD_STATUS=${PIPESTATUS[0]}
set -e
if [ "$XCODEBUILD_STATUS" -ne 0 ]; then
    echo "xcodebuild failed (exit $XCODEBUILD_STATUS). See full log: $LOG_PATH"
    exit "$XCODEBUILD_STATUS"
fi

if [ ! -d "$APP_PATH" ]; then
    echo ""
    echo "Build failed. App not found at: $APP_PATH"
    echo "See full log: $LOG_PATH"
    exit 1
fi

echo ""
echo "Build successful: $APP_PATH"

if [ "$BUILD_ONLY" = true ]; then
    echo "Build-only mode enabled. Skipping install."
    exit 0
fi

echo "Installing to $INSTALL_PATH ..."
cp -R "$APP_PATH" "$INSTALL_PATH"

# Clear quarantine attributes to avoid Gatekeeper noise on local testing.
xattr -cr "$INSTALL_PATH"

echo ""
echo "=== Done ==="
echo "Installed: $INSTALL_PATH"
echo ""
echo "Launch command:"
echo "  open \"$INSTALL_PATH\""
echo ""
echo "If permissions got stuck, run:"
echo "  tccutil reset Accessibility \"$BUNDLE_ID\""
echo "  tccutil reset ListenEvent \"$BUNDLE_ID\""

echo ""
echo "Launching $INSTALL_APP_NAME ..."
open "$INSTALL_PATH"
