#!/bin/zsh
# Releases Tsukumo for Mac (apps/macos, com.zlichtman.tsukumo.mac, the side dock of your bots), only
# when the owner approves a release: one notarized Developer ID build for everyone, installed with
# Homebrew (`brew install --cask zlichtman/tap/tsukumo`) or downloaded from the owner's website.
# The version is 2.<NN>: build 200 is version 2.00 (AGENTS.md rule 2).
#
#   1. Checks the preconditions, waits until the screen is unlocked and no xcodebuild or notarytool runs.
#   2. Runs TsukumoKit's tests (`swift test`) on a clean export of the committed code (`git archive HEAD`).
#   3. Sets CURRENT_PROJECT_VERSION in apps/macos/project.yml to <build> and MARKETING_VERSION to
#      2.<build - 200> (build 200 is 2.00, build 201 is 2.01).
#   4. Builds the Developer ID app. By default with TSUKUMO_CAPABILITIES=Local (no iCloud or Sign in
#      with Apple; both need a Developer ID provisioning profile): archived with manual Developer ID
#      signing, no profile. With --with-icloud, or when a Developer ID profile for
#      com.zlichtman.tsukumo.mac carrying both is installed on this Mac, it archives with
#      TSUKUMO_CAPABILITIES=iCloud and automatic signing, and exports developer-id with that profile.
#      Then it notarizes and staples the app, builds the themed DMG (scripts/dmg), and signs,
#      notarizes and staples it.
#   5. Website (PORTFOLIO): public/downloads/Tsukumo-<version>.dmg (Tsukumo-2.00.dmg) replaces the
#      previous DMG (Homebrew wants a versioned URL for a fixed sha256), /downloads/Tsukumo.dmg
#      redirects to it (next.config.ts, so the site's download link keeps working), and
#      public/downloads/tsukumo.json is the feed the cask's livecheck reads (version, build, url,
#      sha256, minimumMacOS, notes).
#      Commits as the no-reply identity, pushes, and deploys with the Vercel CLI from a clean
#      `git archive HEAD` export (the site has no Git integration), then checks the live DMG is 200
#      with the same SHA-256.
#   6. Homebrew: Casks/tsukumo.rb in zlichtman/homebrew-tap (the one public repo, casks only) gets
#      version "<version>", the sha256, the url Tsukumo-#{version}.dmg, a livecheck that reads the
#      feed's version, `uninstall quit` for com.zlichtman.tsukumo.mac, and no `auto_updates` (this
#      app has no updater of its own, so `brew upgrade` updates it), keeping everything else
#      (depends_on); `brew style` and `brew audit --online` must pass; commits, pushes.
#   7. Verifies the live download, the redirect, the feed, and `brew fetch` from the tap.
#   8. Commits and pushes the build number bump to main.
#   9. Prints a summary.
# Never a public GitHub repo or release, and no git tag. Stops at the first failure.
#
# Usage: scripts/release-mac.sh <build> [--dry-run] [--out <folder>] [--with-icloud] [--notes "<one line>"]
#   --dry-run      builds, notarizes, and checks a real candidate, then prints what steps 5 to 8
#                  would change (files, diffs, commands) without committing, pushing, deploying, or
#                  tagging. It never edits this repo, the site, or the tap. The cask is checked in a
#                  throwaway local tap (brew style, and brew audit without --online).
#   --out          where the build goes (default: a new temporary folder). Kept after a dry run.
#   --with-icloud  build with iCloud and Sign in with Apple even without an installed profile
#                  (Xcode's automatic signing then has to make one).
#   --notes        the feed's one line about what's new (default "Tsukumo <version>.").
set -euo pipefail

usage='usage: release-mac.sh <build> [--dry-run] [--out <folder>] [--with-icloud] [--notes "<one line>"]'
BUILD=${1:?$usage}; shift
DRY=0; OUT=""; WITH_ICLOUD=0; NOTES=""
while (( $# )); do
  case $1 in
    --dry-run) DRY=1 ;;
    --out) OUT=${2:?$usage}; shift ;;
    --with-icloud) WITH_ICLOUD=1 ;;
    --notes) NOTES=${2:?$usage}; shift ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
  shift
done
[[ $BUILD == <-> ]] && (( BUILD >= 200 && BUILD < 300 )) || { echo "The build must be 200 to 299 (build 200 is version 2.00)." >&2; exit 2; }
BUILD=$(( BUILD ))
VERSION=$(printf '2.%02d' $(( BUILD - 200 )))
[[ -n $NOTES ]] || NOTES="Tsukumo $VERSION."

