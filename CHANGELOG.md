# Changelog

All notable changes to App Binder are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] - 2026-11-11

A hardening release: App Binder runs inside your desktop, so it should never be able to hang it.

### Security

- Pressing an App Binder shortcut can no longer freeze Hyprland. The code that runs inside Hyprland no longer reads desktop files, other programs' process information, or files on disk; it reads two small files in your private runtime folder and compares bounded text. A window whose title is full of `*` characters, picked as a window match, could previously freeze the desktop for minutes.
- A desktop entry whose icon is a special file (such as a named pipe) can no longer stall image loading in the whole Omarchy shell through App Binder's table. App Binder loads an icon file only if it is a regular file of a sane size, and otherwise only plain theme icon names.
- The window match editor no longer reads the clipboard. Qt's text fields read it automatically, with no size or time limit, so an app streaming a huge clipboard could stall the shell. As a result, pasting into that field doesn't work. Pick the window from the open-window list or type the match.
- App Binder no longer loads its data files as code inside Hyprland, and no longer falls back to the shared `/tmp` folder, where another user on the same machine could have planted a file.

### Changed

- Learned window matches now appear as the row's window match, where you can see and edit them. A match you set yourself is never replaced.
- App Binder reloads Hyprland only when you remove a shortcut that had taken over one of Hyprland's own bindings, so that binding comes back. Other changes apply without a reload.
- Terminal apps launch through `omarchy-launch-tui`, the way Omarchy's launcher starts them.
- The settings file opens with Omarchy's config editor, and App Binder's animations follow Omarchy's animation setting.

### Fixed

- A damaged `app-binder.json` is no longer overwritten: App Binder shows an error and leaves the file alone. Malformed entries are skipped instead of quietly breaking saves.
- Changes made quickly, such as holding an arrow key on the desktop column, are no longer lost.
- A very long window title picked as a window match can no longer stop App Binder from saving.
- Recording a shortcut can no longer leave Hyprland's shortcuts switched off.
- Problems that leave shortcuts off, such as an unreadable `app-binder.json`, now stay visible when you open App Binder and show a notification, instead of disappearing.
- A settings file with an error is no longer overwritten when you move a slider.
- A window match containing an invisible control character, which some game window titles have, no longer stops every App Binder shortcut from loading.
- A special file named like an app entry (such as a named pipe ending in `.desktop`), or a file name containing line breaks, can no longer stall or confuse App Binder's app scan.
- A damaged or clock-skewed launch record can no longer stop apps from launching, and a long non-English window title no longer stops its shortcut from working.
- App Binder no longer removes other bindings on the same keys as its own when it re-applies its shortcuts.
- Values in the settings file are kept within the ranges the Settings sliders allow.

## [0.2.0] - 2026-11-11

### Added

- Pressing an app's shortcut while you're already on that app takes you back to the window you were on before, so one shortcut works as a toggle.
- App Binder learns each app's window the first time it launches the app, then recognizes it exactly from then on, including games run through Wine or Proton. Learned matches live in `~/.local/state/app-binder-learned.lua`. A window match you set by hand always wins.
- Better recognition of apps App Binder hasn't launched yet. Steam games are matched by their Steam ID. Small differences between an app's name and its window (case, spaces, punctuation, a version number) are ignored, and an app can also be found by its window title.
- Window matches can include a title, such as `steam_app_default title:Battle.net`, for games that share a window class. The open-window picker fills this in for you.

### Changed

- The "Window class" column is now "Window match", since it can include a title.

### Fixed

- Taking over a shortcut that Omarchy binds by key name, such as Super+Ctrl+B for Bluetooth, now actually replaces it. Before, both fired. Shortcuts you already took over are fixed automatically.
- Switching to an app no longer moves the mouse cursor.
- Pressing a shortcut again while its app is still starting no longer launches a second copy. For up to a minute, the shortcut takes you to the app's desktop and shows a "still starting" notice instead.
- App Binder's notices, such as "could not bind", now appear.

## [0.1.0] - 2026-11-07

First public release.

### Added

- Super+Ctrl+Alt+Space opens and closes App Binder. If you already use that combo, your binding is kept.
- Installs with a single `omarchy plugin add`, with no Hyprland config to edit. App Binder adds its shortcuts to Hyprland itself when the shell starts, and again after every config reload.
- One shortcut per app: it focuses the app's most recently used window if the app is running (switching to its desktop), or launches it if not. It never opens a second copy.
- Table of every installed app with icons, the same list Omarchy's launcher shows. Bound apps sort to the top, and you type to filter.
- Each app shows its type (Native, Flatpak, Web app, AppImage, Terminal app, Steam game, Heroic game) and where it lives, so look-alike entries such as a Discord web app next to native Discord can be told apart. Click the line to copy the path.
- Entries whose program no longer exists are flagged as **Broken**, and entries with nothing to run as **No command**.
- Press-to-record shortcuts. While recording, Hyprland's other shortcuts are paused so the combo reaches App Binder, then resume automatically. Super+Ctrl+Alt+Shift+Esc restores them immediately if needed.
- Conflict warnings: App Binder shows what a combo does now and replaces it only if you confirm. A combo taken from another App Binder row is removed from that row.
- A desktop per app (`Any` or 1–10). A shortcut ending in a number key sets that desktop. Any other key picks the lowest desktop no other app uses. Desktops you choose by hand are kept.
- Window matching by Hyprland window class, with `*` wildcards and one-click picks from open windows.
- Settings panel behind an animated cog. Sliders cover scroll speed, scroll glide, window size and recording timeout. Switches cover the two auto-desktop rules and click-outside-to-close. There's also a button to edit `app-binder-settings.jsonc` directly, and changes to the file apply immediately.
- Smooth, configurable mouse-wheel scrolling.
- Open App Binder with Settings showing or a filter pre-filled, from a script or keybinding: `omarchy-shell shell summon cantcode.app-binder '{"settings": true}'` or `'{"filter": "discord"}'`.
- Click outside to close, the same way Omarchy's popups work (can be turned off).
- Optional multi-monitor support: if `~/.config/hypr/linked-desktops.lua` exists, a "desktop" can span several monitors.
- Styling from Omarchy's own shell components, so App Binder follows your theme.

[unreleased]: https://github.com/casey-cantcode/app-binder/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/casey-cantcode/app-binder/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/casey-cantcode/app-binder/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/casey-cantcode/app-binder/releases/tag/v0.1.0
