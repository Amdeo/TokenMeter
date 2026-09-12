#!/bin/bash
# Builds TokenMeter for distribution. Unsigned packages are the default.
# Set DEVELOPER_ID_APPLICATION and NOTARYTOOL_PROFILE to sign, notarize, and staple.
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT="$ROOT_DIR/TokenMeter.xcodeproj"
readonly SCHEME="TokenMeter"
readonly DERIVED_DATA="$ROOT_DIR/build/release-derived-data"
readonly OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
readonly APP_PATH="$DERIVED_DATA/Build/Products/Release/TokenMeter.app"

require_command() {
    command -v "$1" >/dev/null || {
        printf 'Required command not found: %s\n' "$1" >&2
        exit 1
    }
}

for command in xcodebuild ditto shasum /usr/libexec/PlistBuddy; do
    require_command "$command"
done

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" && -z "${NOTARYTOOL_PROFILE:-}" ]]; then
    printf '%s\n' 'NOTARYTOOL_PROFILE is required for signed distribution.' >&2
    exit 1
fi
mkdir -p "$OUTPUT_DIR"

build_args=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration Release
    -destination 'generic/platform=macOS'
    -derivedDataPath "$DERIVED_DATA"
    ARCHS='arm64 x86_64'
    ONLY_ACTIVE_ARCH=NO
)

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    printf '%s\n' 'Building an explicitly unsigned release package.'
    xcodebuild "${build_args[@]}" build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-
else
    require_command codesign
    require_command xcrun
    xcodebuild "${build_args[@]}" build CODE_SIGNING_ALLOWED=NO
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$APP_PATH"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

[[ -d "$APP_PATH" ]] || { printf 'Build did not produce %s\n' "$APP_PATH" >&2; exit 1; }
readonly VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
readonly ARCHIVE_BASENAME="TokenMeter-${VERSION}-macos-universal"
readonly ZIP_PATH="$OUTPUT_DIR/${ARCHIVE_BASENAME}.zip"

# A released version must never be silently repackaged from a later revision:
# bump CFBundleShortVersionString before packaging new content.
if [[ -e "$ZIP_PATH" ]]; then
    printf 'Refusing to overwrite existing archive: %s\n' "$ZIP_PATH" >&2
    printf 'Bump CFBundleShortVersionString before packaging a new release.\n' >&2
    exit 1
fi

printf 'Packaging version %s from %s\n' "$VERSION" "$(git -C "$ROOT_DIR" describe --tags --always --dirty 2>/dev/null || printf 'unknown revision')"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    readonly NOTARY_ZIP="$OUTPUT_DIR/${ARCHIVE_BASENAME}-notarization.zip"
    ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
    xcrun stapler staple "$APP_PATH"
    rm "$NOTARY_ZIP"
fi

ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$(basename "$ZIP_PATH")" > "${ARCHIVE_BASENAME}.zip.sha256"
)
printf 'Created %s\n' "$ZIP_PATH"
printf 'Created %s\n' "$OUTPUT_DIR/${ARCHIVE_BASENAME}.zip.sha256"
