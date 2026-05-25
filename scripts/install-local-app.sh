#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_app_path="${INSTALL_APP_PATH:-/Applications/SteezFlowMacApp.app}"

if pgrep -f "$install_app_path/Contents/MacOS/SteezFlowMacApp" >/dev/null 2>&1; then
  cat >&2 <<MSG
error: $install_app_path is running.

Quit SteezFlowMacApp, then rerun:

  scripts/install-local-app.sh
MSG
  exit 66
fi

built_app_path="${BUILT_APP_PATH:-}"
if [[ -z "$built_app_path" ]]; then
  built_app_path="$("$script_dir/build-local-app.sh")"
fi

mkdir -p "$(dirname "$install_app_path")"
ditto "$built_app_path" "$install_app_path"

codesign --verify --deep --strict "$install_app_path"

printf '%s\n' "$install_app_path"
