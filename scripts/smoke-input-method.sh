#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_input_method_path="${INSTALL_INPUT_METHOD_PATH:-$HOME/Library/Input Methods/EposInputMethod.app}"
input_method_bundle_id="com.steez.inputmethod.Epos"
diagnostic_input_source_id="com.steez.inputmethod.Epos.Diagnostic"
fallback_input_source_id="${EPOS_INPUT_METHOD_SMOKE_FALLBACK_SOURCE_ID:-com.apple.keylayout.ABC}"
watchdog_seconds="${EPOS_INPUT_METHOD_SMOKE_WATCHDOG_SECONDS:-45}"

letters_expected="abc"
diagnostic_expected="Epos input method diagnostic"
previous_input_source_id=""
watchdog_pid=""
smoke_file=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

swift_current_input_source_id() {
  /usr/bin/xcrun swift -e '
import Carbon
import Foundation

guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
      let rawInputSourceID = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID) else {
    exit(1)
}

let inputSourceID = Unmanaged<CFString>.fromOpaque(rawInputSourceID).takeUnretainedValue() as String
print(inputSourceID)
'
}

select_input_source() {
  local input_source_id="$1"

  /usr/bin/xcrun swift -e '
import Carbon
import Foundation

let expectedInputSourceID = CommandLine.arguments[1]
let filter = [kTISPropertyInputSourceID as String: expectedInputSourceID] as CFDictionary

guard let inputSources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
      let mode = inputSources.first else {
    FileHandle.standardError.write(Data("error: input source not found: \(expectedInputSourceID)\n".utf8))
    exit(1)
}

let enableStatus = TISEnableInputSource(mode)
guard enableStatus == noErr else {
    FileHandle.standardError.write(Data("error: TISEnableInputSource failed with status \(enableStatus)\n".utf8))
    exit(1)
}

for _ in 0..<20 {
    if TISSelectInputSource(mode) == noErr {
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
}

FileHandle.standardError.write(Data("error: TISSelectInputSource failed for \(expectedInputSourceID)\n".utf8))
exit(1)
' "$input_source_id"
}

register_input_method() {
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f \
    -R \
    -trusted \
    "$install_input_method_path"

  /usr/bin/xcrun swift -e '
import Carbon
import Foundation

let inputSourceBundleURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let bundleIdentifier = CommandLine.arguments[2]
let diagnosticInputSourceID = CommandLine.arguments[3]
let status = TISRegisterInputSource(inputSourceBundleURL as CFURL)

guard status == noErr else {
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

func source(matching expectedID: String) -> TISInputSource? {
    inputSources().first { inputSourceID($0) == expectedID }
}

guard inputSources().contains(where: { inputSourceID($0) == bundleIdentifier }) else {
    FileHandle.standardError.write(Data("error: parent input source not found for \(bundleIdentifier)\n".utf8))
    exit(1)
}

guard let diagnosticMode = source(matching: diagnosticInputSourceID) else {
    FileHandle.standardError.write(Data("error: diagnostic input mode not found: \(diagnosticInputSourceID)\n".utf8))
    exit(1)
}

for inputSource in inputSources() {
    let enableStatus = TISEnableInputSource(inputSource)
    guard enableStatus == noErr else {
        FileHandle.standardError.write(Data("error: TISEnableInputSource failed with status \(enableStatus)\n".utf8))
        exit(1)
    }
}

for _ in 0..<20 {
    if let mode = source(matching: diagnosticInputSourceID),
       boolProperty(mode, kTISPropertyInputSourceIsEnabled) {
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
}

let enabled = boolProperty(diagnosticMode, kTISPropertyInputSourceIsEnabled)
FileHandle.standardError.write(Data("error: diagnostic input mode did not become enabled; enabled=\(enabled)\n".utf8))
exit(1)
' "$install_input_method_path" "$input_method_bundle_id" "$diagnostic_input_source_id"
}

pasteboard_change_count() {
  /usr/bin/xcrun swift -e '
import AppKit
print(NSPasteboard.general.changeCount)
'
}

open_smoke_document() {
  local raw_smoke_file

  raw_smoke_file="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/epos-input-method-smoke.XXXXXX.txt")"
  smoke_file="$(cd "$(dirname "$raw_smoke_file")" && pwd -P)/$(basename "$raw_smoke_file")"
  /usr/bin/open -a TextEdit "$smoke_file"

  /usr/bin/osascript <<'APPLESCRIPT'
tell application "TextEdit"
  activate
end tell

tell application "System Events"
  repeat 50 times
    if exists process "TextEdit" then
      tell process "TextEdit"
        if frontmost then exit repeat
      end tell
    end if
    delay 0.1
  end repeat
end tell
APPLESCRIPT
}

close_smoke_document() {
  [[ -n "$smoke_file" ]] || return 0

  /usr/bin/osascript - "$smoke_file" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  set targetPath to item 1 of argv

  tell application "TextEdit"
    if it is running then
      repeat with doc in documents
        try
          if (path of doc as text) is targetPath then
            close doc saving no
            exit repeat
          end if
        end try
      end repeat
    end if
  end tell
end run
APPLESCRIPT

  rm -f "$smoke_file"
}

textedit_text_after_letters() {
  /usr/bin/osascript <<'APPLESCRIPT'
tell application "TextEdit"
  activate
  set text of front document to ""
end tell

delay 0.2

tell application "System Events"
  keystroke "abc"
end tell

delay 0.2

tell application "TextEdit"
  get text of front document
end tell
APPLESCRIPT
}

textedit_text_after_diagnostic_chord() {
  /usr/bin/osascript <<'APPLESCRIPT'
tell application "TextEdit"
  activate
  set text of front document to ""
end tell

delay 0.2

tell application "System Events"
  key code 2 using {control down, option down, shift down}
end tell

delay 0.4

tell application "TextEdit"
  get text of front document
end tell
APPLESCRIPT
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  if [[ -n "$watchdog_pid" ]]; then
    kill "$watchdog_pid" >/dev/null 2>&1 || true
    wait "$watchdog_pid" >/dev/null 2>&1 || true
  fi

  close_smoke_document

  if [[ -n "$previous_input_source_id" && "$previous_input_source_id" != "$diagnostic_input_source_id" ]]; then
    select_input_source "$previous_input_source_id" >/dev/null 2>&1 || \
      select_input_source "$fallback_input_source_id" >/dev/null 2>&1 || true
  else
    select_input_source "$fallback_input_source_id" >/dev/null 2>&1 || true
  fi

  /usr/bin/pkill -x EposInputMethod >/dev/null 2>&1 || true
  exit "$status"
}

trap cleanup EXIT INT TERM

case "$watchdog_seconds" in
  '' | *[!0-9]*) fail "EPOS_INPUT_METHOD_SMOKE_WATCHDOG_SECONDS must be a positive integer" ;;
esac

[[ -d "$install_input_method_path" ]] || "$script_dir/install-local-app.sh" >/dev/null
[[ -d "$install_input_method_path" ]] || fail "input method is not installed at $install_input_method_path"

previous_input_source_id="$(swift_current_input_source_id || true)"
register_input_method

(
  sleep "$watchdog_seconds"
  select_input_source "$fallback_input_source_id" >/dev/null 2>&1 || true
  /usr/bin/pkill -x EposInputMethod >/dev/null 2>&1 || true
) &
watchdog_pid="$!"

open -na "$install_input_method_path"

for _ in {1..50}; do
  if /usr/bin/pgrep -x EposInputMethod >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

/usr/bin/pgrep -x EposInputMethod >/dev/null 2>&1 || fail "EposInputMethod did not launch"

select_input_source "$diagnostic_input_source_id"
open_smoke_document

letters_text="$(textedit_text_after_letters)"
[[ "$letters_text" == "$letters_expected" ]] || \
  fail "letters did not pass through selected input method; got '$letters_text'"

pasteboard_before="$(pasteboard_change_count)"
diagnostic_text="$(textedit_text_after_diagnostic_chord)"
pasteboard_after="$(pasteboard_change_count)"

[[ "$diagnostic_text" == "$diagnostic_expected" ]] || \
  fail "diagnostic chord did not commit expected text; got '$diagnostic_text'"
[[ "$pasteboard_before" == "$pasteboard_after" ]] || \
  fail "pasteboard changed during diagnostic commit: $pasteboard_before -> $pasteboard_after"

printf 'letters_text=%s\n' "$letters_text"
printf 'diagnostic_text=%s\n' "$diagnostic_text"
printf 'pasteboard_before=%s\n' "$pasteboard_before"
printf 'pasteboard_after=%s\n' "$pasteboard_after"
