#!/bin/bash

# Papuga Release Script
# Builds, signs, notarizes, and packages the app for distribution
#
# Usage:
#   ./release.sh                    # Full build with notarization
#   ./release.sh --skip-notarize    # Build without notarization
#
# Prerequisites:
#   1. Apple Developer Program membership
#   2. Developer ID Application certificate installed in Keychain
#   3. XcodeGen installed (brew install xcodegen) — only if project.yml exists
#   4. create-dmg installed (brew install create-dmg)
#   5. Notarization credentials stored:
#      xcrun notarytool store-credentials "papuga" \
#        --apple-id <email> --password <app-password> --team-id 8JL9TM5WLG
#
# Optional Sparkle appcast update:
#   SPARKLE_EDDSA_PRIVATE_KEY=<exported-private-key> \
#   SPARKLE_DOWNLOAD_URL=https://github.com/rmarinsky/papuga/releases/download/v1.3.0/Papuga-1.3.0.dmg \
#   ./release.sh

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────
APP_NAME="papuga"
DISPLAY_NAME="Papuga"
SCHEME="papuga"
PROJECT_FILE="papuga.xcodeproj"
TEAM_ID="8JL9TM5WLG"
NOTARY_PROFILE="papuga"
# ─────────────────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"
DMG_STAGE_PATH="${BUILD_DIR}/dmg-stage"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "${PROJECT_DIR}" rev-list --count HEAD)}"
MARKETING_VERSION_OVERRIDE=()
if [ -n "${RELEASE_VERSION:-}" ]; then
    MARKETING_VERSION_OVERRIDE=(MARKETING_VERSION="${RELEASE_VERSION}")
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Parse args ───────────────────────────────────────────────────────
SKIP_NOTARIZE=false
for arg in "$@"; do
    case $arg in
        --skip-notarize) SKIP_NOTARIZE=true ;;
        *) echo -e "${RED}Unknown argument: $arg${NC}"; exit 1 ;;
    esac
done

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║               ${DISPLAY_NAME} Release Builder                      ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${BLUE}Scheme:${NC}  ${SCHEME}"
echo -e "  ${BLUE}Project:${NC} ${PROJECT_FILE}"
echo -e "  ${BLUE}Build:${NC}   ${BUILD_NUMBER}"
if [ -n "${RELEASE_VERSION:-}" ]; then
    echo -e "  ${BLUE}Version:${NC} ${RELEASE_VERSION}"
fi
echo ""

# ── Step 1: Clean ────────────────────────────────────────────────────
echo -e "${YELLOW}[1/7] Cleaning previous build...${NC}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# ── Step 2: Generate Xcode project (if XcodeGen) ────────────────────
echo -e "${YELLOW}[2/7] Checking for XcodeGen...${NC}"
if [ -f "${PROJECT_DIR}/project.yml" ]; then
    if command -v xcodegen &> /dev/null; then
        xcodegen generate --quiet --spec "${PROJECT_DIR}/project.yml"
        echo -e "${GREEN}  Xcode project regenerated${NC}"
    else
        echo -e "${RED}Error: project.yml found but XcodeGen not installed. Run: brew install xcodegen${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}  No project.yml — using existing .xcodeproj${NC}"
fi

# ── Step 3: Resolve SPM + Archive ────────────────────────────────────
echo -e "${YELLOW}[3/7] Resolving packages...${NC}"
xcodebuild -resolvePackageDependencies \
    -project "${PROJECT_FILE}" \
    -scheme "${SCHEME}"

echo -e "${YELLOW}[3/7] Archiving universal app (arm64 + x86_64)...${NC}"
xcodebuild archive \
    -project "${PROJECT_FILE}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    -destination "generic/platform=macOS" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    "${MARKETING_VERSION_OVERRIDE[@]}"

if [ ! -d "${ARCHIVE_PATH}" ]; then
    echo -e "${RED}Error: Archive failed${NC}"
    exit 1
fi
echo -e "${GREEN}  Archive created${NC}"

# ── Step 4: Export ───────────────────────────────────────────────────
echo -e "${YELLOW}[4/7] Exporting for Developer ID distribution...${NC}"
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "${PROJECT_DIR}/ExportOptions.plist"

if [ ! -d "${APP_PATH}" ]; then
    echo -e "${RED}Error: Export failed${NC}"
    exit 1
fi
echo -e "${GREEN}  App exported${NC}"

# ── Step 5: Verify ──────────────────────────────────────────────────
echo -e "${YELLOW}[5/7] Verifying build...${NC}"
echo -n "  Architectures: "
lipo -archs "${APP_PATH}/Contents/MacOS/${APP_NAME}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}" 2>&1 | tail -1
echo -e "${GREEN}  Signature valid${NC}"

# ── Step 6: Notarize ────────────────────────────────────────────────
if [ "$SKIP_NOTARIZE" = false ]; then
    echo -e "${YELLOW}[6/7] Notarizing with Apple...${NC}"

    ZIP_PATH="${BUILD_DIR}/${APP_NAME}-notary.zip"
    ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

    xcrun notarytool submit "${ZIP_PATH}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    xcrun stapler staple "${APP_PATH}"
    spctl --assess --type exec --verbose "${APP_PATH}"
    rm -f "${ZIP_PATH}"

    echo -e "${GREEN}  Notarization complete${NC}"
else
    echo -e "${YELLOW}[6/7] Skipping notarization (--skip-notarize)${NC}"
