#!/usr/bin/env zsh
set -euo pipefail

log_dir="${EPOS_LOG_DIR:-$HOME/Library/Caches/Epos/logs}"
day="${EPOS_LOG_DAY:-$(date +%Y-%m-%d)}"
line_count="${EPOS_TAIL_LINES:-200}"
pattern="${EPOS_TAIL_PATTERN:-recording start|recording finalize|recording done|transcript timing|insertion guard|append-only|polish|recording to|discarded recording|capture started|capture stopped|session starting|session finished}"

setopt local_options null_glob
files=("${log_dir}/${day}"*.log)

if (( ${#files[@]} == 0 )); then
  print -u2 "No Epos logs found for ${day} in ${log_dir}"
  exit 1
fi

tail -n "${line_count}" -f -- "${files[@]}" | grep -E --line-buffered "${pattern}"