REPO=${0:A:h:h}
SITE="$HOME/Library/Mobile Documents/com~apple~CloudDocs/LIFE/PORTFOLIO"
TAP=$(brew --repository zlichtman/tap)
CASK=zlichtman/tap/tsukumo
ORIGIN=https://zlichtman.com
TEAM=28LJG7MXT3
BUNDLE_ID=com.zlichtman.tsukumo.mac
YML=apps/macos/project.yml
ID="Developer ID Application: Zach Lichtman ($TEAM)"
NOREPLY_NAME="Zach Lichtman"; NOREPLY_EMAIL=130262074+zlichtman@users.noreply.github.com
DMGBUILD=~/.venvs/dmgbuild/bin/dmgbuild
SPM_CACHE=${TSUKUMO_SPM_CACHE:-$HOME/Library/Caches/tsukumo-release/SourcePackages}

source ~/.appstoreconnect/kemosabe.env
: ${ASC_KEY_ID:?missing in kemosabe.env} ${ASC_ISSUER_ID:?missing in kemosabe.env}
KEY=~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
[[ -f $KEY ]] || { echo "The App Store Connect key is missing." >&2; exit 2; }
# The key signs in to Apple only for the iCloud export's profile; the default build needs no profile.
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
COMMON=(-parallel-testing-enabled NO -skipPackagePluginValidation -skipMacroValidation -clonedSourcePackagesDirPath "$SPM_CACHE")

grep -qE "^    MARKETING_VERSION: '2\.[0-9]{2}'$" "$REPO/$YML" \
  || { echo "$YML's MARKETING_VERSION isn't a 2.<NN> version (build 200 is 2.00)." >&2; exit 1; }
MIN_MACOS=$(sed -n "s/^ *macOS: '\(.*\)'$/\1/p" "$REPO/$YML" | head -1)
[[ $MIN_MACOS == <->.<-> ]] || { echo "Couldn't read the macOS deployment target from $YML." >&2; exit 1; }
DMG_NAME=Tsukumo-$VERSION.dmg
DMG_URL=$ORIGIN/downloads/$DMG_NAME
STABLE_URL=$ORIGIN/downloads/Tsukumo.dmg
FEED_URL=$ORIGIN/downloads/tsukumo.json

if [[ -n $OUT ]]; then mkdir -p "$OUT"; S=${OUT:A}; else S=$(mktemp -d "${TMPDIR:-/tmp}/tsukumo-release.XXXXXX"); fi
DRYTAP=""
cleanup() {
  local code=$?
  # brew untap refuses a tap it doesn't trust, so the throwaway tap's folder is removed directly.
  if [[ $DRYTAP == zlichtman/tsukumo-dryrun-<-> ]]; then rm -rf "${$(brew --repository "$DRYTAP"):?}"; fi
  if (( code == 0 && DRY == 0 )) && [[ -z $OUT ]]; then rm -rf "${S:?}"; else echo "Build folder: $S"; fi
}
trap cleanup EXIT
step() { print -P "%B== $*%b"; }
fail() { echo "FAILED: $*" >&2; exit 1; }
would() { echo "  [dry run] would $*"; }
git_noreply() { GIT_AUTHOR_NAME=$NOREPLY_NAME GIT_AUTHOR_EMAIL=$NOREPLY_EMAIL GIT_COMMITTER_NAME=$NOREPLY_NAME GIT_COMMITTER_EMAIL=$NOREPLY_EMAIL git "$@"; }
screen_locked() {
  local users; users=$(ioreg -n Root -d1 | grep IOConsoleUsers || true)
  [[ $users == *'"CGSSessionScreenIsLocked"=Yes'* || $users != *'"kCGSSessionOnConsoleKey"=Yes'* ]]
}
# One xcodebuild or notarytool at a time on this Mac, and Mac tests need the screen unlocked.
wait_quiet() {
  local said=0
  while pgrep -x xcodebuild >/dev/null || pgrep -x notarytool >/dev/null || screen_locked; do
    (( said )) || { echo "  waiting for the screen to be unlocked and other builds to finish…"; said=1; }
    sleep 20
  done
}
notarize() {  # notarize <file>: waits, and prints Apple's log when it isn't Accepted
  wait_quiet
  xcrun notarytool submit "$1" --key "$KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait --timeout 45m \
    --output-format json > "$S/notary-${1:t}.json" || true
  local notary_status notary_id
  notary_status=$(plutil -extract status raw "$S/notary-${1:t}.json" 2>/dev/null || echo unknown)
  notary_id=$(plutil -extract id raw "$S/notary-${1:t}.json" 2>/dev/null || echo "")
  echo "  notarization of ${1:t}: $notary_status ($notary_id)"
  if [[ $notary_status != Accepted ]]; then
    [[ -n $notary_id ]] && xcrun notarytool log "$notary_id" --key "$KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" || true
    fail "notarization of ${1:t}"
  fi
}
# The newest unexpired Developer ID profile for the app that carries iCloud and Sign in with Apple
# (made in the developer portal with the "Developer ID Application" certificate), or nothing.
installed_profile() {
  python3 - "$TEAM.$BUNDLE_ID" <<'PY'
import datetime, glob, os, plistlib, subprocess, sys
want, best = sys.argv[1], None
home = os.path.expanduser("~")
for path in glob.glob(f"{home}/Library/Developer/Xcode/UserData/Provisioning Profiles/*.provisionprofile") + \
            glob.glob(f"{home}/Library/MobileDevice/Provisioning Profiles/*.provisionprofile"):
    raw = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True).stdout
    try: p = plistlib.loads(raw)
    except Exception: continue
    e = p.get("Entitlements", {})
    if not p.get("ProvisionsAllDevices") or e.get("com.apple.application-identifier") != want: continue
    if p["ExpirationDate"].replace(tzinfo=datetime.timezone.utc) < datetime.datetime.now(datetime.timezone.utc): continue
    if "com.apple.developer.applesignin" not in e or "iCloud.com.zlichtman.tsukumo" not in e.get("com.apple.developer.icloud-container-identifiers", []): continue
    if best is None or p["CreationDate"] > best["CreationDate"]: best = p
