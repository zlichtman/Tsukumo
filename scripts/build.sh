#!/bin/zsh
# Builds what a change touched, so it compiles before it ships. There is no test suite (the owner, October 8, 2026:
# "we're going to just ship stuff and I will find the errors"); write the safest code you can, and test one thing by
# hand when that's what would catch an error.
#
#   apps/macos, TsukumoKit   a Debug build of the Mac app (it builds TsukumoKit's code the Mac uses)
#   apps/ios, TsukumoKit     a simulator build of the iPhone app
#   relay                    the typecheck
#   scripts                  `zsh -n` on each changed script
#
# "Changed" means the working tree, committed or not, against origin/main (or main on a branch). Builds go to one
# incremental cache per checkout in ~/Library/Caches/Tsukumo, outside iCloud Drive.
#
# Usage: scripts/build.sh [--all]
set -euo pipefail

ALL=0
[[ ${1:-} == --all ]] && ALL=1

ROOT=$(git -C "${0:A:h}" rev-parse --show-toplevel)
cd "$ROOT"
CACHE=$HOME/Library/Caches/Tsukumo
BUILDS=$CACHE/${ROOT:t}
mkdir -p "$BUILDS"
# A checkout's builds go when its worktree goes.
LIVE=(${(f)"$(git worktree list --porcelain | sed -n 's/^worktree //p')"})
for cache in "$CACHE"/*(N/); do
  [[ ${cache:t} == SourcePackages ]] && continue
  (( ${LIVE[(I)*/${cache:t}]} )) || rm -rf -- "${cache:?}"
done

[[ $(git branch --show-current) == main ]] && BASE=origin/main || BASE=main
CHANGED=("${(@f)$( { git diff --name-only "$(git merge-base "$BASE" HEAD)"; git ls-files --others --exclude-standard; } )}")
CHANGED=(${CHANGED:#})
touched() { (( ALL )) && return 0; local p; for p in "$@"; do (( ${CHANGED[(I)$p*]} )) && return 0; done; return 1; }
run() {  # run <log name> <command…>: quiet, with the end of the log on failure
  local log=$BUILDS/$1.log; shift
  if "$@" > "$log" 2>&1; then return 0; fi
  grep -E "error:" "$log" | sort -u | head -20; echo "FAILED (log: $log)" >&2; return 1
}
wait_xcode() { while pgrep -x xcodebuild >/dev/null; do sleep 10; done; }
XC=(-skipPackagePluginValidation -skipMacroValidation
    -clonedSourcePackagesDirPath "${TSUKUMO_SPM_CACHE:-$HOME/Library/Caches/tsukumo-release/SourcePackages}")

for s in ${(M)CHANGED:#scripts/*.sh}; do [[ -f $s ]] && zsh -n "$s"; done

if touched apps/macos TsukumoKit; then
  echo "== The Mac app"
  (cd apps/macos && run mac-xcodegen xcodegen generate)
  wait_xcode
  run mac-build xcodebuild build -project apps/macos/Tsukumo.xcodeproj -scheme Tsukumo -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$BUILDS/mac-dd" "${XC[@]}"
  echo "  built: $BUILDS/mac-dd/Build/Products/Debug/Tsukumo.app"
fi

if touched apps/ios TsukumoKit; then
  echo "== The iPhone app"
  (cd apps/ios && run ios-xcodegen xcodegen generate)
  wait_xcode
  run ios-build xcodebuild build -project apps/ios/Tsukumo.xcodeproj -scheme Tsukumo -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$BUILDS/ios-dd" "${XC[@]}"
  echo "  built"
fi

if touched relay; then
  echo "== The relay"
  [[ -d relay/node_modules ]] || run relay-install npm --prefix relay ci
  run relay-typecheck npm --prefix relay run typecheck
  echo "  typechecked"
fi

echo "Built."
