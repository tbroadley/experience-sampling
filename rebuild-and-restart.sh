#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_FILE="$ROOT_DIR/ExperienceSampling/ExperienceSampling.swift"
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

echo "==> Typechecking"
swiftc -typecheck "$SRC_FILE"

if command -v swiftlint >/dev/null 2>&1; then
  echo "==> Linting with swiftlint"
  swiftlint lint --path "$SRC_FILE"
else
  echo "==> swiftlint not found, skipping lint step"
fi

echo "==> Preparing temporary app bundle"
rm -rf "$TMP_APP"
if [[ -d "$DEST_APP" ]]; then
  cp -R "$DEST_APP" "$TMP_APP"
else
  mkdir -p "$TMP_APP/Contents/MacOS"
  cp "$ROOT_DIR/ExperienceSampling/Info.plist" "$TMP_APP/Contents/Info.plist"
fi

echo "==> Rebuilding binary into temporary bundle"
mkdir -p "$(dirname "$TMP_BIN")"
swiftc -O -framework AppKit -framework SwiftUI "$SRC_FILE" -o "$TMP_BIN"

echo "==> Codesigning temporary app bundle"
codesign --force --sign "$CODESIGN_CERT" "$TMP_APP"

echo "==> Installing app bundle"
rm -rf "$DEST_APP"
cp -R "$TMP_APP" /Applications/

echo "==> Restarting app"
pkill -x ExperienceSampling || true
sleep 0.5
open "$DEST_APP"

echo "==> Verifying process"
ps aux | grep -i "ExperienceSampling" | grep -v grep || true

echo "Done."
