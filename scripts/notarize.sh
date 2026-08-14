#!/bin/zsh
set -euo pipefail

# Re-sign Sparkle's nested helper executables, notarize the app archive, and
# staple the ticket. Xcode's Swift Package binary target signs the outer
# framework but may leave Sparkle's helper processes ad-hoc signed.

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 /path/to/CCRBar.app [/path/to/CCRBar-macos.zip]" >&2
    exit 64
fi

APP_PATH="${1:A}"
ZIP_PATH="${2:-${APP_PATH:h}/${APP_PATH:t:r}-macos.zip}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Guofeng Liu (U8U443D7ZL)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-octoshrink-notary}"
ENTITLEMENTS="${0:A:h:h}/CCRBar/Resources/CCRBar.entitlements"
FRAMEWORK="${APP_PATH}/Contents/Frameworks/Sparkle.framework"

[[ -d "${APP_PATH}" ]] || { echo "App not found: ${APP_PATH}" >&2; exit 1; }
[[ -f "${ENTITLEMENTS}" ]] || { echo "Entitlements not found: ${ENTITLEMENTS}" >&2; exit 1; }
[[ -d "${FRAMEWORK}" ]] || { echo "Sparkle.framework not found: ${FRAMEWORK}" >&2; exit 1; }

sign_nested() {
    local path="$1"
    [[ -e "${path}" ]] || return 0
    /usr/bin/codesign --force --options runtime --timestamp \
        --sign "${SIGNING_IDENTITY}" "${path}"
}

echo "==> Re-signing Sparkle helper processes"
sign_nested "${FRAMEWORK}/Versions/B/Autoupdate"
sign_nested "${FRAMEWORK}/Versions/B/Updater.app/Contents/MacOS/Updater"
sign_nested "${FRAMEWORK}/Versions/B/Updater.app"
sign_nested "${FRAMEWORK}/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
sign_nested "${FRAMEWORK}/Versions/B/XPCServices/Downloader.xpc"
sign_nested "${FRAMEWORK}/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
sign_nested "${FRAMEWORK}/Versions/B/XPCServices/Installer.xpc"
sign_nested "${FRAMEWORK}"

echo "==> Re-signing CCRBar.app"
/usr/bin/codesign --force --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${SIGNING_IDENTITY}" "${APP_PATH}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

echo "==> Creating ${ZIP_PATH}"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "==> Submitting to Apple notarization (${NOTARY_PROFILE})"
/usr/bin/xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

echo "==> Stapling and validating the ticket"
/usr/bin/xcrun stapler staple "${APP_PATH}"
/usr/bin/xcrun stapler validate "${APP_PATH}"
/usr/bin/codesign --verify --deep --strict "${APP_PATH}"

echo "==> Recreating the archive with the stapled app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"
echo "Done: ${ZIP_PATH}"
