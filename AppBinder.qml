import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// App Binder: a table of installed apps. Give a row a shortcut and a desktop;
// the shortcut then focuses the app if it's running or launches it if not.
//
// Source of truth: ~/.config/omarchy/app-binder.json
// Generated for Hyprland: ~/.config/omarchy/app-binder-data.lua, read by
// hypr/app-binder.lua, which this plugin runs inside Hyprland (hyprctl eval)
// at startup and after every config reload. No hyprland.lua edits needed.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  readonly property string pluginId: (manifest && manifest.id) || "cantcode.app-binder"
  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/app-binder.json"
  readonly property string dataPath: home + "/.config/omarchy/app-binder-data.lua"
  readonly property string legacyDataPath: home + "/.config/hypr/app-binder-data.lua"
  // Hyprland side, run inside Hyprland with `hyprctl eval` (see applyBindings).
  readonly property string runtimePath: decodeURIComponent(String(Qt.resolvedUrl("hypr/app-binder.lua")).replace(/^file:\/\//, ""))
  readonly property string settingsPath: home + "/.config/omarchy/app-binder-settings.jsonc"

  // ---------------------------------------------------------------- settings
  // User-editable in settingsPath (cog button). Missing keys fall back to these.
  readonly property var defaultSettings: ({
    scroll_rows_per_notch: 1,
    scroll_glide_ms: 140,
    window_width: 1000,
    window_height: 720,
    capture_timeout_seconds: 20,
    auto_desktop_number_keys: true,
    auto_desktop_other_keys: true,
    close_on_click_outside: true
  })
  property var settings: defaultSettings

  function setting(name) {
    var v = root.settings ? root.settings[name] : undefined
    var d = root.defaultSettings[name]
    if (v === undefined || v === null || typeof v !== typeof d) return d
    return v
  }

  // The settings file, rendered from values with explanatory comments. Used
  // both to create the file and to save changes made in the Settings section,
  // so the file always stays readable in an editor.
  function settingsText(v) {
    function val(name) {
      var x = v && v[name] !== undefined ? v[name] : root.defaultSettings[name]
      return JSON.stringify(x)
    }
    return "// App Binder settings. Edit here or in App Binder's Settings section\n"
      + "// (cog button). Saved changes apply immediately. Delete this file to\n"
      + "// get the defaults back.\n"
      + "{\n"
      + "  // Rows the list scrolls per mouse-wheel notch (decimals are fine).\n"
      + "  \"scroll_rows_per_notch\": " + val("scroll_rows_per_notch") + ",\n"
      + "\n"
      + "  // How long each scroll glides, in milliseconds. 0 = jump instantly.\n"
      + "  \"scroll_glide_ms\": " + val("scroll_glide_ms") + ",\n"
      + "\n"
      + "  // Largest window size (it shrinks to fit smaller screens).\n"
      + "  \"window_width\": " + val("window_width") + ",\n"
      + "  \"window_height\": " + val("window_height") + ",\n"
      + "\n"
      + "  // How long to wait for a shortcut before giving up. While waiting,\n"
      + "  // your other Hyprland shortcuts are paused.\n"
      + "  \"capture_timeout_seconds\": " + val("capture_timeout_seconds") + ",\n"
      + "\n"
      + "  // Shortcut ending in a number key (e.g. Super+Ctrl+4) sets that desktop.\n"
      + "  \"auto_desktop_number_keys\": " + val("auto_desktop_number_keys") + ",\n"
      + "\n"
      + "  // Shortcut ending in any other key sets the lowest desktop no other\n"
      + "  // app uses.\n"
      + "  \"auto_desktop_other_keys\": " + val("auto_desktop_other_keys") + ",\n"
      + "\n"
      + "  // Clicking anywhere outside App Binder closes it. When false, other\n"
      + "  // windows stay clickable while it's open.\n"
      + "  \"close_on_click_outside\": " + val("close_on_click_outside") + "\n"
      + "}\n"
  }
  readonly property string defaultSettingsText: settingsText(defaultSettings)

  property bool settingsOpen: false
  property bool animateSettings: true

  // Change one setting from the Settings section and save the file.
  function updateSetting(name, value) {
    var next = ({})
    for (var k in root.defaultSettings) next[k] = root.setting(k)
    next[name] = value
    root.settings = next
    settingsSaveProc.command = ["bash", "-c",
      "printf '%s' \"$2\" > \"$1.tmp\" && mv \"$1.tmp\" \"$1\"",
      "app-binder-settings", root.settingsPath, root.settingsText(next)]
    settingsSaveProc.running = true
  }

  // JSONC: drop // line comments (outside strings) and trailing commas.
  function parseJsonc(text) {
    var out = ""
    var inString = false
    var s = String(text || "")
    for (var i = 0; i < s.length; i++) {
      var c = s.charAt(i)
      if (inString) {
        out += c
        if (c === "\\") { out += s.charAt(i + 1); i++ }
        else if (c === "\"") inString = false
      } else if (c === "\"") {
        inString = true
        out += c
      } else if (c === "/" && s.charAt(i + 1) === "/") {
        while (i < s.length && s.charAt(i) !== "\n") i++
        out += "\n"
      } else {
        out += c
      }
    }
    return JSON.parse(out.replace(/,(\s*[}\]])/g, "$1"))
  }

  function loadSettings(text) {
    try {
      var parsed = root.parseJsonc(text)
      var next = (parsed && typeof parsed === "object") ? parsed : root.defaultSettings
      var changed = JSON.stringify(next) !== JSON.stringify(root.settings)
      root.settings = next
      if (changed && root.opened)
        root.setStatus("Settings updated (scroll: " + root.wheelRowsPerNotch + " rows per notch).", false)
    } catch (e) {
      root.settings = root.defaultSettings
      root.setStatus("Settings file has an error, using defaults: " + e, true)
    }
  }

  // "Edit ... directly": make sure the file exists, open it in the editor.
  function openSettingsFile() {
    settingsWriteProc.running = true
  }

  // id -> { name, keys, label, match, desktop }
  property var apps: ({})
  property var binds: []
  property var windowClasses: []
  // desktop id -> { file, kind, location } from scan-apps.sh
  property var appInfo: ({})
  readonly property string scanScript: decodeURIComponent(String(Qt.resolvedUrl("scan-apps.sh")).replace(/^file:\/\//, ""))
  readonly property var kindLabels: ({
    native: "Native", flatpak: "Flatpak", webapp: "Web app", appimage: "AppImage",
    terminal: "Terminal app", steam: "Steam game", heroic: "Heroic game",
    broken: "Broken: program not found", nocommand: "No command"
  })
  property var rows: []
  property string filterText: ""
  property int selectedIndex: 0
  property string selectedId: ""

  property string captureId: ""
  property var pendingCapture: null
  property string editingMatchId: ""
  property string status: ""
  property bool statusError: false
  property bool saveQueued: false

  // Shares the menu surface tokens, like Omarchy's own overlays.
  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color border: Commons.Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Commons.Color.menu.scrim
  property color selectedBackground: Commons.Color.menu.selectedBackground
  property color selectedText: Commons.Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  // Two lines per row: app name, then its type and location.
  property int rowHeight: Math.max(Style.space(50), Style.font.heading + Style.font.caption + Style.spacing.controlPaddingY * 2 + Style.spacing.xs)
  property int pillHeight: Math.max(Style.space(30), Style.font.body + Style.spacing.controlPaddingY * 2)
  // Mouse-wheel speed: rows moved per wheel notch.
  property real wheelRowsPerNotch: Math.max(0.25, Number(root.setting("scroll_rows_per_notch")))
  property int iconSize: Math.round(rowHeight * 0.58)
  property int shortcutWidth: Style.space(210)
  property int desktopWidth: Style.space(84)
  property int matchWidth: Style.space(250)
  // Sized from the screen, not the window: the window is only as big as the card.
  readonly property int screenWidth: panel.screen ? panel.screen.width : 1920
  readonly property int screenHeight: panel.screen ? panel.screen.height : 1080
  property int cardWidth: Math.min(Style.space(Math.max(500, root.setting("window_width"))), screenWidth - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(Math.max(300, root.setting("window_height"))), screenHeight - Style.gapsOut * 2)

  // ---------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.editingMatchId = ""
    root.setStatus("", false)
    // Re-read settings on every open: editors that save by replacing the file
    // can slip past the file watcher.
    settingsFile.reload()
    // Settings start collapsed on every open (snap, no animation), unless the
    // payload {"settings": true} asks for them. {"filter": "..."} pre-fills
    // the filter.
    var showSettings = false
    try {
      var payload = JSON.parse(payloadJson || "{}")
      showSettings = !!(payload && payload.settings === true)
      if (payload && typeof payload.filter === "string") root.filterText = payload.filter
    } catch (e) {}
    root.animateSettings = false
    root.settingsOpen = showSettings
    Qt.callLater(function() { root.animateSettings = true })
    bindsProc.running = true
    clientsProc.running = true
    scanProc.running = true
    root.rebuild()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.endCapture()
    root.editingMatchId = ""
    root.opened = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  Component.onDestruction: {
    if (root.captureId !== "") Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.submap('reset')"])
  }

  // ---------------------------------------------------------------- rows

  function defaultMatch(entry, id) {
    var cls = entry && entry.startupClass ? String(entry.startupClass) : ""
    return cls.length > 0 ? cls : id
  }

  function iconFor(icon) {
    var value = String(icon || "")
    if (value.length === 0) return Quickshell.iconPath("application-x-executable", true)
    if (value.charAt(0) === "/") return "file://" + value
    var themed = Quickshell.iconPath(value, true)
    return themed.length > 0 ? themed : Quickshell.iconPath("application-x-executable", true)
  }

  function rebuild() {
    var values = DesktopEntries.applications.values || []
    var seen = ({})
    var list = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (!entry || entry.noDisplay) continue
      var id = String(entry.id || "")
      if (!id || seen[id]) continue
      seen[id] = true
      list.push(root.makeRow(id, String(entry.name || id), entry.icon, root.defaultMatch(entry, id), false))
    }
    for (var cid in root.apps) {
      if (seen[cid]) continue
      var a = root.apps[cid]
      list.push(root.makeRow(cid, String(a.name || cid), "", String(a.match || cid), true))
    }

    var q = root.filterText.toLowerCase()
    if (q.length > 0) {
      list = list.filter(function(r) {
        return r.name.toLowerCase().indexOf(q) !== -1 || r.id.toLowerCase().indexOf(q) !== -1
          || r.label.toLowerCase().indexOf(q) !== -1
          || r.kindLabel.toLowerCase().indexOf(q) !== -1
          || r.location.toLowerCase().indexOf(q) !== -1
      })
    }
    list.sort(function(a, b) {
      var ab = a.keys !== "" ? 0 : 1
      var bb = b.keys !== "" ? 0 : 1
      if (ab !== bb) return ab - bb
      return a.name.toLowerCase().localeCompare(b.name.toLowerCase())
    })
    root.rows = list

    var idx = 0
    for (var j = 0; j < list.length; j++) if (list[j].id === root.selectedId) { idx = j; break }
    root.selectedIndex = list.length > 0 ? idx : 0
    if (list.length > 0) root.selectedId = list[root.selectedIndex].id
    Qt.callLater(function() {
      if (root.rows.length > 0) table.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function makeRow(id, name, icon, fallbackMatch, missing) {
    var cfg = root.apps[id] || ({})
    return {
      id: id,
      name: name,
      icon: icon || "",
      keys: String(cfg.keys || ""),
      label: String(cfg.label || ""),
      match: String(cfg.match || fallbackMatch),
      defaultMatch: fallbackMatch,
      desktop: Number(cfg.desktop || 0),
      desktopAuto: cfg.desktopAuto === true,
      missing: missing,
      kind: root.appInfo[id] ? root.appInfo[id].kind : "",
      kindLabel: root.appInfo[id] ? (root.kindLabels[root.appInfo[id].kind] || root.appInfo[id].kind) : "",
      location: root.appInfo[id] ? root.appInfo[id].location : "",
      file: root.appInfo[id] ? root.appInfo[id].file : ""
    }
  }

  function rowById(id) {
    for (var i = 0; i < root.rows.length; i++) if (root.rows[i].id === id) return root.rows[i]
    return null
  }

  function select(index) {
    if (root.rows.length === 0) return
    if (index < 0) index = 0
    if (index >= root.rows.length) index = root.rows.length - 1
    root.selectedIndex = index
    root.selectedId = root.rows[index].id
    table.positionViewAtIndex(index, ListView.Contain)
  }

  // ---------------------------------------------------------------- config

  function loadConfig(text) {
    try {
      var parsed = JSON.parse(text || "{}")
      root.apps = (parsed && parsed.apps) ? parsed.apps : ({})
    } catch (e) {
      root.setStatus("App Binder: could not parse " + root.configPath + " (" + e + ")", true)
      root.apps = ({})
    }
    if (root.opened) root.rebuild()
  }

  // Merge `patch` into one app's settings and save.
  function setApp(id, patch) {
    var row = root.rowById(id)
    var next = ({})
    for (var k in root.apps) next[k] = root.apps[k]
    var cur = next[id] ? JSON.parse(JSON.stringify(next[id])) : ({})
    for (var p in patch) cur[p] = patch[p]
    if (row) {
      cur.name = row.name
      if (!cur.match) cur.match = row.defaultMatch
    }
    var isDefault = !cur.keys && !Number(cur.desktop || 0) && (!row || cur.match === row.defaultMatch)
    if (isDefault) delete next[id]
    else next[id] = cur
    root.apps = next
    root.save()
    root.rebuild()
  }

  function clearKeysElsewhere(keys, exceptId) {
    var next = ({})
    var cleared = []
    for (var k in root.apps) {
      var a = root.apps[k]
      if (k !== exceptId && a.keys === keys) {
        var copy = JSON.parse(JSON.stringify(a))
        copy.keys = ""
        copy.label = ""
        next[k] = copy
        cleared.push(a.name || k)
      } else {
        next[k] = a
      }
    }
    root.apps = next
    return cleared
  }

  function luaString(s) {
    return JSON.stringify(String(s === undefined || s === null ? "" : s))
  }

  function buildLua() {
    var out = "-- Generated by App Binder (SUPER+CTRL+ALT+SPACE). Don't edit by hand:\n"
      + "-- changes are overwritten from " + root.configPath + "\n"
      + "return {\n"
    var ids = Object.keys(root.apps).sort()
    for (var i = 0; i < ids.length; i++) {
      var a = root.apps[ids[i]]
      if (!a.keys) continue
      out += "  { id = " + root.luaString(ids[i])
        + ", name = " + root.luaString(a.name || ids[i])
        + ", keys = " + root.luaString(a.keys)
        + ", match = " + root.luaString(a.match || ids[i])
        + ", desktop = " + (Number(a.desktop || 0) | 0) + " },\n"
    }
    return out + "}\n"
  }

  function save() {
    if (saveProc.running) { root.saveQueued = true; return }
    var json = JSON.stringify({ version: 1, apps: root.apps }, null, 2) + "\n"
    saveProc.command = ["bash", "-c",
      "set -e\n"
      + "printf '%s' \"$1\" > \"$3.tmp\" && mv \"$3.tmp\" \"$3\"\n"
      + "printf '%s' \"$2\" > \"$4.tmp\" && mv \"$4.tmp\" \"$4\"\n"
      + "rm -f \"$5\"\n"
      // A full reload restores any default binding a removed shortcut had
      // replaced; App Binder re-applies its own on the configreloaded event.
      + "hyprctl reload >/dev/null\n",
      "app-binder-save", json, root.buildLua(), root.configPath, root.dataPath, root.legacyDataPath]
    saveProc.running = true
  }

  // ---------------------------------------------------------------- capture

  readonly property var modifierKeys: [Qt.Key_Shift, Qt.Key_Control, Qt.Key_Meta, Qt.Key_Alt, Qt.Key_AltGr,
    Qt.Key_Super_L, Qt.Key_Super_R, Qt.Key_Hyper_L, Qt.Key_Hyper_R, Qt.Key_CapsLock, Qt.Key_NumLock]

  function startCapture(id) {
    if (!id) return
    root.editingMatchId = ""
    root.captureId = id
    root.pendingCapture = null
    root.selectedId = id
    // Empty submap: Hyprland stops firing its own bindings so the combo reaches us.
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.submap('appbinder')"])
    captureTimer.restart()
    var row = root.rowById(id)
    root.setStatus("Press the shortcut for " + (row ? row.name : id) + "…   Esc cancels · Backspace clears", false)
  }

  function endCapture() {
    if (root.captureId === "") return
    root.captureId = ""
    root.pendingCapture = null
    captureTimer.stop()
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.submap('reset')"])
    keyCatcher.forceActiveFocus()
  }

  function keyLabel(event, keycode) {
    if (keycode >= 10 && keycode <= 19) return String((keycode - 9) % 10)
    var k = event.key
    if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode(k)
    if (k >= Qt.Key_F1 && k <= Qt.Key_F24) return "F" + (k - Qt.Key_F1 + 1)
    var named = {}
    named[Qt.Key_Space] = "Space"; named[Qt.Key_Return] = "Enter"; named[Qt.Key_Enter] = "Enter"
    named[Qt.Key_Tab] = "Tab"; named[Qt.Key_Backtab] = "Tab"; named[Qt.Key_Left] = "Left"
    named[Qt.Key_Right] = "Right"; named[Qt.Key_Up] = "Up"; named[Qt.Key_Down] = "Down"
    named[Qt.Key_Home] = "Home"; named[Qt.Key_End] = "End"; named[Qt.Key_PageUp] = "PgUp"
    named[Qt.Key_PageDown] = "PgDn"; named[Qt.Key_Insert] = "Insert"; named[Qt.Key_Delete] = "Delete"
    named[Qt.Key_Backspace] = "Backspace"; named[Qt.Key_Escape] = "Esc"
    if (named[k]) return named[k]
    var t = String(event.text || "")
    if (t.length === 1 && t.charCodeAt(0) > 32 && t.charCodeAt(0) !== 127) return t.toUpperCase()
    return "code:" + keycode
  }

  // Parse `hyprctl binds` text output. (Hyprland 0.56's -j output leaves `key`
  // empty for code:N binds; the text form carries it.) Each block looks like:
  //   bindd\n\tmodmask: 68\n\tsubmap: \n\tkey: SUPER + CTRL + code:17\n...
  function parseBinds(text) {
    var out = []
    var blocks = String(text || "").split(/\n\s*\n/)
    for (var i = 0; i < blocks.length; i++) {
      var lines = blocks[i].split("\n")
      var b = { flags: lines[0].trim() }
      for (var j = 1; j < lines.length; j++) {
        var m = lines[j].match(/^\s*([a-z_]+):\s?(.*)$/)
        if (m) b[m[1]] = m[2]
      }
      if (b.modmask === undefined) continue
      var keyPart = String(b.key || "").split("+").pop().trim()
      var code = keyPart.match(/^code:(\d+)$/i)
      out.push({
        mouse: b.flags.indexOf("m") !== -1 && /^mouse/i.test(keyPart),
        modmask: Number(b.modmask),
        submap: String(b.submap || ""),
        keycode: code ? Number(code[1]) : Number(b.keycode || 0),
        key: code ? "" : keyPart,
        description: String(b.description || ""),
        dispatcher: String(b.dispatcher || ""),
        arg: String(b.arg || "")
      })
    }
    return out
  }

  function conflictFor(mask, keycode, label) {
    for (var i = 0; i < root.binds.length; i++) {
      var b = root.binds[i]
      if (!b || b.mouse || b.submap !== "") continue
      if (b.description.indexOf("App Binder:") === 0) continue
      if (b.modmask !== mask) continue
      var sameCode = b.keycode !== 0 && b.keycode === keycode
      var sameName = b.keycode === 0 && b.key.toUpperCase() === label.toUpperCase()
      if (sameCode || sameName) return b.description || (b.dispatcher + " " + b.arg)
    }
    return ""
  }

  function handleCaptureKey(event) {
    event.accepted = true
    if (event.isAutoRepeat) return
    var mods = event.modifiers
    var plain = (mods & (Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier)) === 0

    if (root.pendingCapture) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        root.applyCapture(root.pendingCapture)
      } else if (event.key === Qt.Key_Escape && plain) {
        root.pendingCapture = null
        root.startCapture(root.captureId)
      }
      return
    }
    if (plain && event.key === Qt.Key_Escape) {
      root.endCapture()
      root.setStatus("Cancelled", false)
      return
    }
    if (plain && (event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete)) {
      var id = root.captureId
      var row = root.rowById(id)
      root.endCapture()
      root.setApp(id, { keys: "", label: "" })
      root.setStatus("Cleared the shortcut for " + (row ? row.name : id), false)
      return
    }
    if (root.modifierKeys.indexOf(event.key) !== -1) return

    var hasSuper = (mods & Qt.MetaModifier) !== 0
    var hasCtrl = (mods & Qt.ControlModifier) !== 0
    var hasAlt = (mods & Qt.AltModifier) !== 0
    var hasShift = (mods & Qt.ShiftModifier) !== 0
    if (!hasSuper && !hasCtrl && !hasAlt) {
      root.setStatus("Hold Super, Ctrl or Alt with the key, so normal typing isn't hijacked.", true)
      return
    }
    var keycode = event.nativeScanCode
    if (!keycode || keycode <= 0) {
      root.setStatus("Couldn't read that key's code. Try another key.", true)
      return
    }
    var names = []
    var labels = []
    var mask = 0
    if (hasSuper) { names.push("SUPER"); labels.push("Super"); mask |= 64 }
    if (hasCtrl) { names.push("CTRL"); labels.push("Ctrl"); mask |= 4 }
    if (hasAlt) { names.push("ALT"); labels.push("Alt"); mask |= 8 }
    if (hasShift) { names.push("SHIFT"); labels.push("Shift"); mask |= 1 }
    var keyName = root.keyLabel(event, keycode)
    var capture = {
      id: root.captureId,
      keys: names.join(" + ") + " + code:" + keycode,
      label: labels.join("+") + "+" + keyName
    }
    var taken = root.conflictFor(mask, keycode, keyName)
    if (taken !== "") {
      root.pendingCapture = capture
      root.setStatus(capture.label + " is currently “" + taken + "”.   Enter takes it over · Esc picks another", true)
      return
    }
    root.applyCapture(capture)
  }

  // Lowest desktop (1-10) no other app is assigned to, or 0 if all are taken.
  function firstUnassignedDesktop(exceptId) {
    var used = ({})
    for (var k in root.apps) {
      if (k === exceptId) continue
      var d = Number(root.apps[k].desktop || 0)
      if (d > 0) used[d] = true
    }
    for (var n = 1; n <= 10; n++) if (!used[n]) return n
    return 0
  }

  // Desktop implied by a shortcut ending in a number-row key (1-9, 0 = 10), else 0.
  function digitDesktop(keys) {
    var m = String(keys || "").match(/code:(\d+)$/)
    var code = m ? Number(m[1]) : 0
    return code >= 10 && code <= 19 ? code - 9 : 0
  }

  function applyCapture(capture) {
    var row = root.rowById(capture.id)
    var cleared = root.clearKeysElsewhere(capture.keys, capture.id)
    root.endCapture()
    var patch = { keys: capture.keys, label: capture.label }
    // Auto-pick the desktop unless it was chosen by hand: a number key means
    // that desktop; any other key means the lowest desktop no other app uses.
    var current = row ? row.desktop : 0
    var handPicked = current !== 0 && !(row && row.desktopAuto)
      && current !== root.digitDesktop(row ? row.keys : "")
    var implied = root.digitDesktop(capture.keys)
    if (implied > 0 && !root.setting("auto_desktop_number_keys")) implied = -1
    if (implied === 0) implied = root.setting("auto_desktop_other_keys")
      ? root.firstUnassignedDesktop(capture.id) : 0
    var autoDesktop = !handPicked && implied > 0
    if (autoDesktop) { patch.desktop = implied; patch.desktopAuto = true }
    root.setApp(capture.id, patch)
    var msg = capture.label + " → " + (row ? row.name : capture.id)
    if (autoDesktop) msg += " on desktop " + implied
    if (cleared.length > 0) msg += "   (removed from " + cleared.join(", ") + ")"
    root.setStatus(msg, false)
  }

  // ---------------------------------------------------------------- other edits

  function cycleDesktop(id, delta) {
    var row = root.rowById(id)
    if (!row) return
    var d = (row.desktop + delta + 11) % 11
    root.setApp(id, { desktop: d, desktopAuto: false })
    root.setStatus(row.name + " launches on " + (d === 0 ? "the first empty desktop" : "desktop " + d), false)
  }

  function startEditMatch(id) {
    root.endCapture()
    root.editingMatchId = id
    clientsProc.running = true
    var row = root.rowById(id)
    root.setStatus("Window class to look for. Exact match, or use * as a wildcard. Enter saves · Esc cancels", false)
  }

  function commitMatch(id, value) {
    var row = root.rowById(id)
    var v = String(value || "").trim()
    if (v === "" && row) v = row.defaultMatch
    root.editingMatchId = ""
    root.setApp(id, { match: v })
    root.setStatus((row ? row.name : id) + " matches windows of class “" + v + "”", false)
    keyCatcher.forceActiveFocus()
  }

  // Display paths with ~ for the home folder (copying keeps the full path).
  function tildePath(path) {
    var p = String(path || "")
    return root.home && p.indexOf(root.home + "/") === 0 ? "~" + p.slice(root.home.length) : p
  }

  function copyText(text) {
    if (!text) return
    Quickshell.execDetached(["wl-copy", "--", text])
    root.setStatus("Copied " + text, false)
  }

  function setStatus(text, isError) {
    root.status = text
    root.statusError = isError === true
  }

  // ---------------------------------------------------------------- IO

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadConfig(text())
    onLoadFailed: root.loadConfig("{}")
    onFileChanged: reload()
  }

  Process {
    id: saveProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var errs = String(text || "").trim()
        if (errs.length > 0) root.setStatus("Hyprland config error: " + errs, true)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err.length > 0) root.setStatus("Save failed: " + err, true)
      }
    }
    onExited: {
      bindsProc.running = true
      if (root.saveQueued) { root.saveQueued = false; root.save() }
    }
  }

  // ------------------------------------------------ install shortcuts in Hyprland

  // Run hypr/app-binder.lua inside Hyprland. Runtime bindings are wiped by
  // every config reload, so this runs at startup and on each configreloaded.
  function applyBindings() {
    applyProc.running = false
    applyProc.running = true
  }

  Process {
    id: applyProc
    command: ["hyprctl", "eval", "dofile([==[" + root.runtimePath + "]==])"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = String(text || "").trim()
        if (out !== "" && out !== "ok") root.setStatus("Couldn't install shortcuts in Hyprland: " + out, true)
        bindsProc.running = true
      }
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && event.name === "configreloaded") root.applyBindings()
    }
  }

  Component.onCompleted: root.applyBindings()

  Process {
    id: bindsProc
    command: ["hyprctl", "binds"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.binds = root.parseBinds(text)
    }
  }

  // Classifies desktop entries (native / Flatpak / web app / ...) so
  // look-alike apps can be told apart. See scan-apps.sh.
  Process {
    id: scanProc
    command: ["bash", root.scanScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = ({})
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var f = lines[i].split("\t")
          if (f.length < 4 || !f[0]) continue
          next[f[0]] = { file: f[1], kind: f[2], location: f[3] }
        }
        root.appInfo = next
        if (root.opened) root.rebuild()
      }
    }
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var seen = ({})
        var out = []
        try {
          var list = JSON.parse(text)
          for (var i = 0; i < list.length; i++) {
            var c = String(list[i].class || "")
            if (!c || c === "org.quickshell" || seen[c]) continue
            seen[c] = true
            out.push(c)
          }
        } catch (e) {}
        out.sort()
        root.windowClasses = out
      }
    }
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadSettings(text())
    onLoadFailed: { root.settings = root.defaultSettings; settingsCreateProc.running = true }
    onFileChanged: reload()
  }

  // Create the settings file with documented defaults if it doesn't exist.
  Process {
    id: settingsCreateProc
    command: ["bash", "-c", "[ -e \"$1\" ] || printf '%s' \"$2\" > \"$1\"",
      "app-binder-settings", root.settingsPath, root.defaultSettingsText]
  }

  Process { id: settingsSaveProc }

  // Make sure the settings file exists, then open it in Omarchy's default editor.
  Process {
    id: settingsWriteProc
    command: ["bash", "-c", "[ -e \"$1\" ] || printf '%s' \"$2\" > \"$1\"; exec omarchy-launch-editor \"$1\"",
      "app-binder-settings", root.settingsPath, root.defaultSettingsText]
  }

  Timer {
    id: captureTimer
    interval: Math.max(5, root.setting("capture_timeout_seconds")) * 1000
    onTriggered: {
      root.endCapture()
      root.setStatus("Stopped waiting for a shortcut.", false)
    }
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { if (root.opened) { root.rebuild(); scanProc.running = true } }
  }


  // ---------------------------------------------------------------- settings rows

  // Label | Omarchy slider | value. Saves when the slider is released.
  component SliderRow: Item {
    id: sliderRow
    property string label: ""
    property string settingName: ""
    property real minimum: 0
    property real maximum: 1
    property real step: 1
    property bool integer: false
    property var format: function(v) { return String(v) }

    height: Math.max(Style.space(30), Style.font.body + Style.spacing.controlPaddingY * 2)

    function clean(v) {
      var snapped = Math.round(v / step) * step
      return integer ? Math.round(snapped) : Math.round(snapped * 100) / 100
    }

    Text {
      id: sliderLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(150)
      textFormat: Text.PlainText
      text: sliderRow.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
    Text {
      id: sliderValue
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(110)
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: sliderRow.format(sliderRow.clean(slider.liveValue))
      color: root.foreground
      opacity: 0.75
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    PanelSlider {
      id: slider
      anchors.left: sliderLabel.right
      anchors.right: sliderValue.left
      anchors.leftMargin: Style.spacing.md
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      height: parent.height
      minimum: sliderRow.minimum
      maximum: sliderRow.maximum
      step: sliderRow.step
      integer: sliderRow.integer
      value: Number(root.setting(sliderRow.settingName))
      trackColor: Style.selectedFillFor(root.foreground, Commons.Color.accent)
      fillColor: root.foreground
      knobColor: root.foreground
      tickColor: root.background
      onReleased: function(v) { root.updateSetting(sliderRow.settingName, sliderRow.clean(v)) }
    }
  }

  // Label | Omarchy switch. The whole row toggles.
  component SwitchRow: Item {
    id: switchRow
    property string label: ""
    property string settingName: ""
    readonly property bool checked: root.setting(settingName) === true

    height: Math.max(Style.space(30), Style.font.body + Style.spacing.controlPaddingY * 2)
    width: switchLabel.implicitWidth + Style.spacing.lg * 2 + toggle.width

    Text {
      id: switchLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: switchRow.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
    ToggleSwitch {
      id: toggle
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: switchRow.checked
      foreground: root.foreground
      onToggled: root.updateSetting(switchRow.settingName, !switchRow.checked)
    }
  }

  // ---------------------------------------------------------------- UI

  PanelWindow {
    id: panel
    visible: root.opened
    // No anchors: a card-sized surface centred on the monitor, no backdrop, so
    // every other window (on either monitor) stays clickable while it's open.
    implicitWidth: root.cardWidth
    implicitHeight: root.cardHeight
    color: "transparent"
    WlrLayershell.namespace: "cantcode-app-binder"
    WlrLayershell.layer: WlrLayer.Overlay
    // OnDemand: keyboard goes to App Binder when clicked and to any other
    // window you click. (Exclusive would hold the keyboard while open.)
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

    // Click-away to close, the same mechanism Omarchy's popups use: while
    // open, Hyprland routes input to App Binder; the first click anywhere
    // else clears the grab and we close. It also hands App Binder the
    // keyboard on open, so typing and scrolling work without a first click.
    HyprlandFocusGrab {
      active: root.opened && root.setting("close_on_click_outside") === true
      windows: [panel]
      onCleared: if (root.opened) root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea {
        anchors.fill: parent
        onClicked: if (root.editingMatchId === "") keyCatcher.forceActiveFocus()
      }

      // Faster wheel scrolling than Qt's default (~1 row per notch).
      // A wheel-only layer ON TOP of the list (the ListView itself is
      // non-interactive, so Qt's own wheel scrolling can't compete).
      // NoButton: clicks and hover pass straight through to the rows.
      // Touchpads report pixelDelta and keep their natural 1:1 feel.
      MouseArea {
        id: wheelCatcher
        z: 10
        x: content.x + table.x
        y: content.y + table.y
        width: table.width
        height: table.height
        acceptedButtons: Qt.NoButton
        onWheel: function(wheel) {
          // Always scroll by notches (angleDelta, 120 per notch). Wayland mouse
          // wheels also report pixelDelta, so preferring it would ignore the
          // rows-per-notch setting.
          var dy = wheel.angleDelta.y / 120 * root.rowHeight * root.wheelRowsPerNotch
          var maxY = table.originY + Math.max(0, table.contentHeight - table.height)
          // Glide: keep adding to the running animation's destination, so a
          // fast flurry of notches becomes one continuous ease-out.
          var base = scrollGlide.running ? scrollGlide.to : table.contentY
          var dest = Math.max(table.originY, Math.min(maxY, base - dy))
          wheel.accepted = true
          var ms = Math.max(0, Number(root.setting("scroll_glide_ms")))
          scrollGlide.stop()
          if (ms === 0) { table.contentY = dest; return }
          scrollGlide.duration = ms
          scrollGlide.from = table.contentY
          scrollGlide.to = dest
          scrollGlide.start()
        }
      }

      NumberAnimation {
        id: scrollGlide
        target: table
        property: "contentY"
        easing.type: Easing.OutCubic
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        // Clicking another window mid-recording ends the recording, so
        // Hyprland's shortcuts never stay paused behind your back.
        onActiveFocusChanged: if (!activeFocus && root.captureId !== "") {
          root.endCapture()
          root.setStatus("Recording stopped: focus moved to another window.", false)
        }

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.captureId !== "") { root.handleCaptureKey(event); return }
          var row = root.rows[root.selectedIndex]
          var k = event.key
          var mods = event.modifiers & (Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier)
          if (k === Qt.Key_Escape) {
            if (root.filterText) { root.filterText = ""; root.rebuild() }
            else root.dismiss()
          } else if (k === Qt.Key_Down) root.select(root.selectedIndex + 1)
          else if (k === Qt.Key_Up) root.select(root.selectedIndex - 1)
          else if (k === Qt.Key_PageDown) root.select(root.selectedIndex + Math.max(1, Math.floor(table.height / root.rowHeight)))
          else if (k === Qt.Key_PageUp) root.select(root.selectedIndex - Math.max(1, Math.floor(table.height / root.rowHeight)))
          else if (k === Qt.Key_Return || k === Qt.Key_Enter) { if (row) root.startCapture(row.id) }
          else if (k === Qt.Key_Right) { if (row) root.cycleDesktop(row.id, 1) }
          else if (k === Qt.Key_Left) { if (row) root.cycleDesktop(row.id, -1) }
          else if (k === Qt.Key_Delete) {
            if (row && row.keys) {
              root.setApp(row.id, { keys: "", label: "" })
              root.setStatus("Cleared the shortcut for " + row.name, false)
            }
          } else if (k === Qt.Key_Backspace) {
            if (root.filterText) { root.filterText = root.filterText.slice(0, -1); root.rebuild() }
          } else if (mods === 0 && event.text && event.text.length === 1
                     && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.filterText += event.text
            root.selectedId = ""
            root.rebuild()
          } else {
            return
          }
          event.accepted = true
        }
      }

      Column {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        // Header: title row + Settings section. Zero spacing here so the gap
        // above Settings lives inside it (topPadding) and animates with it.
        Column {
          width: parent.width
          spacing: 0

        // Title + filter
        Item {
          width: parent.width
          height: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)

          Text {
            id: title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "App Binder"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
          // Settings cog: shows/hides the Settings section below.
          Button {
            id: cog
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\uf013"
            tooltipText: root.settingsOpen ? "Hide settings" : "Settings"
            selected: root.settingsOpen
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconSize: Style.font.heading
            // Spins forward as Settings opens, back as it closes.
            iconRotation: root.settingsOpen ? 180 : 0
            Behavior on iconRotation {
              enabled: root.animateSettings
              NumberAnimation { duration: 380; easing.type: Easing.OutCubic }
            }
            onClicked: root.settingsOpen = !root.settingsOpen
          }
          Text {
            anchors.left: title.right
            anchors.leftMargin: Style.spacing.lg
            anchors.right: cog.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.filterText || "Type to filter apps…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        // Settings (cog): sliders/switches that write app-binder-settings.jsonc.
        Column {
          id: settingsSection
          width: parent.width
          spacing: Style.spacing.md
          // Slides open/closed: height animates between 0 and its content,
          // with a fade; clipped so nothing spills while it moves.
          clip: true
          topPadding: Style.spacing.md
          height: root.settingsOpen ? implicitHeight : 0
          opacity: root.settingsOpen ? 1 : 0
          Behavior on height {
            enabled: root.animateSettings
            NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
          }
          Behavior on opacity {
            enabled: root.animateSettings
            NumberAnimation { duration: 200 }
          }

          Item {
            width: parent.width
            height: editButton.implicitHeight
            PanelSectionHeader {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Settings"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Button {
              id: editButton
              anchors.right: parent.right
              text: "Edit app-binder-settings.jsonc directly"
              iconText: "\uf044"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: {
                // Close first so the editor isn't hidden behind App Binder.
                root.dismiss()
                root.openSettingsFile()
              }
            }
          }

          Grid {
            id: settingsGrid
            width: parent.width
            columns: 2
            columnSpacing: Style.spacing.xl
            rowSpacing: Style.spacing.sm
            readonly property real cellWidth: (width - columnSpacing) / 2

            SliderRow {
              width: settingsGrid.cellWidth
              label: "Scroll per notch"
              settingName: "scroll_rows_per_notch"
              minimum: 0.25; maximum: 4; step: 0.25
              format: function(v) { return v + (v === 1 ? " row" : " rows") }
            }
            SliderRow {
              width: settingsGrid.cellWidth
              label: "Scroll glide"
              settingName: "scroll_glide_ms"
              minimum: 0; maximum: 400; step: 20; integer: true
              format: function(v) { return v === 0 ? "off" : v + " ms" }
            }
            SliderRow {
              width: settingsGrid.cellWidth
              label: "Window width"
              settingName: "window_width"
              minimum: 700; maximum: 1800; step: 50; integer: true
              format: function(v) { return v + " px" }
            }
            SliderRow {
              width: settingsGrid.cellWidth
              label: "Window height"
              settingName: "window_height"
              minimum: 400; maximum: 1300; step: 20; integer: true
              format: function(v) { return v + " px" }
            }
            SliderRow {
              width: settingsGrid.cellWidth
              label: "Recording timeout"
              settingName: "capture_timeout_seconds"
              minimum: 5; maximum: 60; step: 5; integer: true
              format: function(v) { return v + " s" }
            }
          }

          // Switches on their own line, apart from the sliders. Each sizes to
          // its label; the Flow wraps them if the window is made narrow.
          Flow {
            width: parent.width
            spacing: Style.spacing.xl * 4
            SwitchRow {
              label: "Number key sets that desktop"
              settingName: "auto_desktop_number_keys"
            }
            SwitchRow {
              label: "Other keys pick first free desktop"
              settingName: "auto_desktop_other_keys"
            }
            SwitchRow {
              label: "Click outside to close"
              settingName: "close_on_click_outside"
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }
        }

        } // header

        // Column headings
        Row {
          width: parent.width
          height: Style.font.body + Style.spacing.sm
          opacity: 0.55
          Text {
            width: parent.width - root.shortcutWidth - root.desktopWidth - root.matchWidth
            text: "App"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body
            leftPadding: root.iconSize + Style.spacing.md + Style.spacing.sm
          }
          Text { width: root.shortcutWidth; text: "Shortcut"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
          Text { width: root.desktopWidth; text: "Desktop"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
          Text { width: root.matchWidth; text: "Window class"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
        }

        ListView {
          id: table
          width: parent.width
          height: parent.height - y - footer.height - Style.spacing.md
          clip: true
          model: root.rows
          boundsBehavior: Flickable.StopAtBounds
          // Non-interactive: Qt's own wheel/drag scrolling is off so the card's
          // WheelHandler (above) controls the speed. Keyboard and code scrolling
          // (positionViewAtIndex, contentY) still work.
          interactive: false

          // Rows use Omarchy's CursorSurface (same as the audio panel): the
          // highlighted row gets the theme's hover fill plus its thin border.
          delegate: CursorSurface {
            id: rowItem
            required property int index
            required property var modelData
            readonly property bool isSelected: index === root.selectedIndex
            readonly property bool isCapturing: root.captureId === modelData.id
            readonly property bool isEditing: root.editingMatchId === modelData.id

            width: table.width
            height: root.rowHeight
            hasCursor: isSelected
            foreground: root.foreground
            readonly property color textColor: root.foreground

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onContainsMouseChanged: if (containsMouse && root.captureId === "" && root.editingMatchId === "") {
                root.selectedIndex = rowItem.index
                root.selectedId = rowItem.modelData.id
              }
              onClicked: { root.select(rowItem.index); root.startCapture(rowItem.modelData.id) }
            }

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.sm

              // App
              Item {
                width: parent.width - root.shortcutWidth - root.desktopWidth - root.matchWidth - Style.spacing.sm
                height: parent.height
                Image {
                  id: appIcon
                  anchors.verticalCenter: parent.verticalCenter
                  width: root.iconSize; height: root.iconSize
                  sourceSize.width: root.iconSize; sourceSize.height: root.iconSize
                  source: root.iconFor(rowItem.modelData.icon)
                  asynchronous: true
                  smooth: true
                  onStatusChanged: if (status === Image.Error)
                    source = Quickshell.iconPath("application-x-executable", true)
                }
                Column {
                  anchors.left: appIcon.right
                  anchors.leftMargin: Style.spacing.md
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.md
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.xs

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: rowItem.modelData.name + (rowItem.modelData.missing ? "  (not installed)" : "")
                    color: rowItem.textColor
                    opacity: rowItem.modelData.missing ? 0.5 : 1
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                    elide: Text.ElideRight
                  }

                  // Type · location. Click copies the location (e.g. to
                  // uninstall a duplicate).
                  Text {
                    id: whereText
                    width: Math.min(parent.width, implicitWidth)
                    visible: rowItem.modelData.kindLabel !== ""
                    textFormat: Text.PlainText
                    text: rowItem.modelData.kindLabel + " · " + root.tildePath(rowItem.modelData.location)
                    color: rowItem.textColor
                    opacity: whereMouse.containsMouse ? 0.95 : (rowItem.modelData.kind === "broken" ? 0.8 : 0.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.underline: whereMouse.containsMouse
                    font.bold: rowItem.modelData.kind === "broken"
                    elide: Text.ElideMiddle
                    MouseArea {
                      id: whereMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.copyText(rowItem.modelData.location)
                    }
                  }
                }
              }

              // Shortcut
              Item {
                width: root.shortcutWidth
                height: parent.height
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.spacing.md
                  height: root.pillHeight
                  radius: root.cornerRadius
                  color: "transparent"
                  border.width: rowItem.isCapturing ? Math.max(1, Style.space(2)) : (rowItem.modelData.keys ? 1 : 0)
                  border.color: rowItem.textColor
                  opacity: rowItem.isCapturing ? 1 : (rowItem.modelData.keys ? 0.9 : 0.35)
                  Text {
                    anchors.centerIn: parent
                    width: parent.width - Style.spacing.md
                    horizontalAlignment: Text.AlignHCenter
                    textFormat: Text.PlainText
                    text: rowItem.isCapturing
                      ? (root.pendingCapture ? root.pendingCapture.label + " ?" : "press keys…")
                      : (rowItem.modelData.label || "—")
                    color: rowItem.textColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: rowItem.isCapturing
                    elide: Text.ElideRight
                  }
                }
              }

              // Desktop
              Item {
                width: root.desktopWidth
                height: parent.height
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.spacing.md
                  height: root.pillHeight
                  radius: root.cornerRadius
                  color: "transparent"
                  border.width: 1
                  border.color: rowItem.textColor
                  opacity: rowItem.modelData.desktop > 0 ? 0.9 : 0.35
                  Text {
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: rowItem.modelData.desktop > 0 ? String(rowItem.modelData.desktop) : "Any"
                    color: rowItem.textColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: function(mouse) {
                      root.endCapture()
                      root.select(rowItem.index)
                      root.cycleDesktop(rowItem.modelData.id, mouse.button === Qt.RightButton ? -1 : 1)
                    }
                    // No wheel handler: scrolling the list must never change desktops.
                    onWheel: function(wheel) { wheel.accepted = false }
                  }
                }
              }

              // Window class (match)
              Item {
                width: root.matchWidth
                height: parent.height
                Text {
                  visible: !rowItem.isEditing
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: rowItem.modelData.match
                  color: rowItem.textColor
                  opacity: rowItem.modelData.match === rowItem.modelData.defaultMatch ? 0.45 : 0.95
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideMiddle
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.IBeamCursor
                    onClicked: { root.select(rowItem.index); root.startEditMatch(rowItem.modelData.id) }
                  }
                }
                Rectangle {
                  visible: rowItem.isEditing
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.spacing.sm
                  height: root.pillHeight
                  radius: root.cornerRadius
                  color: "transparent"
                  border.width: Math.max(1, Style.space(2))
                  border.color: rowItem.textColor
                  TextInput {
                    id: matchInput
                    anchors.fill: parent
                    anchors.leftMargin: Style.spacing.sm
                    anchors.rightMargin: Style.spacing.sm
                    verticalAlignment: TextInput.AlignVCenter
                    color: rowItem.textColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    clip: true
                    onVisibleChanged: if (visible) {
                      text = rowItem.modelData.match
                      selectAll()
                      forceActiveFocus()
                    }
                    Keys.onPressed: function(event) {
                      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.commitMatch(rowItem.modelData.id, text)
                        event.accepted = true
                      } else if (event.key === Qt.Key_Escape) {
                        root.editingMatchId = ""
                        root.setStatus("", false)
                        keyCatcher.forceActiveFocus()
                        event.accepted = true
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // Footer: open-window class chips while editing, status, key help
        Column {
          id: footer
          width: parent.width
          spacing: Style.spacing.sm

          Flow {
            width: parent.width
            spacing: Style.spacing.sm
            visible: root.editingMatchId !== "" && root.windowClasses.length > 0
            Text {
              text: "Open windows:"
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Repeater {
              model: root.windowClasses
              delegate: Rectangle {
                required property string modelData
                width: chipText.implicitWidth + Style.spacing.md * 2
                height: chipText.implicitHeight + Style.spacing.xs * 2
                radius: root.cornerRadius
                color: chipMouse.containsMouse ? root.selectedBackground : "transparent"
                border.width: 1
                border.color: root.foreground
                Text {
                  id: chipText
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: parent.modelData
                  color: chipMouse.containsMouse ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                MouseArea {
                  id: chipMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.commitMatch(root.editingMatchId, parent.modelData)
                }
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.status
            visible: root.status !== ""
            color: root.foreground
            opacity: root.statusError ? 1 : 0.85
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: root.statusError
            wrapMode: Text.Wrap
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "Click or ↵ set shortcut · ←/→ or click desktop · click class to edit · Del clear · type to filter · Esc close"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