fi

# ── Step 7: Create DMG ──────────────────────────────────────────────
VERSION=$(defaults read "${APP_PATH}/Contents/Info.plist" CFBundleShortVersionString)
BUILD_NUM=$(defaults read "${APP_PATH}/Contents/Info.plist" CFBundleVersion)
DMG_PATH="${BUILD_DIR}/${DISPLAY_NAME}-${VERSION}.dmg"

echo -e "${YELLOW}[7/7] Creating DMG...${NC}"

if ! command -v create-dmg &> /dev/null; then
    echo -e "${RED}Error: create-dmg not installed. Run: brew install create-dmg${NC}"
    exit 1
fi

rm -rf "${DMG_STAGE_PATH}"
mkdir -p "${DMG_STAGE_PATH}"
cp -R "${APP_PATH}" "${DMG_STAGE_PATH}/"

create-dmg \
    --volname "${DISPLAY_NAME}" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 175 190 \
    --app-drop-link 425 190 \
    "${DMG_PATH}" \
    "${DMG_STAGE_PATH}/"

shasum -a 256 "${DMG_PATH}" | awk '{print $1}' > "${DMG_PATH%.dmg}.sha256"

echo -e "${GREEN}  DMG created${NC}"

# ── Optional Sparkle appcast update ─────────────────────────────────
if [ -n "${SPARKLE_EDDSA_PRIVATE_KEY:-}" ] || [ -n "${SPARKLE_DOWNLOAD_URL:-}" ]; then
    echo -e "${YELLOW}[8/8] Updating Sparkle appcast...${NC}"

    if [ -z "${SPARKLE_EDDSA_PRIVATE_KEY:-}" ]; then
        echo -e "${RED}Error: SPARKLE_EDDSA_PRIVATE_KEY is required to update the appcast${NC}"
        exit 1
    fi
    if [ -z "${SPARKLE_DOWNLOAD_URL:-}" ]; then
        echo -e "${RED}Error: SPARKLE_DOWNLOAD_URL is required to update the appcast${NC}"
        exit 1
    fi

    KEY_LENGTH=$(printf '%s' "${SPARKLE_EDDSA_PRIVATE_KEY}" | tr -d '\r\n' | wc -c | tr -d ' ')
    if [ "${KEY_LENGTH}" -lt 80 ]; then
        echo -e "${RED}Error: SPARKLE_EDDSA_PRIVATE_KEY looks invalid (${KEY_LENGTH} characters)${NC}"
        exit 1
    fi

    if [ -n "${SPARKLE_SIGN_UPDATE:-}" ]; then
        SIGN_UPDATE_TOOL="${SPARKLE_SIGN_UPDATE}"
    else
        SIGN_UPDATE_TOOL=$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
            -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
            -print -quit 2>/dev/null || true)
    fi
    if [ -z "${SIGN_UPDATE_TOOL}" ] || [ ! -x "${SIGN_UPDATE_TOOL}" ]; then
        echo -e "${RED}Error: Sparkle sign_update tool not found. Set SPARKLE_SIGN_UPDATE explicitly.${NC}"
        exit 1
    fi

    SIGN_OUTPUT=$(printf '%s\n' "${SPARKLE_EDDSA_PRIVATE_KEY}" | "${SIGN_UPDATE_TOOL}" "${DMG_PATH}" --ed-key-file -)
    ED_SIGNATURE=$(echo "${SIGN_OUTPUT}" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
    ED_LENGTH=$(echo "${SIGN_OUTPUT}" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
    if [ -z "${ED_SIGNATURE}" ]; then
        echo -e "${RED}Error: Could not parse Sparkle signature output${NC}"
        echo "${SIGN_OUTPUT}"
        exit 1
    fi

    DMG_SIZE=$(stat -f%z "${DMG_PATH}")
    python3 "${PROJECT_DIR}/scripts/update_appcast.py" \
        --appcast "${PROJECT_DIR}/docs/appcast.xml" \
        --version "${BUILD_NUM}" \
        --short-version "${VERSION}" \
        --download-url "${SPARKLE_DOWNLOAD_URL}" \
        --ed-signature "${ED_SIGNATURE}" \
        --length "${ED_LENGTH:-$DMG_SIZE}" \
        --minimum-system-version "14.0.0"

    echo -e "${GREEN}  Appcast updated: ${PROJECT_DIR}/docs/appcast.xml${NC}"
else
    echo -e "${YELLOW}[8/8] Skipping Sparkle appcast update (SPARKLE_EDDSA_PRIVATE_KEY/SPARKLE_DOWNLOAD_URL not set)${NC}"
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗"
echo -e "║                    BUILD COMPLETE                         ║"
echo -e "╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLUE}App:${NC}     ${APP_PATH}"
echo -e "  ${BLUE}DMG:${NC}     ${DMG_PATH}"
echo -e "  ${BLUE}SHA256:${NC}  ${DMG_PATH%.dmg}.sha256"
echo -e "  ${BLUE}Version:${NC} ${VERSION} (${BUILD_NUM})"
echo ""

if [ "$SKIP_NOTARIZE" = false ]; then
    echo -e "  ${GREEN}Signed + Notarized + Ready for distribution${NC}"
else
    echo -e "  ${YELLOW}Not notarized — users may see Gatekeeper warnings${NC}"
fi

echo ""
echo -e "  ${BLUE}open ${DMG_PATH}${NC}"
echo ""