print(best["Name"] if best else "")
PY
}

# ---------------------------------------------------------------------------------------------
step "1. Preconditions (build $BUILD, version $VERSION$( (( DRY )) && echo ', dry run'))"
# The cask's build: version "1.80" now, or "1.0.0,79" from before the version was 1.<build>.
PUBLISHED=$(sed -n -e 's/^ *version "[^,"]*,\([0-9]*\)"$/\1/p' -e 's/^ *version "1\.\([0-9]*\)"$/\1/p' "$TAP/Casks/tsukumo.rb")
COMMITTED=$(git -C "$REPO" show HEAD:$YML | sed -n 's/^ *CURRENT_PROJECT_VERSION: *\([0-9]*\)$/\1/p')
(( BUILD > ${PUBLISHED:-0} )) || fail "build $BUILD isn't newer than the published $PUBLISHED"
(( BUILD >= ${COMMITTED:-0} )) || fail "build $BUILD is older than $YML's $COMMITTED"
if (( ! DRY )); then
  # main, or a clean worktree branch of it (the main checkout may hold another session's work); it pushes HEAD to main.
  git -C "$REPO" diff --quiet HEAD -- apps/macos TsukumoKit scripts ':!*.pbxproj' || fail "the checkout has uncommitted changes in apps/macos, TsukumoKit, or scripts"
  git -C "$REPO" diff --quiet HEAD -- $YML || fail "$YML has uncommitted changes"
  git -C "$REPO" fetch -q origin main
  git -C "$REPO" merge-base --is-ancestor origin/main HEAD || fail "main is behind origin/main; pull first"
fi
[[ -x $DMGBUILD ]] || { python3 -m venv ~/.venvs/dmgbuild && ~/.venvs/dmgbuild/bin/pip install -q dmgbuild; }
for tool in xcodegen vercel; do command -v $tool >/dev/null || fail "$tool isn't installed"; done
security find-identity -v -p codesigning | grep -qF "$ID" || fail "the Developer ID Application identity isn't in the keychain"
PROFILE_SPEC=$(installed_profile)
if [[ -n $PROFILE_SPEC ]] || (( WITH_ICLOUD )); then ICLOUD=1; else ICLOUD=0; fi
if (( ICLOUD )); then
  ENTITLEMENTS_NOTE="iCloud and Sign in with Apple ON ($([[ -n $PROFILE_SPEC ]] && echo "installed profile \"$PROFILE_SPEC\"" || echo "--with-icloud, automatic signing makes the profile"))"
else
  ENTITLEMENTS_NOTE="iCloud and Sign in with Apple OFF (no Developer ID profile for $BUNDLE_ID installed; like the website build)"
fi
echo "  published build ${PUBLISHED:-none}, project.yml at HEAD $COMMITTED, repo $(git -C "$REPO" rev-parse --short HEAD)"
echo "  $ENTITLEMENTS_NOTE"
wait_quiet

