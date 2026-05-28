#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_app_path="${INSTALL_APP_PATH:-/Applications/Epos.app}"
install_input_method_path="${INSTALL_INPUT_METHOD_PATH:-$HOME/Library/Input Methods/EposInputMethod.app}"
enable_input_method="${EPOS_ENABLE_INPUT_METHOD:-0}"

case "$enable_input_method" in
  0 | 1) ;;
  *)
    cat >&2 <<'MSG'
error: EPOS_ENABLE_INPUT_METHOD must be 0 or 1.

The local install registers the input method by default. Set
EPOS_ENABLE_INPUT_METHOD=1 only for a guarded manual input-method smoke.
MSG
    exit 64
    ;;
esac

if pgrep -f "$install_app_path/Contents/MacOS/Epos" >/dev/null 2>&1; then
  cat >&2 <<MSG
error: $install_app_path is running.

Quit Epos, then rerun:

  scripts/install-local-app.sh
MSG
  exit 66
fi

if pgrep -x EposInputMethod >/dev/null 2>&1; then
  cat >&2 <<MSG
error: EposInputMethod is running.

Switch away from the Epos input method, then rerun:

  scripts/install-local-app.sh
MSG
  exit 66
fi

built_app_path="${BUILT_APP_PATH:-}"
if [[ -z "$built_app_path" ]]; then
  built_app_path="$("$script_dir/build-local-app.sh")"
fi
built_input_method_path="${BUILT_INPUT_METHOD_PATH:-$(dirname "$built_app_path")/EposInputMethod.app}"

replace_bundle() {
  local source_path="$1"
  local destination_path="$2"
  local parent_dir
  local bundle_name
  local temporary_path

  parent_dir="$(dirname "$destination_path")"
  bundle_name="$(basename "$destination_path")"
  temporary_path="$parent_dir/.$bundle_name.installing.$$"

  mkdir -p "$parent_dir"
  rm -rf "$temporary_path"
  ditto "$source_path" "$temporary_path"
  codesign --verify --deep --strict "$temporary_path"

  rm -rf "$destination_path"
  mv "$temporary_path" "$destination_path"
  codesign --verify --deep --strict "$destination_path"
}

register_input_source() {
  local input_source_path="$1"

  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f \
    -R \
    -trusted \
    "$input_source_path"

  /usr/bin/xcrun swift -e '
import Carbon
import Foundation

let inputSourceBundleURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let shouldEnableInputMethod = CommandLine.arguments[2] == "1"
let status = TISRegisterInputSource(inputSourceBundleURL as CFURL)
guard status == noErr,
      let bundleIdentifier = Bundle(url: inputSourceBundleURL)?.bundleIdentifier else {
    FileHandle.standardError.write(Data("error: TISRegisterInputSource failed with status \(status)\n".utf8))
    exit(1)
}

let filter = [kTISPropertyBundleID as String: bundleIdentifier] as CFDictionary
func inputSources() -> [TISInputSource] {
    TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] ?? []
}

func inputSourceID(_ inputSource: TISInputSource) -> String? {
    guard let rawValue = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID) else {
        return nil
    }
    return Unmanaged<CFString>.fromOpaque(rawValue).takeUnretainedValue() as String
}

func boolProperty(_ inputSource: TISInputSource, _ key: CFString) -> Bool {
    guard let rawValue = TISGetInputSourceProperty(inputSource, key) else {
        return false
    }
    return (Unmanaged<CFTypeRef>.fromOpaque(rawValue).takeUnretainedValue() as? NSNumber)?.boolValue ?? false
}

func inputSource(matching expectedID: String) -> TISInputSource? {
    inputSources().first { inputSourceID($0) == expectedID }
}

func enable(_ inputSource: TISInputSource) {
    let enableStatus = TISEnableInputSource(inputSource)
    guard enableStatus == noErr else {
        FileHandle.standardError.write(Data("error: TISEnableInputSource failed with status \(enableStatus)\n".utf8))
        exit(1)
    }
}

func waitUntilEnabled(_ inputSourceID: String) {
    for _ in 0..<10 {
        if let inputSource = inputSource(matching: inputSourceID),
           boolProperty(inputSource, kTISPropertyInputSourceIsEnabled) {
            return
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    FileHandle.standardError.write(Data("error: input source did not become enabled: \(inputSourceID)\n".utf8))
    exit(1)
}

guard !inputSources().isEmpty else {
    FileHandle.standardError.write(Data("error: no registered input sources found for \(bundleIdentifier)\n".utf8))
    exit(1)
}

guard let parentInputSource = inputSources().first(where: { inputSourceID($0) == bundleIdentifier }) else {
    FileHandle.standardError.write(Data("error: parent input source not found for \(bundleIdentifier)\n".utf8))
    exit(1)
}

guard shouldEnableInputMethod else {
    exit(0)
}

enable(parentInputSource)

for inputSource in inputSources() where inputSourceID(inputSource) != bundleIdentifier {
    guard let inputSourceID = inputSourceID(inputSource) else {
        continue
    }
    enable(inputSource)
    waitUntilEnabled(inputSourceID)
}
' "$input_source_path" "$enable_input_method"
}

replace_bundle "$built_app_path" "$install_app_path"
replace_bundle "$built_input_method_path" "$install_input_method_path"
register_input_source "$install_input_method_path"

printf '%s\n' "$install_app_path"
