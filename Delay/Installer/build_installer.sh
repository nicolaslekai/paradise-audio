#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="1.0.0"; APP_NAME="Delay"; BUNDLE_ID="com.paradise.Delay"
BUILD_DIR="$(pwd)/build"; DIST_DIR="$(pwd)/dist"
PRODUCT_PKG="$DIST_DIR/${APP_NAME}-${VERSION}.pkg"
mkdir -p "$BUILD_DIR" "$DIST_DIR"
[ -d "${APP_NAME}.xcodeproj" ] || { command -v xcodegen >/dev/null 2>&1 || { echo "brew install xcodegen" >&2; exit 1; }; xcodegen generate; }
ARGS=(-project "${APP_NAME}.xcodeproj" -scheme "${APP_NAME}App" -configuration Release
      -derivedDataPath "$BUILD_DIR/DerivedData" -destination 'generic/platform=macOS'
      ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Automatic clean build)
if command -v xcpretty >/dev/null 2>&1; then set -o pipefail; xcodebuild "${ARGS[@]}" | xcpretty; else xcodebuild "${ARGS[@]}"; fi
APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/${APP_NAME}.app"
[ -d "$APP_PATH" ] || { echo "Build failed" >&2; exit 1; }
STAGE="$BUILD_DIR/stage"; rm -rf "$STAGE" && mkdir -p "$STAGE/Applications"
cp -R "$APP_PATH" "$STAGE/Applications/"
COMPONENT_PKG="$BUILD_DIR/${APP_NAME}-component.pkg"
pkgbuild --root "$STAGE" --identifier "$BUNDLE_ID.pkg" --version "$VERSION" --install-location "/" --scripts Installer/scripts "$COMPONENT_PKG"
UNSIGNED="$BUILD_DIR/${APP_NAME}-${VERSION}-unsigned.pkg"
productbuild --distribution Installer/distribution.xml --resources Installer/Resources --package-path "$BUILD_DIR" --version "$VERSION" "$UNSIGNED"
cp "$UNSIGNED" "$PRODUCT_PKG"
echo "Done. Installer: $PRODUCT_PKG"
