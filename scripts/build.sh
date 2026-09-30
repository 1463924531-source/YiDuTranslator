#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${YIDU_BUILD_ROOT:-$project_root/../../work/swift-build}"
bundle_path="${YIDU_BUNDLE_PATH:-$project_root/../译读.app}"
/usr/bin/swift build --package-path "$project_root" --scratch-path "$build_root" -c release
binary_dir="$(/usr/bin/swift build --package-path "$project_root" --scratch-path "$build_root" -c release --show-bin-path)"
stage_root="$(/usr/bin/mktemp -d /private/tmp/yidu-build.XXXXXX)"
trap '/bin/rm -rf "$stage_root"' EXIT
stage_bundle="$stage_root/译读.app"
/bin/mkdir -p "$stage_bundle/Contents/MacOS" "$stage_bundle/Contents/Resources"
/bin/cp -X "$binary_dir/YiDuTranslator" "$stage_bundle/Contents/MacOS/YiDuTranslator"
/bin/cp -X "$project_root/Resources/Info.plist" "$stage_bundle/Contents/Info.plist"
if [ -f "$project_root/Resources/AppIcon.icns" ]; then
  /bin/cp -X "$project_root/Resources/AppIcon.icns" "$stage_bundle/Contents/Resources/AppIcon.icns"
fi
/usr/bin/codesign --force --sign - --identifier local.codex.YiDuTranslator "$stage_bundle"
/usr/bin/codesign --verify --strict "$stage_bundle"
/usr/bin/ditto --norsrc --noextattr "$stage_bundle" "$bundle_path"
/usr/bin/xattr -r -d com.apple.FinderInfo "$bundle_path" 2>/dev/null || true
/usr/bin/xattr -r -d com.apple.ResourceFork "$bundle_path" 2>/dev/null || true
/usr/bin/codesign --verify --strict "$bundle_path"
printf '%s\n' "$bundle_path"
