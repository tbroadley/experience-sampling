#!/usr/bin/env bash
# Build and run the headless logic tests.
#
# Compiles ExperienceSampling.swift together with ExperienceSamplingTests/main.swift
# under -DTESTING (which strips the app's NSApplication entry point), then runs the
# resulting binary with HOME pointed at a throwaway temp dir so the data stores
# (which resolve under ~/Library/Application Support) never touch real data.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT_DIR/ExperienceSampling/ExperienceSampling.swift"
TST="$ROOT_DIR/ExperienceSamplingTests/main.swift"
ENV_FILE="$ROOT_DIR/.env"
BUILD_DIR="$(mktemp -d)"
BIN="$BUILD_DIR/estests"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Santa (binary authorization) SIGKILLs unsigned binaries on managed Macs, so
# locally the test binary must be codesigned with the same cert the app build
# uses. CI runners (e.g. GitHub-hosted macOS) have no Santa and no cert, so
# codesigning is skipped there: .env and CODESIGN_CERT are both optional.
if [[ -f "$ENV_FILE" ]]; then set -a; source "$ENV_FILE"; set +a; fi

echo "==> Building tests"
swiftc -DTESTING \
  -framework AppKit -framework SwiftUI -framework CoreMediaIO -framework CoreAudio \
  "$SRC" "$TST" -o "$BIN"

if [[ -n "${CODESIGN_CERT:-}" ]]; then
  echo "==> Codesigning test binary"
  # No --force: swiftc/ld emit a *linker-signed* ad-hoc signature, which codesign
  # replaces without --force. --force is only needed to clobber a *real* signature,
  # which never happens here since $BIN is always freshly compiled above. Omitting
  # it also avoids Santa --force alerts and surfaces (rather than silently
  # overwriting) any unexpected pre-existing signature.
  codesign --sign "$CODESIGN_CERT" "$BIN"
else
  echo "==> CODESIGN_CERT not set, skipping codesign (expected on CI)"
fi

echo "==> Running tests (isolated home dir)"
# macOS NSHomeDirectory() ignores $HOME (it reads the directory service), so
# redirect via CFFIXED_USER_HOME, which CoreFoundation honors. This keeps the
# data stores' ~/Library/Application Support writes inside the throwaway dir.
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR" "$TEST_HOME"' EXIT
set +e
CFFIXED_USER_HOME="$TEST_HOME" HOME="$TEST_HOME" "$BIN"
code=$?
set -e
exit $code
