#!/bin/zsh
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yidu-store-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
# Compile live production state logic; replace only external boundaries with the
# deterministic stubs in store-check.swift. This does not access real keys or TCC.
sed '/^import TranslatorCore$/d' "$PROJECT_ROOT/Sources/TranslatorApp/AppSettings.swift" > "$CHECK_DIR/AppSettings.swift"
sed -e '/^import TranslatorCore$/d' -e 's/private func recognizeImage(/func recognizeImage(/' "$PROJECT_ROOT/Sources/TranslatorApp/AppStore.swift" > "$CHECK_DIR/AppStore.swift"
swiftc -parse-as-library \
  "$PROJECT_ROOT/Sources/TranslatorCore/Models.swift" \
  "$PROJECT_ROOT/Sources/TranslatorCore/FavoritesStore.swift" \
  "$CHECK_DIR/AppSettings.swift" "$CHECK_DIR/AppStore.swift" \
  "$SCRIPT_DIR/store-check.swift" -o "$CHECK_DIR/store-check"
# All transient favorite test files stay inside this disposable directory.
cd "$CHECK_DIR"
./store-check
