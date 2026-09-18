#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES=("$ROOT_DIR"/ExperienceSampling/*.swift)
TMP_APP="/tmp/ExperienceSampling.app"
TMP_BIN="$TMP_APP/Contents/MacOS/ExperienceSampling"
DEST_APP="/Applications/ExperienceSampling.app"
ENV_FILE="$ROOT_DIR/.env"

echo "==> Loading environment"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE"
  exit 1
fi
set -a
source "$ENV_FILE"
set +a

if [[ -z "${CODESIGN_CERT:-}" ]]; then
  echo "CODESIGN_CERT is not set in $ENV_FILE"
  exit 1
fi

GIT_REVISION="$(git -C "$ROOT_DIR" rev-parse HEAD)"
GIT_DIRTY=false
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
  GIT_DIRTY=true
fi
echo "==> Building revision $GIT_REVISION (modified: $GIT_DIRTY)"

echo "==> Typechecking"
# -parse-as-library: the entry point is an @main struct (so the source can also
# be compiled as a library into the test binary); without this flag swiftc treats
# a lone file as a script and rejects @main.
swiftc -parse-as-library -typecheck "${SOURCES[@]}"

if command -v swiftlint >/dev/null 2>&1; then
  echo "==> Linting with swiftlint"
  # SwiftLint needs sourcekitdInProc, which isn't on the default search path on
  # a Command Line Tools-only machine (no full Xcode). Point DYLD at the active
  # developer dir's lib so swiftlint can load it.
  SOURCEKIT_LIB="$(xcode-select -p)/usr/lib"
  if [[ -d "$SOURCEKIT_LIB/sourcekitdInProc.framework" ]]; then
    export DYLD_FRAMEWORK_PATH="${DYLD_FRAMEWORK_PATH:+$DYLD_FRAMEWORK_PATH:}$SOURCEKIT_LIB"
  fi
  # Config (.swiftlint.yml) targets the source via `included:`; run from the
  # repo root so it's picked up. --strict matches CI (warnings fail the build).
  # Best-effort locally: a lint hiccup shouldn't block the rebuild — CI enforces it.
  if ! (cd "$ROOT_DIR" && swiftlint lint --strict); then
    echo "==> swiftlint failed (non-fatal locally; CI enforces lint on every PR)"
  fi
else
  echo "==> swiftlint not found, skipping lint step"
fi

echo "==> Preparing temporary app bundle"
rm -rf "$TMP_APP"
if [[ -d "$DEST_APP" ]]; then
  cp -R "$DEST_APP" "$TMP_APP"
else
  mkdir -p "$TMP_APP/Contents/MacOS"
fi
cp "$ROOT_DIR/ExperienceSampling/Info.plist" "$TMP_APP/Contents/Info.plist"
plutil -insert ExperienceSamplingGitCommit -string "$GIT_REVISION" "$TMP_APP/Contents/Info.plist"
plutil -insert ExperienceSamplingGitDirty -bool "$GIT_DIRTY" "$TMP_APP/Contents/Info.plist"

echo "==> Rebuilding binary into temporary bundle"
mkdir -p "$(dirname "$TMP_BIN")"
swiftc -O -parse-as-library -framework AppKit -framework SwiftUI -framework CoreMediaIO -framework CoreAudio "${SOURCES[@]}" -o "$TMP_BIN"

echo "==> Codesigning temporary app bundle"
# No --force: the bundle's inner binary was just rebuilt by swiftc above, so it
# carries only a *linker-signed* ad-hoc signature, which codesign replaces without
# --force (the copied bundle's stale real signature is on the now-overwritten
# binary). --force is only needed to clobber a real signature, which never occurs
# here. Omitting it avoids Santa --force alerts.
codesign --sign "$CODESIGN_CERT" "$TMP_APP"

echo "==> Stopping the previous app"
pkill -x ExperienceSampling || true
for _ in {1..50}; do
  if ! pgrep -x ExperienceSampling >/dev/null; then break; fi
  sleep 0.1
done
if pgrep -x ExperienceSampling >/dev/null; then
  echo "Previous app did not exit; refusing to replace its bundle."
  exit 1
fi

echo "==> Installing app bundle"
rm -rf "$DEST_APP"
cp -R "$TMP_APP" /Applications/
cmp "$TMP_BIN" "$DEST_APP/Contents/MacOS/ExperienceSampling"
codesign --verify --deep --strict "$DEST_APP"

echo "==> Restarting app"
open "$DEST_APP"
sleep 1

echo "==> Verifying process"
pgrep -lx ExperienceSampling

echo "Done — installed $GIT_REVISION (modified: $GIT_DIRTY)."
