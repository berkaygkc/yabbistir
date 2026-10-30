#!/bin/bash
# Builds a signed, notarized and stapled yabbistir.app and DMG for a GitHub release.
# Usage: scripts/release.sh   (or: make release)
#
# Needs a "Developer ID Application" certificate and a notarytool keychain profile (default name: yabbistir-notary):
#   xcrun notarytool store-credentials yabbistir-notary --apple-id <Apple ID> --team-id 9MX558XNV6
# You'll be asked for an app-specific password (appleid.apple.com → Sign-In and Security → App-Specific Passwords).
# NOTARY_PROFILE overrides the profile name. Without it the script tries yabbistir-notary, then mystat-notary
# (same Apple ID).
#
# Notarization runs twice: first the app (so a copy dragged out of the DMG opens offline too), then the DMG built from
# the stapled app.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/yabbistir.app"

fail() { echo "error: $*" >&2; exit 1; }

# Preflight, cheapest and most local first: certificate, clean tree, untracked files, then the notary profile
# (a network call), then green tests.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)"
[ -n "$IDENTITY" ] || fail "no Developer ID Application certificate in the keychain"
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "uncommitted changes; commit or stash them first"
# XcodeGen compiles every file under App/ and Packages/, and the app bundles Extensions/BuiltinExtensions: untracked
# files there would ship. project.yml decides what the project contains, and Config/Base.xcconfig includes an optional
# local xcconfig.
UNTRACKED="$(git ls-files --others --exclude-standard -- Packages App Config Extensions/BuiltinExtensions project.yml)"
[ -z "$UNTRACKED" ] || fail "untracked files would be built into the app:
$UNTRACKED"
# BuiltinExtensions is copied as a folder, so even ignored files (.DS_Store and the like) would ship.
IGNORED="$(git ls-files --others --ignored --exclude-standard -- Extensions/BuiltinExtensions)"
[ -z "$IGNORED" ] || fail "ignored files would be bundled into the app:
$IGNORED"

# An explicit NOTARY_PROFILE is used as is; otherwise yabbistir-notary, then mystat-notary.
if [ -n "${NOTARY_PROFILE:-}" ]; then
    CANDIDATES=("$NOTARY_PROFILE")
else
    CANDIDATES=(yabbistir-notary mystat-notary)
fi
PROFILE=""
for candidate in "${CANDIDATES[@]}"; do
    if xcrun notarytool history --keychain-profile "$candidate" >/dev/null 2>&1; then
        PROFILE="$candidate"
        break
    fi
done
[ -n "$PROFILE" ] || fail "no notarytool profile (tried: ${CANDIDATES[*]}); create one with:
  xcrun notarytool store-credentials yabbistir-notary --apple-id <Apple ID> --team-id 9MX558XNV6"
echo "Using notarytool profile \"$PROFILE\""

# Leftovers of an earlier release must not be mistaken for this one's.
rm -f build/yabbistir-*.dmg build/yabbistir-*.dmg.sha256 build/yabbistir-*-app.zip

echo "Running tests…"
mkdir -p build
make test >build/release-tests.log 2>&1 || fail "tests failed (see build/release-tests.log)"

# Submits a file and waits; stops unless Apple accepts it.
notarize() {
    local out id
    echo "Notarizing $(basename "$1")…"
    out="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1)" || true
    # Here-strings, not pipes: under pipefail a grep with no match would end the script before the error is shown.
    id="$(awk '/^ *id:/ { print $2; exit }' <<< "$out")"
    if ! grep -q 'status: Accepted' <<< "$out"; then
        echo "$out" >&2
        fail "notarization was not accepted${id:+; details: xcrun notarytool log $id --keychain-profile $PROFILE}"
    fi
    echo "  id: $id"
    echo "  status: Accepted"
}

# 1. The app.
make release-build
[ -d "$APP" ] || fail "release build did not produce $APP"
# Binaries must ship stripped: no debug map and no path from this machine inside them (the dSYMs are in build/dsym).
scripts/check-stripped.sh "$APP" || fail "the release binaries are not stripped; see above"
# The build regenerates the project; a version bumped only in project.yml leaves App/Info.plist modified.
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "the build changed tracked files (App/Info.plist is stale after a version bump?); commit the regenerated files and re-run:
$(git status --porcelain --untracked-files=no)"
# The version comes from the built app, so the file names always match what is inside.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/yabbistir-$VERSION.dmg"
rm -f "$DMG" "$DMG.sha256"
ZIP="build/yabbistir-$VERSION-app.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
rm -f "$ZIP"
xcrun stapler staple -q "$APP"

# 2. The DMG: the stapled app, the license and notices, and a shortcut to /Applications.
STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp LICENSE THIRD_PARTY_NOTICES.md "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname yabbistir -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple -q "$DMG"

# 3. Verify the way Gatekeeper will.
spctl -a -vv "$APP" 2>&1 | sed 's/^/  /'
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/  /'
xcrun stapler validate -q "$APP" && xcrun stapler validate -q "$DMG" || fail "stapled ticket missing"
(cd build && shasum -a 256 "yabbistir-$VERSION.dmg" > "yabbistir-$VERSION.dmg.sha256")
echo "Ready: $DMG ($(du -h "$DMG" | cut -f1)), $(cut -d' ' -f1 "$DMG.sha256")"
