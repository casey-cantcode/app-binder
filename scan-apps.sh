#!/usr/bin/env bash
# App Binder helper: classify every desktop entry so look-alike apps (e.g. a
# Discord web app next to native Discord) can be told apart.
#
# Prints one line per entry, tab-separated:
#   <desktop id>  <desktop file>  <kind>  <location>  <icon file>
# kind: native | flatpak | webapp | appimage | terminal | steam | heroic |
#       broken (its program doesn't exist) | nocommand (no Exec= line)
# location: the executable's real path (native/appimage), the Flatpak install
# folder (flatpak), the game link (steam/heroic), the missing program
# (broken), or the desktop file (webapp/terminal/nocommand).
# icon file: the entry's Icon= path if it is an absolute path to a regular,
# readable file under 4 MB, else empty. App Binder only loads absolute icon
# paths this script vouched for: a named pipe as an icon would stall the
# shell's image loading.
#
# The last line is "END". App Binder ignores a scan without it (one that was
# stopped partway).
#
# Directories are scanned in XDG precedence order; the first file for an id
# wins, matching what the launcher shows.
#
# Desktop files are read by this shell itself, never handed to another
# program, and only if they are regular files: a named pipe called
# something.desktop would make a reader wait forever, and a reader started
# from here could outlive the scan if App Binder stops it. Reads are capped
# per file, and App Binder stops the whole scan if it runs too long. The only
# programs started are stat and readlink, which look paths up without
# opening them, each with a 2-second kill timer (a hung network drive could
# otherwise leave them behind).

set -u
shopt -s nullglob

MAX_ENTRIES=5000      # desktop entries listed at most
MAX_LINES=2000        # lines read per desktop file
MAX_LINE_CHARS=4096   # characters read per line
MAX_ICON_BYTES=$((4 * 1024 * 1024))

data_dirs="${XDG_DATA_HOME:-$HOME/.local/share}:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
declare -A seen

# Sets exec_line, terminal and icon from the [Desktop Entry] group of $1.
read_entry() {
  exec_line=""
  terminal=""
  icon=""
  local line n=0 in_main=0
  while IFS= read -r -n "$MAX_LINE_CHARS" line || [[ -n $line ]]; do
    (( ++n > MAX_LINES )) && break
    line=${line%$'\r'}
    if [[ $line == \[* ]]; then
      if [[ $line == "[Desktop Entry]" ]]; then in_main=1
      elif (( in_main )); then break   # the main group has ended
      fi
      continue
    fi
    (( in_main )) || continue
    case $line in
      Exec=*) [[ -z $exec_line ]] && exec_line=${line#Exec=} ;;
      Terminal=*) [[ -z $terminal ]] && terminal=${line#Terminal=} ;;
      Icon=*) [[ -z $icon ]] && icon=${line#Icon=} ;;
    esac
  done < "$1"
}

first_command() { # strip env VAR=val prefixes and quotes, print the program
  local - word
  set -f # the command line is split into words, never expanded as a glob
  for word in $1; do
    word="${word%\"}"; word="${word#\"}"; word="${word%\'}"; word="${word#\'}"
    case "$word" in
      env|*=*) continue ;;
      *) printf '%s' "$word"; return ;;
    esac
  done
}

flatpak_app() { # the first non-option word after "run"
  local - word seen_run=0
  set -f
  for word in $1; do
    if (( seen_run )) && [[ $word != -* ]]; then printf '%s' "$word"; return; fi
    [[ $word == run ]] && seen_run=1
  done
}

# Sets icon_ok to the entry's icon if it is an absolute path that is safe to
# hand to an image loader, else "". stat only looks the file up; it never
# opens it.
check_icon() {
  icon_ok=""
  local size
  [[ $icon == /* && -f $icon && -r $icon && $icon != *[[:cntrl:]]* ]] || return 0
  size=$(timeout -s KILL 2 stat -L -c %s -- "$icon" 2>/dev/null) || return 0
  (( size > 0 && size <= MAX_ICON_BYTES )) && icon_ok=$icon
}

steam_re='steam://rungameid/([0-9]+)'
heroic_re='(heroic://[^ "]+)'
count=0

IFS=: read -r -a dirs <<<"$data_dirs"
for base in "${dirs[@]}"; do
  for f in "$base"/applications/*.desktop; do
    [[ -f $f ]] || continue   # regular files only (follows symlinks)
    [[ $f == *[[:cntrl:]]* ]] && continue   # a name that would break the output
    id=${f##*/}
    id=${id%.desktop}
    [[ -n "${seen[$id]:-}" ]] && continue
    seen[$id]=1
    (( ++count > MAX_ENTRIES )) && break 2

    read_entry "$f"

    case "$exec_line" in
      "")
        kind=nocommand; loc="$f" ;;
      *steam://rungameid/*)
        kind=steam; loc="$f"
        [[ $exec_line =~ $steam_re ]] && loc="steam://rungameid/${BASH_REMATCH[1]}" ;;
      *heroic://*)
        kind=heroic; loc="$f"
        [[ $exec_line =~ $heroic_re ]] && loc="${BASH_REMATCH[1]}" ;;
      *omarchy-launch-webapp*|*omarchy-webapp-handler*|*--app=*)
        kind=webapp; loc="$f" ;;
      *flatpak\ run*)
        kind=flatpak
        app="$(flatpak_app "$exec_line")"
        loc="$f"
        for root in "$HOME/.local/share/flatpak/app" /var/lib/flatpak/app; do
          [[ -n "$app" && -d "$root/$app" ]] && { loc="$root/$app"; break; }
        done ;;
      *.AppImage*|*.appimage*)
        kind=appimage; loc="$(first_command "$exec_line")" ;;
      *omarchy-launch-tui*|*xdg-terminal-exec*)
        kind=terminal; loc="$f" ;;
      *)
        if [[ "$terminal" == "true" ]]; then
          kind=terminal; loc="$f"
        else
          kind=native
          prog="$(first_command "$exec_line")"
          # PATH lookup with bash's own hash table: no subshell.
          path=""
          if [[ $prog == /* ]]; then
            [[ -x $prog && ! -d $prog ]] && path=$prog
          elif [[ -n $prog && $prog != */* ]] && hash -- "$prog" 2>/dev/null; then
            path=${BASH_CMDS[$prog]:-}
          fi
          # readlink only resolves the path; it never reads the file.
          if [[ -n "$path" ]]; then
            loc="$(timeout -s KILL 2 readlink -f -- "$path" 2>/dev/null)" || loc=$path
            [[ -n $loc ]] || loc=$path
          else
            kind=broken; loc="$prog"
          fi
        fi ;;
    esac

    check_icon
    # Output is tab-separated lines, so no field may hold a control character
    # (a tab or newline would forge another field or line).
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$f" "$kind" "${loc//[[:cntrl:]]/?}" "$icon_ok"
  done
done
echo END
