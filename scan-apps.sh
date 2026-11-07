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

set -u
shopt -s nullglob

data_dirs="${XDG_DATA_HOME:-$HOME/.local/share}:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
declare -A seen

field() { # field <file> <Key> -> first value of Key= in the [Desktop Entry] group
  awk -v k="$2" -F= '
    /^\[/ { in_main = ($0 == "[Desktop Entry]") }
    in_main && $1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1"
}

first_command() { # strip env VAR=val prefixes and quotes, print the program
  local word
  for word in $1; do
    word="${word%\"}"; word="${word#\"}"; word="${word%\'}"; word="${word#\'}"
    case "$word" in
      env|*=*) continue ;;
      *) printf '%s' "$word"; return ;;
    esac
  done
}

IFS=: read -r -a dirs <<<"$data_dirs"
for base in "${dirs[@]}"; do
  for f in "$base"/applications/*.desktop; do
    id="$(basename "$f" .desktop)"
    [[ -n "${seen[$id]:-}" ]] && continue
    seen[$id]=1

    exec_line="$(field "$f" Exec)"
    terminal="$(field "$f" Terminal)"

    case "$exec_line" in
      "")
        kind=nocommand; loc="$f" ;;
      *steam://rungameid/*)
        kind=steam; loc="steam://rungameid/$(sed -E 's|.*steam://rungameid/([0-9]+).*|\1|' <<<"$exec_line")" ;;
      *heroic://*)
        kind=heroic; loc="$(grep -oE 'heroic://[^ "]+' <<<"$exec_line" | head -n1)" ;;
      *omarchy-launch-webapp*|*omarchy-webapp-handler*|*--app=*)
        kind=webapp; loc="$f" ;;
      *flatpak\ run*)
        kind=flatpak
        app="$(awk '{ for (i = 1; i <= NF; i++) if (seen_run && $i !~ /^-/) { print $i; exit } else if ($i == "run") seen_run = 1 }' <<<"$exec_line")"
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
          if [[ -n "$path" ]]; then loc="$(readlink -f -- "$path")"; else kind=broken; loc="$prog"; fi
        fi ;;
    esac

    printf '%s\t%s\t%s\t%s\n' "$id" "$f" "$kind" "$loc"
  done
done
