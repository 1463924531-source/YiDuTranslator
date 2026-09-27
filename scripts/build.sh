#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${YIDU_BUILD_ROOT:-$project_root/../../work/swift-build}"
bundle_path="${YIDU_BUNDLE_PATH:-$project_root/../译读.app}"
/usr/bin/swift build --package-path "$project_root" --scratch-path "$build_root" -c release
binary_dir="$(/usr/bin/swift build --package-path "$project_root" --scratch-path "$build_root" -c release --show-bin-path)"
/bin/mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
/bin/cp "$binary_dir/YiDuTranslator" "$bundle_path/Contents/MacOS/YiDuTranslator"
/bin/cp "$project_root/Resources/Info.plist" "$bundle_path/Contents/Info.plist"
if [ -f "$project_root/Resources/AppIcon.icns" ]; then
  /bin/cp "$project_root/Resources/AppIcon.icns" "$bundle_path/Contents/Resources/AppIcon.icns"
fi
/usr/bin/xattr -r -d com.apple.FinderInfo "$bundle_path" 2>/dev/null || true
/usr/bin/xattr -r -d com.apple.ResourceFork "$bundle_path" 2>/dev/null || true
/usr/bin/codesign --force --sign - --identifier local.codex.YiDuTranslator "$bundle_path"
/usr/bin/codesign --verify --strict "$bundle_path"
printf '%s\n' "$bundle_path"
