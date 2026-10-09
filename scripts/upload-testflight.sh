#!/bin/zsh
# Archives the Tsukumo iPhone app (apps/ios, com.zlichtman.tsukumo) and uploads it to App Store
# Connect for TestFlight with an App Store Connect API key, never a password (AGENTS.md rule 3).
#
# One-time setup (by the account owner; the key never enters the repo):
#   1. App Store Connect → Users and Access → Integrations → App Store Connect API →
#      Team Keys → Generate API Key (Access: Admin, so signing can be managed).
#   2. Download AuthKey_<KEYID>.p8 (Apple offers it once) into ~/.appstoreconnect/private_keys/
#   3. Create ~/.appstoreconnect/kemosabe.env with:
#        ASC_KEY_ID=<Key ID>
#        ASC_ISSUER_ID=<Issuer ID>
#   4. The app's own App Store Connect record for com.zlichtman.tsukumo.
#
# Usage: scripts/upload-testflight.sh <build> [--no-upload] [--out <folder>]
#   1. Sets CURRENT_PROJECT_VERSION in apps/ios/project.yml to <build>. The version stays 1.0.0
#      (AGENTS.md rule 2), so only the build number goes up.
#   2. Generates apps/ios/Tsukumo.xcodeproj with xcodegen (never committed).
#   3. Archives the Tsukumo scheme (Release) for iOS devices.
#   4. Exports with apps/ios/ExportOptions.plist (app-store-connect, destination upload), which
#      uploads the build. --no-upload stops after the archive.
# Build first (scripts/build.sh). Afterwards commit the bump, report Apple's real processing and
# TestFlight status, and add docs/releases/TSUKUMO-IOS-<build>.md.
set -euo pipefail

usage() { echo "usage: upload-testflight.sh <build> [--no-upload] [--out <folder>]" >&2; exit 2; }
fail() { echo "error: $*" >&2; exit 1; }

BUILD=""; UPLOAD=1; OUT=""
while (( $# )); do
  case $1 in
    --no-upload) UPLOAD=0 ;;
    --out) (( $# >= 2 )) || usage; OUT=$2; shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [[ -z $BUILD ]] || usage; BUILD=$1 ;;
  esac
  shift
done
[[ $BUILD == <-> ]] || usage

REPO=${0:A:h:h}
SPEC=$REPO/apps/ios/project.yml
EXPORT_OPTIONS=$REPO/apps/ios/ExportOptions.plist
[[ -f $SPEC && -f $EXPORT_OPTIONS ]] || fail "apps/ios/project.yml or apps/ios/ExportOptions.plist is missing"
command -v xcodegen >/dev/null || fail "xcodegen isn't installed"

config=~/.appstoreconnect/kemosabe.env
[[ -f $config ]] || { echo "error: $config is missing. See the setup steps at the top of this script." >&2; exit 2; }
source "$config"
: ${ASC_KEY_ID:?ASC_KEY_ID missing in $config} ${ASC_ISSUER_ID:?ASC_ISSUER_ID missing in $config}
key=~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
[[ -f $key ]] || { echo "error: the App Store Connect key AuthKey_${ASC_KEY_ID}.p8 is missing." >&2; exit 2; }
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

grep -qxF "    MARKETING_VERSION: '1.0.0'" "$SPEC" || fail "apps/ios/project.yml's MARKETING_VERSION isn't '1.0.0' (AGENTS.md rule 2)"
CURRENT=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *\([0-9]*\)$/\1/p' "$SPEC" | head -1)
[[ $CURRENT == <-> ]] || fail "couldn't read CURRENT_PROJECT_VERSION from apps/ios/project.yml"
(( BUILD >= CURRENT )) || fail "build $BUILD is lower than apps/ios/project.yml's $CURRENT; App Store Connect refuses a lower or reused build"

# One xcodebuild at a time on this Mac.
said=0
while pgrep -x xcodebuild >/dev/null; do
  (( said )) || { echo "Waiting for another xcodebuild to finish…"; said=1; }
  sleep 15
done

if [[ -n $OUT ]]; then mkdir -p "$OUT"; S=${OUT:A}; else S=$(mktemp -d "${TMPDIR:-/tmp}/tsukumo-ios.XXXXXX"); fi
echo "Build folder: $S"

if (( BUILD != CURRENT )); then
  sed -i '' "s/^\( *CURRENT_PROJECT_VERSION:\) *[0-9]*$/\1 $BUILD/" "$SPEC"
  grep -q "^ *CURRENT_PROJECT_VERSION: $BUILD$" "$SPEC" || fail "couldn't set the build number"
  echo "apps/ios/project.yml: CURRENT_PROJECT_VERSION $CURRENT → $BUILD"
fi

(cd "$REPO/apps/ios" && xcodegen generate --quiet)

ARCHIVE=$S/Tsukumo-1.0.0-$BUILD.xcarchive
echo "Archiving Tsukumo 1.0.0 ($BUILD)…"
xcodebuild archive \
  -project "$REPO/apps/ios/Tsukumo.xcodeproj" \
  -scheme Tsukumo \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$S/DerivedData" \
  CURRENT_PROJECT_VERSION=$BUILD \
  "${AUTH[@]}" -quiet > "$S/archive.log" 2>&1 \
  || { tail -40 "$S/archive.log" >&2; fail "the archive failed (log: $S/archive.log)"; }

ARCHIVED=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$ARCHIVE/Info.plist")
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleIdentifier' "$ARCHIVE/Info.plist")
[[ $ARCHIVED == $BUILD ]] || fail "the archive's build is $ARCHIVED, not $BUILD"
[[ $BUNDLE == com.zlichtman.tsukumo ]] || fail "the archive's bundle ID is $BUNDLE, not com.zlichtman.tsukumo"
echo "Archived: $ARCHIVE"

if (( ! UPLOAD )); then
  echo "Not uploaded (--no-upload)."
  exit 0
fi

echo "Uploading to App Store Connect…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$S/export" \
  "${AUTH[@]}" > "$S/export.log" 2>&1 \
  || { tail -40 "$S/export.log" >&2; fail "the upload failed (log: $S/export.log)"; }
echo "Uploaded Tsukumo 1.0.0 ($BUILD). Apple processes it next: check its status in App Store Connect or TestFlight before reporting it."
