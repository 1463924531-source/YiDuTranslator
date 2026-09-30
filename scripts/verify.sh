#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
check_root="${YIDU_CHECK_ROOT:-$project_root/../../work/verification}"
/bin/mkdir -p "$check_root"
for check_name in api-check doc-check mac-integration-check wps-copy-check favorites-check; do
  /usr/bin/swiftc -parse-as-library -target arm64-apple-macosx13.0 \
    "$project_root"/Sources/TranslatorCore/*.swift \
    "$project_root/Tests/Standalone/$check_name.swift" -o "$check_root/$check_name"
  "$check_root/$check_name"
done
