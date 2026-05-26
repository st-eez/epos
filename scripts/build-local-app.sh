#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

discover_development_teams() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  security find-certificate -a -p -c "Apple Development" 2>/dev/null |
    awk -v dir="$tmpdir" '
      /-----BEGIN CERTIFICATE-----/ { n += 1 }
      n > 0 { print > (dir "/cert-" n ".pem") }
    '

  local cert subject team
  for cert in "$tmpdir"/cert-*.pem; do
    [[ -e "$cert" ]] || continue
    subject="$(openssl x509 -in "$cert" -noout -subject 2>/dev/null || true)"
    team="$(sed -n 's/.*OU=\([^,]*\).*/\1/p' <<<"$subject" | head -n 1)"
    [[ -n "$team" ]] && printf '%s\n' "$team"
  done | sort -u
}

require_command() {
  local command_name="$1"
  local install_hint="$2"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    cat >&2 <<MSG
error: missing required command: $command_name

$install_hint
MSG
    exit 69
  fi
}

configuration="${CONFIGURATION:-Release}"
symroot="$repo_root/.build/xcode"
app_path="$symroot/$configuration/Epos.app"
signing_mode="${EPOS_LOCAL_SIGNING:-auto}"

cd "$repo_root"

require_command xcodegen "Install it with: brew install xcodegen"
require_command xcodebuild "Install Xcode 17 or later, then run: sudo xcode-select -s /Applications/Xcode.app"

xcodegen generate >&2

case "$signing_mode" in
  auto | development | adhoc) ;;
  *)
    cat >&2 <<'MSG'
error: EPOS_LOCAL_SIGNING must be one of: auto, development, adhoc
MSG
    exit 64
    ;;
esac

discovered_teams=()
while IFS= read -r team; do
  discovered_teams+=("$team")
done < <(discover_development_teams)

if [[ "$signing_mode" != "adhoc" ]]; then
  if [[ -z "${DEVELOPMENT_TEAM:-}" && "${#discovered_teams[@]}" -eq 1 ]]; then
    DEVELOPMENT_TEAM="${discovered_teams[0]}"
    export DEVELOPMENT_TEAM
    printf 'info: using DEVELOPMENT_TEAM=%s from installed Apple Development certificate\n' "$DEVELOPMENT_TEAM" >&2
  fi

  if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    code_sign_identity="${CODE_SIGN_IDENTITY:-Apple Development}"
    xcodebuild \
      -project Epos.xcodeproj \
      -scheme EposMacApp \
      -configuration "$configuration" \
      -destination 'platform=macOS' \
      SYMROOT="$symroot" \
      DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
      CODE_SIGN_IDENTITY="$code_sign_identity" \
      build >&2
  elif [[ "$signing_mode" == "development" ]]; then
    cat >&2 <<'MSG'
error: DEVELOPMENT_TEAM is required for EPOS_LOCAL_SIGNING=development.

Set DEVELOPMENT_TEAM to the TeamIdentifier/OU from your Apple Development
certificate, or use EPOS_LOCAL_SIGNING=adhoc for a local ad-hoc build.
MSG
    exit 64
  else
    signing_mode="adhoc"
  fi
fi

if [[ "$signing_mode" == "adhoc" ]]; then
  cat >&2 <<'MSG'
warning: building with an ad-hoc local signature.

This is free and works for source-built local installs, but macOS permission
grants may be less stable across rebuilds than with an Apple Development
certificate. For a better free local install, add an Apple ID in Xcode and
create an Apple Development certificate, then rerun this script.
MSG

  xcodebuild \
    -project Epos.xcodeproj \
    -scheme EposMacApp \
    -configuration "$configuration" \
    -destination 'platform=macOS' \
    SYMROOT="$symroot" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    CODE_SIGN_IDENTITY="-" \
    build >&2
fi

codesign --verify --deep --strict "$app_path"

printf '%s\n' "$app_path"
