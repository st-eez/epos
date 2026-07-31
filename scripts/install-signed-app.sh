#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_app_path="${INSTALL_APP_PATH:-/Applications/Epos.app}"

if pgrep -f "$install_app_path/Contents/MacOS/Epos" >/dev/null 2>&1; then
  cat >&2 <<MSG
error: $install_app_path is running.

Quit Epos, then rerun:

  DEVELOPMENT_TEAM=YOURTEAMID scripts/install-signed-app.sh
MSG
  exit 66
fi

built_app_path="$("$script_dir/build-signed-app.sh")"

mkdir -p "$(dirname "$install_app_path")"
ditto "$built_app_path" "$install_app_path"

codesign --verify --deep --strict "$install_app_path"

# The inline preview streams into the field through the companion palette input
# method; keep it in lockstep with the app. A registration that needs a logout
# (first install on a machine) must not fail the app install — Epos degrades to
# the pill HUD until the input method is live.
if ! "$script_dir/../probes/inline-preview/install"; then
  echo "warning: inline-preview input method not live yet; Epos falls back to the pill HUD" >&2
fi

printf '%s\n' "$install_app_path"
