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
    team="$(sed -n 's/.*OU[[:space:]]*=[[:space:]]*\([^,\/]*\).*/\1/p' <<<"$subject" | head -n 1)"
    [[ -n "$team" ]] && printf '%s\n' "$team"
  done | sort -u
}

load_discovered_teams() {
  discovered_teams=()
  local team
  while IFS= read -r team; do
    discovered_teams+=("$team")
  done < <(discover_development_teams)
}

code_sign_identity="${CODE_SIGN_IDENTITY:-Apple Development}"

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  load_discovered_teams
  if [[ "${#discovered_teams[@]}" -eq 1 ]]; then
    DEVELOPMENT_TEAM="${discovered_teams[0]}"
    export DEVELOPMENT_TEAM
    printf 'info: using DEVELOPMENT_TEAM=%s from installed Apple Development certificate\n' "$DEVELOPMENT_TEAM" >&2
  else
    cat >&2 <<'MSG'
error: DEVELOPMENT_TEAM is required and could not be inferred uniquely.

Set it to the TeamIdentifier/OU from your Apple Development certificate, then
rerun this script:

  export DEVELOPMENT_TEAM=YOURTEAMID
  scripts/build-signed-app.sh

You can inspect available certificate subjects with:

  security find-certificate -a -p -c "Apple Development" | openssl x509 -noout -subject
MSG
    exit 64
  fi
else
  load_discovered_teams
  if [[ "${#discovered_teams[@]}" -gt 0 ]]; then
    team_matches=false
    for team in "${discovered_teams[@]}"; do
      if [[ "$team" == "$DEVELOPMENT_TEAM" ]]; then
        team_matches=true
        break
      fi
    done
    if [[ "$team_matches" == false ]]; then
      cat >&2 <<MSG
error: DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM does not match any installed Apple Development certificate TeamIdentifier/OU.

Installed Apple Development certificate TeamIdentifier/OU values:
$(printf '  %s\n' "${discovered_teams[@]}")

Use one of those values for DEVELOPMENT_TEAM. Do not copy the parenthesized
suffix from the keychain display name unless it matches the certificate OU.
MSG
      exit 64
    fi
  fi
fi

configuration="${CONFIGURATION:-Debug}"
symroot="$repo_root/.build/xcode"
app_path="$symroot/$configuration/Epos.app"

cd "$repo_root"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >&2
fi

xcodebuild \
  -project Epos.xcodeproj \
  -scheme EposMacApp \
  -configuration "$configuration" \
  -destination 'platform=macOS' \
  SYMROOT="$symroot" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_IDENTITY="$code_sign_identity" \
  build >&2

signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
designated_requirement="$(codesign -dr - "$app_path" 2>&1)"

if grep -q 'Signature=adhoc' <<<"$signature_details"; then
  echo "error: build produced an ad-hoc signature" >&2
  exit 65
fi

if grep -q 'TeamIdentifier=not set' <<<"$signature_details"; then
  echo "error: build has no TeamIdentifier" >&2
  exit 65
fi

if grep -q '# designated => cdhash' <<<"$designated_requirement"; then
  echo "error: build produced a cdhash-only designated requirement" >&2
  exit 65
fi

printf '%s\n' "$app_path"
