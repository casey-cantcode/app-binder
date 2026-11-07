# Changelog

All notable changes to App Binder are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[unreleased]: https://github.com/casey-cantcode/app-binder/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/casey-cantcode/app-binder/releases/tag/v0.1.0
