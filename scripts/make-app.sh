#!/bin/bash
# Assemble Spartan.app from the swift build output and codesign it.
# Usage: scripts/make-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG/Spartan"
APP="$ROOT/dist/Spartan.app"
CERT_NAME="Spartan Dev"

if [[ ! -x "$BIN" ]]; then
  echo "error: $BIN not found — run 'swift build -c $CONFIG' first" >&2
  exit 1
fi

# Assemble + sign in a temp dir: Documents may be cloud-synced, and file-provider
# xattrs (com.apple.fileprovider, FinderInfo) make codesign reject the bundle.
STAGE="$(mktemp -d)/Spartan.app"
trap 'rm -rf "$(dirname "$STAGE")"' EXIT
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$ROOT/Support/Info.plist" "$STAGE/Contents/Info.plist"
cp "$BIN" "$STAGE/Contents/MacOS/Spartan"
xattr -cr "$STAGE" 2>/dev/null || true

# Sign with the stable self-signed cert if present (keeps the Screen Recording
# TCC grant across rebuilds); otherwise fall back to ad-hoc with a warning.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  codesign --force --sign "$CERT_NAME" --identifier com.mdumas.spartan "$STAGE"
  echo "signed with '$CERT_NAME'"
else
  codesign --force --sign - --identifier com.mdumas.spartan "$STAGE"
  echo "warning: '$CERT_NAME' cert not found — ad-hoc signed." >&2
  echo "         Screen Recording permission will RESET on every rebuild." >&2
  echo "         Run scripts/make-cert.sh once to fix this." >&2
fi

codesign --verify "$STAGE"
rm -rf "$APP"
mkdir -p "$(dirname "$APP")"
ditto "$STAGE" "$APP"
echo "built $APP"
