#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  cat >&2 <<'MSG'
error: DEVELOPMENT_TEAM is required.

Set it to your Apple Developer Team ID, then rerun this script:

  export DEVELOPMENT_TEAM=YOURTEAMID
  scripts/build-signed-app.sh

You can inspect available signing identities with:

  security find-identity -v -p codesigning
MSG
  exit 64
fi

code_sign_identity="${CODE_SIGN_IDENTITY:-Apple Development}"
configuration="${CONFIGURATION:-Debug}"
symroot="$repo_root/.build/xcode"
app_path="$symroot/$configuration/SteezFlowMacApp.app"

cd "$repo_root"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >&2
fi

xcodebuild \
  -project SteezFlow.xcodeproj \
  -scheme SteezFlowMacApp \
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
