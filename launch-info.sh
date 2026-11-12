#!/usr/bin/env bash
# App Binder helper: for each process ID given, print which launcher entry
# started it and when, so App Binder can learn which window belongs to an app
# it launched:
#   <pid>  <desktop id>  <start time, seconds since the epoch>
#
# The standard launcher library records the launcher entry in the launched
# app's environment (GIO_LAUNCHED_DESKTOP_FILE), and every process the app
# starts inherits it. Processes without that record are skipped.
#
# This runs outside Hyprland: reading another process's /proc files can wait
# while that process is stuck, and that must never stall the compositor. Only
# bash builtins read files here, so when App Binder stops this script (it has
# a deadline) nothing is left behind. Every read is bounded.

set -u

MAX_PIDS=64
MAX_VARS=4096       # environment variables read per process
MAX_CHARS=4096      # characters read per variable or line

btime=""
while IFS= read -r -n "$MAX_CHARS" line; do
  if [[ $line == "btime "* ]]; then btime=${line#btime }; break; fi
done < /proc/stat
[[ $btime =~ ^[0-9]+$ ]] || exit 0

n=0
for pid in "$@"; do
  [[ $pid =~ ^[0-9]{1,9}$ ]] || continue
  (( ++n > MAX_PIDS )) && break

  record=""
  count=0
  while IFS= read -r -d '' -n "$MAX_CHARS" var; do
    (( ++count > MAX_VARS )) && break
    if [[ $var == GIO_LAUNCHED_DESKTOP_FILE=* ]]; then record=${var#GIO_LAUNCHED_DESKTOP_FILE=}; break; fi
  done 2>/dev/null < "/proc/$pid/environ"
  [[ $record == *.desktop ]] || continue
  id=${record##*/}
  id=${id%.desktop}
  [[ -n $id && $id != *[[:cntrl:]]* ]] || continue

  IFS= read -r -n "$MAX_CHARS" stat 2>/dev/null < "/proc/$pid/stat" || continue
  # Fields after the last ") ": the process name before it can contain ") ".
  # Start time is field 22 overall, the 20th here, in clock ticks (100 per
  # second) since boot.
  read -r -a fields <<< "${stat##*) }"
  ticks=${fields[19]:-}
  [[ $ticks =~ ^[0-9]+$ ]] || continue

  printf '%s\t%s\t%s\n' "$pid" "$id" "$(( btime + ticks / 100 ))"
done
