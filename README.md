# App Binder

One key per app. Press it and the app comes forward if it's running, or launches if it isn't.

App Binder is an [Omarchy](https://omarchy.org) shell plugin for the macOS/Raycast habit of jumping straight to an app by keyboard: `Super+Ctrl+1` for the terminal, `Super+Ctrl+6` for the browser, `Super+Ctrl+M` for mail. It's not "go to desktop 6 and hope the browser is there". It means "I want the browser", wherever the browser is.

Assign shortcuts in a table of every installed app: click a row, press the combo, done.

<!-- Add a screenshot: save it as preview.png in the repo root. -->
![App Binder](preview.png)

## What a shortcut does

- **App running:** switches to the desktop its window is on and focuses it. If it has several windows, it goes to the most recently used one. It never opens a second copy.
- **App not running:** switches to the app's desktop (or the first empty one), then launches it there.

## Features

- **Table of every installed app**, using the same list as Omarchy's app launcher, with icons. Bound apps sort to the top. Type to filter.
- **Press-to-record shortcuts.** Click a row (or press Enter), then press the combo. While it records, your other Hyprland shortcuts are briefly paused, so even a combo that's already in use reaches the recorder instead of firing.
- **Conflict warnings.** If a combo is already bound, App Binder shows what it does now. Press Enter to take it over or Esc to pick another. A combo moved from another App Binder row is removed from that row.
- **A desktop per app.** Choose `Any` (first empty desktop) or 1–10.
  - A shortcut ending in a number key sets that desktop: `Super+Ctrl+4` puts the app on desktop 4.
  - A shortcut ending in any other key picks the lowest desktop no other app uses.
  - Desktops you choose by hand are kept when you re-record a shortcut.
- **Window matching** by Hyprland window class. App Binder fills in a sensible default (the app's `StartupWMClass`, or its desktop-entry ID). You can edit it, use `*` wildcards (e.g. `*hey.com*` for a web app), or pick from the classes of currently open windows.
- **Settings panel** behind the cog: sliders and switches, plus a button to edit the settings file directly.
- **Matches your Omarchy theme.** It uses Omarchy's own shell components (the same rows, sliders and switches as the built-in panels).

## Requirements

- Omarchy 4 ("Quattro"), which uses the Lua Hyprland config and the Quickshell-based Omarchy shell. Tested on Omarchy 4.0.0.
- Hyprland 0.56 or newer. Tested on 0.56.2.

## Install

1. Add the plugin:

   ```bash
   omarchy plugin add https://github.com/casey-cantcode/app-binder --enable
   ```

2. Load App Binder's Hyprland side by adding this line to `~/.config/hypr/hyprland.lua`, **after** `require("hypr.bindings")`, so App Binder's shortcuts override your own bindings:

   ```lua
   dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/cantcode.app-binder/hypr/app-binder.lua")
   ```

   Hyprland reloads on save. Check for errors with `hyprctl configerrors`.

3. Open App Binder with **Super+Ctrl+Alt+Space**.

## Usage

| Do this | What happens |
|---|---|
| Type | Filters the app list |
| Click a row, or Enter | Records a shortcut for that app |
| Esc while recording | Cancels |
| Backspace while recording, or Del | Clears the app's shortcut |
| Click the Desktop cell, or ←/→ | Cycles `Any`, 1–10. Right-click cycles backwards |
| Click the Window class cell | Edits the match; open windows' classes appear as clickable chips |
| Cog | Shows or hides Settings |
| Esc, Super+Ctrl+Alt+Space, or click outside | Closes App Binder |

A shortcut must include Super, Ctrl or Alt, so plain typing can never be taken over. Suggested convention: `Super+Ctrl+<key>` for apps, and `Super+Ctrl+Shift+<key>` for a "personal" counterpart (e.g. work browser and personal browser).

## Settings

Change these with the cog, or edit `~/.config/omarchy/app-binder-settings.jsonc` directly (JSON with `//` comments). Saved changes apply immediately. Delete the file to restore the defaults.

| Setting | Default | Description |
|---|---|---|
| `scroll_rows_per_notch` | `1` | Rows the list scrolls per mouse-wheel notch |
| `scroll_glide_ms` | `140` | Length of the scroll glide in ms; `0` = jump instantly |
| `window_width` / `window_height` | `1000` / `720` | Largest window size; it shrinks on smaller screens |
| `capture_timeout_seconds` | `20` | How long recording waits for a shortcut |
| `auto_desktop_number_keys` | `true` | A number-key shortcut sets that desktop |
| `auto_desktop_other_keys` | `true` | Any other shortcut picks the first unused desktop |
| `close_on_click_outside` | `true` | Clicking outside closes App Binder. When `false`, other windows stay clickable while it's open |

## How it works

| File | Role |
|---|---|
| `AppBinder.qml` | The window (an Omarchy shell overlay plugin) |
| `hypr/app-binder.lua` | Hyprland side: turns each saved row into a binding with the focus-or-launch logic |
| `~/.config/omarchy/app-binder.json` | Your shortcuts. App Binder writes this; it's the source of truth |
| `~/.config/hypr/app-binder-data.lua` | Generated from the JSON for Hyprland to read. Don't edit by hand |

When you change something, App Binder writes both files and runs `hyprctl reload`. Shortcuts are ordinary Hyprland bindings (described as `App Binder: <app>`), so they work from login whether or not the window is open, and appear in Omarchy's keybindings list.

Apps launch the same way Omarchy's launcher starts them: `uwsm-app -- gtk-launch <app>.desktop`.

### Multi-monitor desktops (optional)

By default a "desktop" is a plain Hyprland workspace. If your setup treats a desktop as a set of workspaces across several monitors, provide a Lua module at `~/.config/hypr/linked-desktops.lua` that returns a table with these functions, and App Binder will use them:

| Function | Purpose |
|---|---|
| `switch(n)` | Show desktop `n` |
| `focus_window(win)` | Bring up the desktop holding `win` (a Hyprland window object) and focus it |
| `first_empty()` | Return the lowest empty desktop number, or `nil` |

## Troubleshooting

- **The shortcut launches a second copy instead of focusing.** The window class doesn't match. Open the app, click its Window class cell in App Binder, and pick the right class from the open-window chips. Web apps usually need a wildcard such as `*hey.com*`.
- **Keyboard shortcuts stopped working while recording.** Recording pauses Hyprland's shortcuts, and they come back automatically after the recording timeout. To restore them immediately, press **Super+Ctrl+Alt+Shift+Esc**.
- **Edits to `AppBinder.qml` don't show up.** App Binder stays loaded for the whole session, so it doesn't hot-reload. Run `omarchy restart shell`.

## Uninstall

```bash
omarchy plugin remove cantcode.app-binder
```

Then remove the `dofile(...)` line from `~/.config/hypr/hyprland.lua`. Optionally delete `~/.config/omarchy/app-binder.json`, `~/.config/omarchy/app-binder-settings.jsonc` and `~/.config/hypr/app-binder-data.lua`.

## License

<!-- Choose a license (e.g. MIT) and add a LICENSE file. -->
