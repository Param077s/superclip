#!/bin/bash
# Regenerate the app icon from source.
#
# The .icns is committed because build.sh needs it and nobody should have to run
# a code generator to get a working build. This script is what makes that
# committed binary honest: the artwork is `Sources/IconGen` plus the mark in
# `SuperclipKit`, and running this reproduces the file exactly.
#
#   ./Tools/generate-icons.sh              regenerate Resources/Superclip.icns
#   ./Tools/generate-icons.sh --preview    also write contact sheets to look at
set -eo pipefail

cd "$(dirname "$0")/.."

ICONSET="Resources/Superclip.iconset"
ICNS="Resources/Superclip.icns"

mkdir -p Resources

echo ">> Drawing iconset..."
swift run -c release IconGen iconset "$ICONSET"

echo ">> Converting to $ICNS..."
iconutil -c icns "$ICONSET" -o "$ICNS"

# The iconset is a build product — ten PNGs that say nothing a reviewer can use.
# The generator and the .icns are what get committed.
rm -rf "$ICONSET"

if [ "$1" = "--preview" ]; then
    echo ">> Drawing contact sheets..."
    swift run -c release IconGen preview Resources/preview
fi

echo ">> Wrote $ICNS"
