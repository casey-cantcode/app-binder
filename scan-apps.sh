#!/usr/bin/env bash
# App Binder helper: classify every desktop entry so look-alike apps (e.g. a
# Discord web app next to native Discord) can be told apart.
#
# Prints one line per entry, tab-separated:
#   <desktop id>  <desktop file>  <kind>  <location>
# kind: native | flatpak | webapp | appimage | terminal | steam | heroic |
#       broken (its program doesn't exist) | nocommand (no Exec= line)
# location: the executable's real path (native/appimage), the Flatpak install
# folder (flatpak), the game link (steam/heroic), the missing program
# (broken), or the desktop file (webapp/terminal/nocommand).
#
# Directories are scanned in XDG precedence order; the first file for an id
# wins, matching what the launcher shows.
#
# Desktop files are read by this shell itself, never handed to another
# program, and only if they are regular files: a named pipe called
# something.desktop would make a reader wait forever, and a reader started
# from here could outlive the scan if App Binder stops it. Reads are capped
# per file, and App Binder stops the whole scan if it runs too long.

set -u
shopt -s nullglob

MAX_ENTRIES=5000      # desktop entries listed at most
MAX_LINES=2000        # lines read per desktop file
MAX_LINE_CHARS=4096   # characters read per line

data_dirs="${XDG_DATA_HOME:-$HOME/.local/share}:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
declare -A seen

# Sets exec_line and terminal from the [Desktop Entry] group of file $1.
read_entry() {
  exec_line=""
  terminal=""
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

steam_re='steam://rungameid/([0-9]+)'
heroic_re='(heroic://[^ "]+)'
count=0

IFS=: read -r -a dirs <<<"$data_dirs"
for base in "${dirs[@]}"; do
  for f in "$base"/applications/*.desktop; do
    [[ -f $f ]] || continue   # regular files only (follows symlinks)
    id=${f##*/}
    id=${id%.desktop}
    [[ -n "${seen[$id]:-}" ]] && continue
    seen[$id]=1
    (( ++count > MAX_ENTRIES )) && exit 0

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
          path="$(command -v -- "$prog" 2>/dev/null || true)"
          # readlink only resolves the path; it never reads the file.
          if [[ -n "$path" ]]; then loc="$(readlink -f -- "$path")"; else kind=broken; loc="$prog"; fi
        fi ;;
    esac

    printf '%s\t%s\t%s\t%s\n' "$id" "$f" "$kind" "$loc"
  done
done
