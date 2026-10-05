#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: build_fork_dmg.sh VERSION OUTPUT_DIRECTORY" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERSION="$1"
OUTPUT_DIRECTORY="$2"
APP_BUNDLE_ID="com.happyjoy95.boringnotch"
RUNNER_TEMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"

cd "$REPOSITORY_ROOT"
mkdir -p "$OUTPUT_DIRECTORY"
APP_SOURCE="$RUNNER_TEMP/DerivedData/Build/Products/Release/Boring Notch.app"
APP_DEST="$OUTPUT_DIRECTORY/Boring Notch (HappyJoy95).app"
DMG_PATH="$OUTPUT_DIRECTORY/boringNotch.dmg"
UPDATE_ARCHIVE_PATH="$OUTPUT_DIRECTORY/Boring-Notch-${VERSION}-macos-universal.zip"

if [[ -e "$APP_DEST" || -e "$DMG_PATH" || -e "$UPDATE_ARCHIVE_PATH" ]]; then
  echo "Output already exists; choose a fresh directory: $OUTPUT_DIRECTORY" >&2
  exit 1
fi

METADATA="$(python3 "$SCRIPT_DIR/fork_release_metadata.py" \
  --pbxproj boringNotch.xcodeproj/project.pbxproj \
  --bundle-identifier "$APP_BUNDLE_ID" \
  --version "$VERSION")"
printf '%s\n' "$METADATA" > "$OUTPUT_DIRECTORY/release-metadata.txt"

xcodebuild -resolvePackageDependencies \
  -project boringNotch.xcodeproj \
  -scheme boringNotch

xcodebuild clean build \
  -project boringNotch.xcodeproj \
  -scheme boringNotch \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$RUNNER_TEMP/DerivedData" \
  DEVELOPMENT_TEAM= \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  ONLY_ACTIVE_ARCH=NO \
  -quiet

[[ -d "$APP_SOURCE" ]] || {
  echo "Built app was not found at $APP_SOURCE" >&2
  exit 1
}

ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$APP_SOURCE/Contents/Info.plist")"
ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP_SOURCE/Contents/Info.plist")"
EXPECTED_BUILD_NUMBER="$(sed -n 's/^build_number=//p' "$OUTPUT_DIRECTORY/release-metadata.txt")"
ACTUAL_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$APP_SOURCE/Contents/Info.plist")"

[[ "$ACTUAL_BUNDLE_ID" == "$APP_BUNDLE_ID" ]] || {
  echo "Built app has unexpected bundle ID: $ACTUAL_BUNDLE_ID" >&2
  exit 1
}
[[ "$ACTUAL_VERSION" == "$VERSION" ]] || {
  echo "Built app version $ACTUAL_VERSION does not match $VERSION" >&2
  exit 1
}
[[ "$ACTUAL_BUILD_NUMBER" == "$EXPECTED_BUILD_NUMBER" ]] || {
  echo "Built app build number $ACTUAL_BUILD_NUMBER does not match $EXPECTED_BUILD_NUMBER" >&2
  exit 1
}

ditto "$APP_SOURCE" "$APP_DEST"
codesign --verify --deep --strict "$APP_DEST"

python3 -m venv "$RUNNER_TEMP/dmg-venv"
"$RUNNER_TEMP/dmg-venv/bin/python" -m pip install \
  --index-url https://pypi.org/simple --upgrade pip setuptools wheel
"$RUNNER_TEMP/dmg-venv/bin/python" -m pip install \
  --index-url https://pypi.org/simple \
  --require-hashes -r Configuration/dmg/requirements.txt
chmod +x Configuration/dmg/create_dmg.sh
source "$RUNNER_TEMP/dmg-venv/bin/activate"
./Configuration/dmg/create_dmg.sh "$APP_DEST" "$DMG_PATH" "Boring Notch"
ditto -c -k --sequesterRsrc --keepParent "$APP_DEST" "$UPDATE_ARCHIVE_PATH"
unzip -tqq "$UPDATE_ARCHIVE_PATH"

shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"
shasum -a 256 --check "$DMG_PATH.sha256"
shasum -a 256 "$UPDATE_ARCHIVE_PATH" > "$UPDATE_ARCHIVE_PATH.sha256"
shasum -a 256 --check "$UPDATE_ARCHIVE_PATH.sha256"
codesign --verify --deep --strict "$APP_DEST"
