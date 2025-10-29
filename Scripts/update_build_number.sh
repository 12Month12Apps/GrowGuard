#!/usr/bin/env bash

set -euo pipefail

# Only run when archiving (or installing from Xcode Organizer)
case "${ACTION:-}" in
  archive|install)
    ;;
  *)
    echo "Skipping build number update for action: ${ACTION:-unknown}"
    exit 0
    ;;
esac

BUILD_NUMBER=$(date +"%d.%m.%Y")
echo "🏗️  Setting build number to ${BUILD_NUMBER}"

update_plist() {
  local plist_path="$1"

  [[ -f "${plist_path}" ]] || return 0

  if /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${plist_path}" 2>/dev/null; then
    return 0
  fi

  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${BUILD_NUMBER}" "${plist_path}"
}

# Update the compiled Info.plist inside the app bundle
if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${INFOPLIST_PATH:-}" ]]; then
  update_plist "${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
fi

# Also update the dSYM bundle if it exists (so symbols carry matching version)
if [[ -n "${DWARF_DSYM_FOLDER_PATH:-}" && -n "${DWARF_DSYM_FILE_NAME:-}" ]]; then
  update_plist "${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Info.plist"
fi

echo "✅ Build number updated"
