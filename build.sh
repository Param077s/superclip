#!/bin/bash
# Build Superclip and assemble a runnable .app bundle.
set -eo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="Superclip.app"
BIN_NAME="Superclip"

echo ">> Building ($CONFIG)..."
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"

echo ">> Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp Info.plist "$APP/Contents/Info.plist"

# Before signing, not after: the signature covers the bundle's contents, and a
# resource added afterwards invalidates it.
if [ -f Resources/Superclip.icns ]; then
    cp Resources/Superclip.icns "$APP/Contents/Resources/Superclip.icns"
else
    echo "   no Resources/Superclip.icns — run ./Tools/generate-icons.sh"
fi

# Sign with a STABLE self-signed identity so macOS keeps the Accessibility grant
# across rebuilds (ad-hoc changes identity every build and resets TCC).
IDENTITY="Superclip Dev Cert"
echo ">> Signing ($IDENTITY)..."
if security find-identity -v 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" --identifier com.param.superclip "$APP" >/dev/null 2>&1 \
        && echo "   signed with stable identity" \
        || { echo "   stable identity failed, falling back to ad-hoc"; codesign --force --deep --sign - "$APP" >/dev/null 2>&1; }
else
    echo "   stable identity not found, using ad-hoc"
    echo "   (create one in Keychain Access > Certificate Assistant > Create a Certificate,"
    echo "    name it '$IDENTITY', type 'Code Signing' — keeps permissions across rebuilds)"
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

echo ">> Built $APP"
echo "   Run with:  open ./$APP"
