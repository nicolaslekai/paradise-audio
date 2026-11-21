#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.0.0"
APP_NAME="EQ"
BUNDLE_ID="com.paradise.EQ"
BUILD_DIR="$(pwd)/build"
DIST_DIR="$(pwd)/dist"
PRODUCT_PKG="$DIST_DIR/${APP_NAME}-${VERSION}.pkg"

mkdir -p "$BUILD_DIR" "$DIST_DIR"

if [ ! -d "${APP_NAME}.xcodeproj" ]; then
    command -v xcodegen >/dev/null 2>&1 || { echo "Error: install xcodegen (brew install xcodegen)" >&2; exit 1; }
    xcodegen generate
fi

echo "==> Building $APP_NAME (Release, universal)"
XCBUILD_ARGS=(-project "${APP_NAME}.xcodeproj" -scheme "${APP_NAME}App" -configuration Release
    -derivedDataPath "$BUILD_DIR/DerivedData" -destination 'generic/platform=macOS'
    ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Automatic clean build)
if command -v xcpretty >/dev/null 2>&1; then
    set -o pipefail; xcodebuild "${XCBUILD_ARGS[@]}" | xcpretty
else
    xcodebuild "${XCBUILD_ARGS[@]}"
fi

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/${APP_NAME}.app"
[ -d "$APP_PATH" ] || { echo "Error: build did not produce $APP_PATH" >&2; exit 1; }

if [ -n "${DEV_ID_APP:-}" ]; then
    EXT_PATH="$APP_PATH/Contents/PlugIns/${APP_NAME}Extension.appex"
    codesign --force --options runtime --timestamp \
        --entitlements ${APP_NAME}Extension/${APP_NAME}Extension.entitlements --sign "$DEV_ID_APP" "$EXT_PATH"
    codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" "$APP_PATH"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

STAGE_DIR="$BUILD_DIR/stage"
rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR/Applications"
cp -R "$APP_PATH" "$STAGE_DIR/Applications/"

COMPONENT_PKG="$BUILD_DIR/${APP_NAME}-component.pkg"
pkgbuild --root "$STAGE_DIR" --identifier "$BUNDLE_ID.pkg" --version "$VERSION" \
    --install-location "/" --scripts Installer/scripts "$COMPONENT_PKG"

UNSIGNED_PRODUCT="$BUILD_DIR/${APP_NAME}-${VERSION}-unsigned.pkg"
productbuild --distribution Installer/distribution.xml --resources Installer/Resources \
    --package-path "$BUILD_DIR" --version "$VERSION" "$UNSIGNED_PRODUCT"

if [ -n "${DEV_ID_INSTALLER:-}" ]; then
    productsign --sign "$DEV_ID_INSTALLER" "$UNSIGNED_PRODUCT" "$PRODUCT_PKG"
else
    cp "$UNSIGNED_PRODUCT" "$PRODUCT_PKG"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$PRODUCT_PKG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PRODUCT_PKG"
fi

echo ""; echo "Done."; echo "Installer: $PRODUCT_PKG"