# ---------------------------------------------------------------------------------------------
step "2. TsukumoKit tests (a clean export of HEAD)"
mkdir -p "$S/src" "$SPM_CACHE"
rm -rf "${S:?}/src"/*(N)
git -C "$REPO" archive HEAD | tar -x -C "$S/src"
# The build number goes into the export right away, so what's tested is what ships.
sed -i '' -e "s/^\( *CURRENT_PROJECT_VERSION:\) *[0-9]*$/\1 $BUILD/" -e "s/^\( *MARKETING_VERSION:\) *'[0-9.]*'$/\1 '$VERSION'/" "$S/src/$YML"
grep -q "^ *CURRENT_PROJECT_VERSION: $BUILD$" "$S/src/$YML" || fail "couldn't set the build number"
(cd "$S/src/apps/macos" && xcodegen generate --quiet)
PROJECT="$S/src/apps/macos/Tsukumo.xcodeproj"
wait_quiet
# The app has no test target; its logic is TsukumoKit's, tested here (the export's path has no spaces).
swift test --package-path "$S/src/TsukumoKit" --scratch-path "$S/kit-build" > "$S/tests.log" 2>&1 \
  || { tail -40 "$S/tests.log"; fail "TsukumoKit tests (log: $S/tests.log)"; }
TESTS=$(python3 - "$S/tests.log" <<'PY'
import re, sys
log = open(sys.argv[1]).read()
xc = [int(n) for n in re.findall(r"Executed (\d+) tests?, with 0 failures", log)]
st = sum(int(n) for n in re.findall(r"Test run with (\d+) tests? in \d+ suites? passed", log))
print("%d tests passed (%d XCTest, %d Swift Testing), 0 failed" % ((max(xc) if xc else 0) + st, max(xc) if xc else 0, st))
PY
)
echo "  $TESTS"

# ---------------------------------------------------------------------------------------------
step "3. Build number $BUILD in $YML"
if (( DRY )); then
  would "set CURRENT_PROJECT_VERSION: $COMMITTED → $BUILD in $YML (the export already has it)"
else
  sed -i '' -e "s/^\( *CURRENT_PROJECT_VERSION:\) *[0-9]*$/\1 $BUILD/" -e "s/^\( *MARKETING_VERSION:\) *'[0-9.]*'$/\1 '$VERSION'/" "$REPO/$YML"
  git -C "$REPO" diff --stat -- $YML
fi

# ---------------------------------------------------------------------------------------------
step "4. Developer ID app, notarized; the DMG"
wait_quiet
if (( ICLOUD )); then
  xcodebuild archive -project "$PROJECT" -scheme Tsukumo -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$S/Tsukumo.xcarchive" -derivedDataPath "$S/dd-archive" "${COMMON[@]}" "${AUTH[@]}" \
    TSUKUMO_CAPABILITIES=iCloud CURRENT_PROJECT_VERSION=$BUILD MARKETING_VERSION=$VERSION -quiet > "$S/archive.log" 2>&1 \
    || { tail -40 "$S/archive.log"; fail "archive (log: $S/archive.log)"; }
  if [[ -n $PROFILE_SPEC ]]; then
    echo "  export with the installed Developer ID profile \"$PROFILE_SPEC\""
    SIGNING="<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>Developer ID Application</string>
<key>provisioningProfiles</key><dict><key>$BUNDLE_ID</key><string>$PROFILE_SPEC</string></dict>"
  else
    echo "  no Developer ID profile installed; Xcode's automatic signing makes one (--with-icloud)"
    SIGNING="<key>signingStyle</key><string>automatic</string>"
  fi
  cat > "$S/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>destination</key><string>export</string>
$SIGNING
<key>teamID</key><string>$TEAM</string>
</dict></plist>
PLIST
  wait_quiet
  rm -rf "${S:?}/export"
  xcodebuild -exportArchive -archivePath "$S/Tsukumo.xcarchive" -exportOptionsPlist "$S/ExportOptions.plist" \
    -exportPath "$S/export" "${AUTH[@]}" > "$S/export.log" 2>&1 \
    || { tail -40 "$S/export.log"; fail "Developer ID export (log: $S/export.log). If Apple refused a capability, it's quoted above."; }
  APP="$S/export/Tsukumo.app"
else
  # No restricted entitlements (TSUKUMO_CAPABILITIES=Local), so no profile.
  xcodebuild archive -project "$PROJECT" -scheme Tsukumo -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$S/Tsukumo.xcarchive" -derivedDataPath "$S/dd-archive" "${COMMON[@]}" \
    TSUKUMO_CAPABILITIES=Local CURRENT_PROJECT_VERSION=$BUILD MARKETING_VERSION=$VERSION \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=$TEAM "CODE_SIGN_IDENTITY=$ID" \
    PROVISIONING_PROFILE_SPECIFIER= "OTHER_CODE_SIGN_FLAGS=--timestamp" -quiet > "$S/archive.log" 2>&1 \
    || { tail -40 "$S/archive.log"; fail "archive (log: $S/archive.log)"; }
  rm -rf "${S:?}/export"; mkdir -p "$S/export"
  /usr/bin/ditto "$S/Tsukumo.xcarchive/Products/Applications/Tsukumo.app" "$S/export/Tsukumo.app"
  APP="$S/export/Tsukumo.app"
fi

echo "  checking the signature and entitlements"
codesign --verify --deep --strict "$APP" || fail "codesign --verify"
codesign -dvv "$APP" > "$S/codesign.txt" 2>&1
grep -qF "Authority=$ID" "$S/codesign.txt" || fail "not signed with $ID"
grep -q "flags=.*runtime" "$S/codesign.txt" || fail "the hardened runtime is off"
codesign -d --entitlements - --xml "$APP" 2>/dev/null > "$S/entitlements.plist" || true
plutil -p "$S/entitlements.plist" > "$S/entitlements.txt" 2>/dev/null || : > "$S/entitlements.txt"
grep -q 'get-task-allow' "$S/entitlements.txt" && fail "get-task-allow is in a release build"
if (( ICLOUD )); then
  grep -q '"iCloud.com.zlichtman.tsukumo"' "$S/entitlements.txt" || fail "the iCloud container is missing"
  [[ $(/usr/libexec/PlistBuddy -c 'Print TsukumoCapabilities' "$APP/Contents/Info.plist") == iCloud ]] || fail "TsukumoCapabilities isn't iCloud"
  grep -q '"com.apple.developer.icloud-container-environment" => "Production"' "$S/entitlements.txt" || fail "the CloudKit environment isn't Production"
  grep -q '"com.apple.developer.applesignin"' "$S/entitlements.txt" || fail "Sign in with Apple is missing"
  security cms -D -i "$APP/Contents/embedded.provisionprofile" > "$S/profile.plist" 2>/dev/null || fail "no embedded provisioning profile"
  [[ $(plutil -extract ProvisionsAllDevices raw "$S/profile.plist" 2>/dev/null) == true ]] || fail "the profile isn't a Developer ID profile"
  PROFILE_NAME=$(plutil -extract Name raw "$S/profile.plist")
  echo "  profile: $PROFILE_NAME"
else
  grep -q 'icloud\|applesignin' "$S/entitlements.txt" && fail "iCloud or Sign in with Apple is in a build without a profile"
  [[ $(/usr/libexec/PlistBuddy -c 'Print TsukumoCapabilities' "$APP/Contents/Info.plist") == Local ]] || fail "TsukumoCapabilities isn't Local"
  PROFILE_NAME="none (no restricted entitlements)"
fi
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist") == "$BUILD" ]] || fail "the app isn't build $BUILD"
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist") == "$VERSION" ]] || fail "the app isn't version $VERSION"
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist") == "$BUNDLE_ID" ]] || fail "bundle ID"
echo "  entitlements: $(grep -o '"com\.apple\.[^"]*"' "$S/entitlements.txt" | tr -d '"' | tr '\n' ' ')"

echo "  notarizing the app, then stapling it (so a Homebrew install opens offline too)"
/usr/bin/ditto -c -k --keepParent "$APP" "$S/Tsukumo-app.zip"
notarize "$S/Tsukumo-app.zip"
xcrun stapler staple -q "$APP"
spctl -a -t exec -vv "$APP" 2>&1 | tee "$S/spctl-app.txt" | sed 's/^/  /'
grep -q "source=Notarized Developer ID" "$S/spctl-app.txt" || fail "Gatekeeper doesn't accept the app"

echo "  building the themed DMG"
HERE="$S/src/scripts/dmg"
[[ -f $HERE/background.tiff ]] || tiffutil -cathidpicheck "$HERE/background.png" "$HERE/background@2x.png" -out "$HERE/background.tiff" >/dev/null
DMG="$S/$DMG_NAME"
rm -f "${DMG:?}"
$DMGBUILD -s "$HERE/settings.py" -D app="$APP" -D here="$HERE" Tsukumo "$DMG" > "$S/dmgbuild.log" 2>&1 || { tail -20 "$S/dmgbuild.log"; fail "dmgbuild"; }
codesign --sign "$ID" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple -q "$DMG"
xcrun stapler validate -q "$DMG" || fail "stapler validate"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | tee "$S/spctl-dmg.txt" | sed 's/^/  /'
grep -q "source=Notarized Developer ID" "$S/spctl-dmg.txt" || fail "Gatekeeper doesn't accept the DMG"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
SIZE=$(stat -f %z "$DMG")
echo "  $DMG_NAME: $SIZE bytes, SHA-256 $SHA"

# ---------------------------------------------------------------------------------------------
step "5. Website ($SITE)"
python3 - "$S/tsukumo.json" "$VERSION" "$BUILD" "$DMG_URL" "$SHA" "$MIN_MACOS" "$NOTES" <<'PY'
import json, sys
path, version, build, url, sha, minimum, notes = sys.argv[1:]
feed = {"version": version, "build": int(build), "url": url, "sha256": sha, "minimumMacOS": minimum, "notes": notes}
open(path, "w").write(json.dumps(feed, indent=2, ensure_ascii=False) + "\n")
PY
REDIRECT_LINE="const tsukumoDownload = \"/downloads/$DMG_NAME\";"
# next.config.ts: the constant /downloads/Tsukumo.dmg redirects to (added the first time).
edit_next_config() {  # edit_next_config <file>
  python3 - "$1" "$REDIRECT_LINE" <<'PY'
import re, sys
path, line = sys.argv[1], sys.argv[2]
src = open(path).read()
if re.search(r'^const tsukumoDownload = ".*";$', src, re.M):
    src = re.sub(r'^const tsukumoDownload = ".*";$', lambda _: line, src, count=1, flags=re.M)
else:
    anchor = 'import type { NextConfig } from "next";\n'
    if src.count(anchor) != 1 or src.count("    return [\n") != 1:
        sys.exit("next.config.ts changed shape; add the Tsukumo redirect by hand")
    src = src.replace(anchor, anchor + "\n// The current Tsukumo download, set by KemoSabe's scripts/release-mac.sh. /downloads/Tsukumo.dmg\n"
                      "// redirects here (temporary, so it follows each release), and the site's download link keeps working.\n" + line + "\n", 1)
    src = src.replace("    return [\n", '    return [\n      { source: "/downloads/Tsukumo.dmg", destination: tsukumoDownload, permanent: false },\n', 1)
open(path, "w").write(src)
PY
  grep -qxF "$REDIRECT_LINE" "$1" || fail "next.config.ts edit"
  grep -qF 'source: "/downloads/Tsukumo.dmg", destination: tsukumoDownload' "$1" || fail "next.config.ts redirect"
  if [[ -d $SITE/node_modules/typescript ]]; then  # a syntax check; Vercel's build is the full one
    NODE_PATH="$SITE/node_modules" node -e '
      const ts = require("typescript"), fs = require("fs");
      const out = ts.transpileModule(fs.readFileSync(process.argv[1], "utf8"), { reportDiagnostics: true, compilerOptions: { module: ts.ModuleKind.ESNext } });
      if (out.diagnostics.length) { console.error(out.diagnostics.map(d => ts.flattenDiagnosticMessageText(d.messageText, "\n")).join("\n")); process.exit(1); }' "$1" \
      || fail "next.config.ts doesn't parse"
  fi
}
# The previous downloads to remove: the unversioned Tsukumo.dmg and any other versioned one.
OLD_DMGS=("$SITE"/public/downloads/Tsukumo.dmg(N:t) "$SITE"/public/downloads/Tsukumo-*.dmg(N:t))
OLD_DMGS=(${OLD_DMGS:#$DMG_NAME})
SITE_PATHS=(public/downloads/$DMG_NAME public/downloads/tsukumo.json next.config.ts ${OLD_DMGS/#/public/downloads/})
git -C "$SITE" fetch -q origin main
[[ $(git -C "$SITE" branch --show-current) == main ]] || fail "the site isn't on main"
[[ -z $(git -C "$SITE" status --porcelain -- "${SITE_PATHS[@]}") ]] || fail "the site has uncommitted changes in ${SITE_PATHS[*]}"
[[ -f $SITE/.vercel/project.json ]] || fail "the site has no .vercel/project.json"
SITE_MESSAGE="Tsukumo download: $VERSION ($BUILD), notarized. SHA-256 $SHA"
if (( DRY )); then
  mkdir -p "$S/site-preview"
  cp "$SITE/next.config.ts" "$S/site-preview/next.config.ts"
  edit_next_config "$S/site-preview/next.config.ts"
  would "add public/downloads/$DMG_NAME ($SIZE bytes)"
  for old in $OLD_DMGS; do would "delete public/downloads/$old"; done
  would "write public/downloads/tsukumo.json:"; sed 's/^/      /' "$S/tsukumo.json"
  would "change next.config.ts:"; diff -u "$SITE/next.config.ts" "$S/site-preview/next.config.ts" | sed 's/^/      /' || true
  would "commit those paths as $NOREPLY_NAME <$NOREPLY_EMAIL>: \"$SITE_MESSAGE\""
  echo "  site main vs origin/main (behind/ahead): $(git -C "$SITE" rev-list --left-right --count origin/main...HEAD | tr '\t' '/')"
  would "git push origin main, then deploy a clean 'git archive HEAD' export with: vercel deploy --prod --yes"
  echo "  vercel CLI signed in as: $(vercel whoami 2>/dev/null || echo 'NOT SIGNED IN')"
else
  git -C "$SITE" pull -q --ff-only origin main
  cp "$DMG" "$SITE/public/downloads/$DMG_NAME"
  cp "$S/tsukumo.json" "$SITE/public/downloads/tsukumo.json"
  edit_next_config "$SITE/next.config.ts"
  for old in $OLD_DMGS; do git -C "$SITE" rm -q -- "public/downloads/$old"; done
  git -C "$SITE" add -- "public/downloads/$DMG_NAME" public/downloads/tsukumo.json next.config.ts
  git_noreply -C "$SITE" commit -q -m "$SITE_MESSAGE" -- "${SITE_PATHS[@]}"
  git -C "$SITE" push -q origin main
  echo "== deploy"
  rm -rf "${S:?}/site"; mkdir -p "$S/site/.vercel"
  git -C "$SITE" archive HEAD | tar -x -C "$S/site"
  cp "$SITE/.vercel/project.json" "$S/site/.vercel/"
  (cd "$S/site" && vercel deploy --prod --yes > "$S/vercel.log" 2>&1) || { tail -20 "$S/vercel.log"; fail "Vercel deploy"; }
  # The live copy must be exactly what was notarized (a few tries while the deploy settles).
  for try in {1..10}; do
    LIVE=$(curl -sfL "$DMG_URL" | shasum -a 256 | cut -d' ' -f1) || LIVE=""
    [[ $LIVE == "$SHA" ]] && break; sleep 15
  done
  [[ $LIVE == "$SHA" ]] || fail "the live $DMG_URL doesn't match (got ${LIVE:-nothing})"
fi

# ---------------------------------------------------------------------------------------------
step "6. Homebrew cask ($TAP/Casks/tsukumo.rb)"
CASK_URL='  url "https://zlichtman.com/downloads/Tsukumo-#{version}.dmg"'
# The feed's version is the cask's version (1.80), so livecheck reads just that.
CASK_LIVECHECK='  livecheck do
    url "https://zlichtman.com/downloads/tsukumo.json"
    strategy :json do |json|
      json["version"]
    end
  end'
update_cask() {  # update_cask <file>: version, sha256, url, livecheck, uninstall quit, no auto_updates; everything else stays
  sed -i '' -e "s/^\( *version \)\"[^\"]*\"$/\1\"$VERSION\"/" -e "s/^\( *sha256 \)\"[0-9a-f]*\"$/\1\"$SHA\"/" "$1"
  python3 - "$1" "$CASK_URL" "$CASK_LIVECHECK" "$BUNDLE_ID" <<'PY'
import re, sys
path, url, livecheck, bundle = sys.argv[1:]
src = open(path).read()
src, n = re.subn(r'^  url ".*"$', lambda _: url, src, count=1, flags=re.M)
if n != 1: sys.exit("the cask has no url line")
src, n = re.subn(r'^  livecheck do\n.*?^  end$', lambda _: livecheck, src, count=1, flags=re.M | re.S)
if n != 1: sys.exit("the cask has no livecheck block")
# This Tsukumo has no updater of its own, so brew upgrade updates it.
src = re.sub(r'^  auto_updates true\n', '', src, flags=re.M)
src, n = re.subn(r'^  uninstall quit: ".*"$', lambda _: '  uninstall quit: "%s"' % bundle, src, count=1, flags=re.M)
if n != 1: sys.exit("the cask has no uninstall quit line")
open(path, "w").write(src)
PY
  grep -qx "  version \"$VERSION\"" "$1" || fail "the cask's version line"
  grep -qx "  sha256 \"$SHA\"" "$1" || fail "the cask's sha256 line"
  grep -qxF "$CASK_URL" "$1" || fail "the cask's url line"
  grep -qxF '      json["version"]' "$1" || fail "the cask's livecheck"
  grep -qx '  auto_updates true' "$1" && fail "the cask still has auto_updates true"
  grep -qx '  depends_on macos: :tahoe' "$1" || fail "the cask lost depends_on macos: :tahoe"
  grep -qx "  uninstall quit: \"$BUNDLE_ID\"" "$1" || fail "the cask's uninstall quit"
}
git -C "$TAP" fetch -q origin
[[ -z $(git -C "$TAP" status --porcelain -- Casks/tsukumo.rb) ]] || fail "the tap has uncommitted changes to Casks/tsukumo.rb"
CASK_MESSAGE="tsukumo $VERSION"
if (( DRY )); then
  # A throwaway local tap, so style and audit check the new cask without touching zlichtman/tap.
  DRYTAP=zlichtman/tsukumo-dryrun-$$
  brew tap-new -q --no-git "$DRYTAP" >/dev/null
  DRYCASK="$(brew --repository "$DRYTAP")/Casks/tsukumo.rb"
  mkdir -p "${DRYCASK:h}"; cp "$TAP/Casks/tsukumo.rb" "$DRYCASK"
  update_cask "$DRYCASK"
  would "change Casks/tsukumo.rb:"; diff -u "$TAP/Casks/tsukumo.rb" "$DRYCASK" | sed 's/^/      /' || true
  brew style --cask "$DRYTAP/tsukumo" | sed 's/^/  /' || fail "brew style"
  # --online needs the DMG live; the real run audits with it after the deploy.
  brew audit --cask "$DRYTAP/tsukumo" 2>&1 | sed 's/^/  /' || fail "brew audit"
  echo "  brew style and brew audit (offline) pass on the new cask"
  would "commit Casks/tsukumo.rb as $NOREPLY_NAME <$NOREPLY_EMAIL>: \"$CASK_MESSAGE\" and push zlichtman/homebrew-tap"
  echo "  tap main vs origin/main (behind/ahead): $(git -C "$TAP" rev-list --left-right --count origin/main...HEAD | tr '\t' '/')"
else
  git -C "$TAP" pull -q --ff-only origin main
  update_cask "$TAP/Casks/tsukumo.rb"
  brew style --cask "$CASK" || fail "brew style"
  brew audit --cask --online "$CASK" || fail "brew audit --online"
  git_noreply -C "$TAP" commit -q -m "$CASK_MESSAGE" -- Casks/tsukumo.rb
  git -C "$TAP" push -q origin main
fi

# ---------------------------------------------------------------------------------------------
step "7. Verify"
if (( DRY )); then
  would "check: $DMG_URL is 200 with SHA-256 $SHA; $STABLE_URL redirects there; $FEED_URL matches; brew update && brew fetch --cask $CASK matches; brew audit --cask --online $CASK passes"
else
  code=$(curl -s -o /dev/null -w '%{http_code}' "$DMG_URL"); [[ $code == 200 ]] || fail "$DMG_URL returned $code"
  location=$(curl -s -o /dev/null -w '%{redirect_url}' "$STABLE_URL")
  [[ $location == "$DMG_URL" ]] || fail "$STABLE_URL redirects to '${location}', not $DMG_URL"
  [[ $(curl -sf "$FEED_URL" | python3 -c 'import json,sys; j=json.load(sys.stdin); print(j["build"], j["sha256"], j["url"])') == "$BUILD $SHA $DMG_URL" ]] \
    || fail "the live tsukumo.json doesn't match"
  brew update -q
  brew fetch --cask --force "$CASK" >/dev/null
  FETCHED=$(shasum -a 256 "$(brew --cache --cask "$CASK")" | cut -d' ' -f1)
  [[ $FETCHED == "$SHA" ]] || fail "brew fetched SHA-256 $FETCHED"
  brew audit --cask --online "$CASK" || fail "brew audit --online after the push"
  echo "  live download (200), redirect, feed, brew fetch, and audit all match $SHA"
fi

# ---------------------------------------------------------------------------------------------
step "8. Build number on main"
if (( DRY )); then
  if (( COMMITTED == BUILD )); then would "push main ($YML is already at build $BUILD); no tag"
  else would "commit $YML (CURRENT_PROJECT_VERSION $BUILD) on main and push it; no tag"; fi
else
  # The bump may already be committed (build 200 was set ahead of its release).
  if ! git -C "$REPO" diff --quiet HEAD -- $YML; then
    git -C "$REPO" commit -q -m "Tsukumo $VERSION (build $BUILD): released (SHA-256 $SHA)" -- $YML
  fi
  git -C "$REPO" push -q origin HEAD:main
fi

# ---------------------------------------------------------------------------------------------
step "9. Summary"
cat <<SUMMARY
  Tsukumo $VERSION ($BUILD)$( (( DRY )) && echo ' (DRY RUN: nothing committed, pushed, deployed, or tagged)')
  Tests:          $TESTS
  Signed:         $ID; profile: $PROFILE_NAME
  Entitlements:   $ENTITLEMENTS_NOTE
  Notarized:      app and DMG accepted and stapled; Gatekeeper: Notarized Developer ID
  DMG:            $DMG ($SIZE bytes)
  SHA-256:        $SHA
  Download:       $DMG_URL  ($STABLE_URL redirects there)
  Feed:           $FEED_URL (minimum macOS $MIN_MACOS)
  Homebrew:       brew install --cask $CASK (brew upgrade updates it)
SUMMARY
