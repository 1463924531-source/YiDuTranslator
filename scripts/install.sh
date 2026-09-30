#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_bundle="${YIDU_BUNDLE_PATH:-$project_root/../译读.app}"
destination="/Applications/译读.app"
if /usr/bin/pgrep -f '^/Applications/译读[.]app/Contents/MacOS/YiDuTranslator($| )' >/dev/null; then
  printf '%s\n' '请先完全退出译读（⌘Q），再安装更新。运行中覆盖应用可能导致权限与版本不一致。' >&2
  exit 1
fi
if [ ! -f "$source_bundle/Contents/MacOS/YiDuTranslator" ]; then
  /bin/bash "$project_root/scripts/build.sh"
fi
stage_root="$(/usr/bin/mktemp -d /private/tmp/yidu-install.XXXXXX)"
trap '/bin/rm -rf "$stage_root"' EXIT
stage_bundle="$stage_root/译读.app"
# Documents/FileProvider can reattach FinderInfo after a source bundle is signed.
# Copy without source metadata, then verify the exact bundle that will be installed.
/usr/bin/ditto --norsrc --noextattr "$source_bundle" "$stage_bundle"
/usr/bin/codesign --verify --strict "$stage_bundle"
identity_changed=false
if [ -e "$destination" ]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$existing_id" != 'local.codex.YiDuTranslator' ]; then
    printf '%s\n' '目标位置已有其他应用，未覆盖。请手动选择安装位置。' >&2
    exit 1
  fi
  existing_requirement="$(/usr/bin/codesign -d -r- "$destination" 2>&1 | /usr/bin/sed -n 's/^.*designated => //p')"
  incoming_requirement="$(/usr/bin/codesign -d -r- "$stage_bundle" 2>&1 | /usr/bin/sed -n 's/^.*designated => //p')"
  if [ "$existing_requirement" != "$incoming_requirement" ]; then identity_changed=true; fi
fi
/usr/bin/ditto --norsrc --noextattr "$stage_bundle" "$destination"
/usr/bin/xattr -r -d com.apple.FinderInfo "$destination" 2>/dev/null || true
/usr/bin/xattr -r -d com.apple.ResourceFork "$destination" 2>/dev/null || true
/usr/bin/codesign --verify --strict "$destination"
printf '%s\n' "$destination"
if [ "$identity_changed" = true ]; then
  printf '%s\n' '当前构建的签名已变化。如辅助功能开关已开但仍提示未允许，请在系统设置移除译读的旧条目，再重新添加 /Applications/译读.app 并开启权限。'
fi
