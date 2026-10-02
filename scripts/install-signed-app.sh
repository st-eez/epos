#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_app_path="${INSTALL_APP_PATH:-/Applications/Epos.app}"
install_app_path="${install_app_path%/}"

if [[ "$install_app_path" != /* || "$(basename "$install_app_path")" != "Epos.app" ]]; then
  cat >&2 <<MSG
error: INSTALL_APP_PATH must be an absolute path ending in Epos.app.
refusing to remove/install at: $install_app_path
MSG
  exit 64
fi

# Pin the physical parent so replacement and rollback use stable paths.
install_app_parent="$(dirname "$install_app_path")"
mkdir -p "$install_app_parent"
install_app_parent="$(cd "$install_app_parent" && pwd -P)"
install_app_path="$install_app_parent/Epos.app"

if pgrep -f "$install_app_path/Contents/MacOS/Epos" >/dev/null 2>&1; then
  cat >&2 <<MSG
error: $install_app_path is running.

Quit Epos, then rerun:

  DEVELOPMENT_TEAM=YOURTEAMID scripts/install-signed-app.sh
MSG
  exit 66
fi

built_app_path="$("$script_dir/build-signed-app.sh")"

staging_dir="$(mktemp -d "$install_app_parent/.Epos.app.install.XXXXXX")"
staged_app_path="$staging_dir/new.app"
previous_app_path="$staging_dir/previous.app"
installation_verified=false

cleanup_installation() {
  local status="$?"
  if [[ "$installation_verified" == false && ( -e "$previous_app_path" || -L "$previous_app_path" ) ]]; then
    if [[ -e "$install_app_path" || -L "$install_app_path" ]] &&
      ! mv "$install_app_path" "$staging_dir/failed.app"; then
      echo "error: could not restore the previous bundle; it remains at $previous_app_path" >&2
      return "$status"
    fi
    if ! mv "$previous_app_path" "$install_app_path"; then
      echo "error: could not restore the previous bundle; it remains at $previous_app_path" >&2
      return "$status"
    fi
  fi
  rm -rf "$staging_dir"
  return "$status"
}
trap cleanup_installation EXIT

# A fresh destination excludes artifacts from the previous build configuration.
ditto "$built_app_path" "$staged_app_path"
codesign --verify --deep --strict "$staged_app_path"

if [[ -e "$install_app_path" || -L "$install_app_path" ]]; then
  mv "$install_app_path" "$previous_app_path"
fi
mv "$staged_app_path" "$install_app_path"

codesign --verify --deep --strict "$install_app_path"
installation_verified=true

# The inline preview streams into the field through the companion palette input
# method; keep it in lockstep with the app. A registration that needs a logout
# (first install on a machine) must not fail the app install — Epos degrades to
# the pill HUD until the input method is live.
if ! "$script_dir/../probes/inline-preview/install"; then
  echo "warning: inline-preview input method not live yet; Epos falls back to the pill HUD" >&2
fi

printf '%s\n' "$install_app_path"
