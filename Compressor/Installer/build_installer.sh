#!/bin/bash
# build_installer.sh — End-to-end build + sign + package for Compressor.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.0.0"
APP_NAME="Compressor"
BUNDLE_ID="com.anthropic.Compressor"
BUILD_DIR="$(pwd)/build"
DIST_DIR="$(pwd)/dist"
PRODUCT_PKG="$DIST_DIR/${APP_NAME}-${VERSION}.pkg"

mkdir -p "$BUILD_DIR" "$DIST_DIR"

# ---------- 1. Xcode project ----------
if [ ! -d "${APP_NAME}.xcodeproj" ]; then
    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "Error: xcodegen not installed. Install with: brew install xcodegen" >&2
        exit 1
    fi
    echo "==> Generating Xcode project with XcodeGen"
    xcodegen generate
fi

# ---------- 2. Build ----------
echo "==> Building $APP_NAME (Release, universal)"
XCBUILD_ARGS=(
    -project "${APP_NAME}.xcodeproj"
    -scheme "${APP_NAME}App"
    -configuration Release
    -derivedDataPath "$BUILD_DIR/DerivedData"
    -destination 'generic/platform=macOS'
    ONLY_ACTIVE_ARCH=NO
    CODE_SIGN_STYLE=Automatic
    clean build
)
if command -v xcpretty >/dev/null 2>&1; then
    set -o pipefail
    xcodebuild "${XCBUILD_ARGS[@]}" | xcpretty
else
    xcodebuild "${XCBUILD_ARGS[@]}"
fi

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Error: build did not produce $APP_PATH" >&2
    exit 1
fi

# ---------- 3. Codesign (optional) ----------
if [ -n "${DEV_ID_APP:-}" ]; then
    echo "==> Codesigning with: $DEV_ID_APP"
    EXT_PATH="$APP_PATH/Contents/PlugIns/CompressorExtension.appex"
    codesign --force --options runtime --timestamp \
        --entitlements CompressorExtension/CompressorExtension.entitlements \
        --sign "$DEV_ID_APP" "$EXT_PATH"
    codesign --force --options runtime --timestamp \
        --sign "$DEV_ID_APP" "$APP_PATH"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
else
    echo "==> DEV_ID_APP not set, skipping codesign (build will be ad-hoc)"
fi

# ---------- 4. Build component pkg + product pkg ----------
echo "==> Building component .pkg"
STAGE_DIR="$BUILD_DIR/stage"
rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR/Applications"
cp -R "$APP_PATH" "$STAGE_DIR/Applications/"

COMPONENT_PKG="$BUILD_DIR/Compressor-component.pkg"
pkgbuild \
    --root "$STAGE_DIR" \
    --identifier "$BUNDLE_ID.pkg" \
    --version "$VERSION" \
    --install-location "/" \
    --scripts Installer/scripts \
    "$COMPONENT_PKG"

echo "==> Building product .pkg"
UNSIGNED_PRODUCT="$BUILD_DIR/${APP_NAME}-${VERSION}-unsigned.pkg"
productbuild \
    --distribution Installer/distribution.xml \
    --resources Installer/Resources \
    --package-path "$BUILD_DIR" \
    --version "$VERSION" \
    "$UNSIGNED_PRODUCT"

# ---------- 5. Sign product pkg (optional) ----------
if [ -n "${DEV_ID_INSTALLER:-}" ]; then
    echo "==> Signing product pkg with: $DEV_ID_INSTALLER"
    productsign --sign "$DEV_ID_INSTALLER" "$UNSIGNED_PRODUCT" "$PRODUCT_PKG"
else
    echo "==> DEV_ID_INSTALLER not set, output pkg is unsigned"
    cp "$UNSIGNED_PRODUCT" "$PRODUCT_PKG"
fi

# ---------- 6. Notarize (optional) ----------
if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Submitting to notarization service"
    xcrun notarytool submit "$PRODUCT_PKG" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PRODUCT_PKG"
fi

echo ""
echo "Done."
echo "Installer: $PRODUCT_PKG"
echo ""
echo "To install: open \"$PRODUCT_PKG\""
