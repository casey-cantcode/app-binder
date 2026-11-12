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
// For Hyprland: $XDG_RUNTIME_DIR/app-binder-bindings.txt, plain data read by
// hypr/app-binder.lua, which this plugin runs inside Hyprland (hyprctl eval)
// at startup, after every config reload, and when shortcuts change. No
// hyprland.lua edits needed.
//
// Anything that could block (reading files other programs write, /proc,
// scanning apps) happens here or in the helper scripts, never inside
// Hyprland. Every input is bounded and validated before use.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  readonly property string pluginId: (manifest && manifest.id) || "cantcode.app-binder"
  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/app-binder.json"
  // Shared with hypr/app-binder.lua. tmpfs, private to the user.
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string bindingsPath: runtimeDir ? runtimeDir + "/app-binder-bindings.txt" : ""
  readonly property string pendingPath: runtimeDir ? runtimeDir + "/app-binder-pending.txt" : ""
  // Files earlier versions wrote, removed at startup.
  readonly property var obsoletePaths: [
    home + "/.config/omarchy/app-binder-data.lua",
    home + "/.config/hypr/app-binder-data.lua",
    (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/app-binder-learned.lua",
    (Quickshell.env("XDG_RUNTIME_DIR") || "/nonexistent") + "/app-binder-launching.lua"
  ]
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
  // The settings file is hand-editable, so numbers are kept to the ranges
  // the Settings sliders allow.
  readonly property var settingRanges: ({
    scroll_rows_per_notch: [0.25, 4],
    scroll_glide_ms: [0, 400],
    window_width: [700, 1800],
    window_height: [400, 1300],
    capture_timeout_seconds: [5, 60]
  })

  function setting(name) {
    var v = root.settings ? root.settings[name] : undefined
    var d = root.defaultSettings[name]
    if (v === undefined || v === null || typeof v !== typeof d) return d
    var r = root.settingRanges[name]
    if (r) return isFinite(v) ? Math.min(r[1], Math.max(r[0], v)) : d
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
  // True while the settings file has an error: the Settings sliders then
  // don't save over your edits.
  property bool settingsUnreadable: false
  property bool animateSettings: true

  // Change one setting from the Settings section and save the file.
  function updateSetting(name, value) {
    var next = ({})
    for (var k in root.defaultSettings) next[k] = root.setting(k)
    next[name] = value
    if (root.settingsUnreadable) {
      root.setStatus("Not saved: the settings file has an error. Fix it, or delete it to get the defaults back.", true)
      return
    }
    root.settings = next
    settingsFile.setText(root.settingsText(next))
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
      root.settingsUnreadable = false
      root.settings = next
      if (changed && root.opened)
        root.setStatus("Settings updated (scroll: " + root.wheelRowsPerNotch + " rows per notch).", false)
    } catch (e) {
      root.settings = root.defaultSettings
      root.settingsUnreadable = true
      root.setStatus("Settings file has an error, using defaults: " + e, true)
    }
  }

  // "Edit ... directly": the file exists (created on first load), so open it
  // the way Omarchy opens config files.
  function openSettingsFile() {
    Quickshell.execDetached(["omarchy-launch-config-editor", root.settingsPath])
  }

  // id -> { name, keys, label, match, desktop }. Maps keyed by app IDs are
  // made with Object.create(null), so an ID like "constructor" is just an ID.
  property var apps: Object.create(null)
  property var binds: []
  property var windowClasses: []
  // Window classes that many unrelated apps share, so a class alone can't
  // tell them apart.
  readonly property var sharedClasses: ["steam_app_default"]
  // desktop id -> { file, kind, location } from scan-apps.sh
  property var appInfo: Object.create(null)
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
  // The window match being edited. App Binder handles the typing itself
  // rather than using a Qt text field: in current Qt, every editable text
  // field reads the clipboard whenever it changes, with no size limit or
  // timeout, which a misbehaving clipboard owner could use to stall the
  // shell. This editor never touches the clipboard.
  property string matchDraft: ""
  property int matchCursor: 0
  property bool matchAllSelected: false
  readonly property int matchMaxLength: 256
  property string status: ""
  property bool statusError: false
  // A problem that leaves shortcuts not working. It stays visible (open()
  // shows it again) and, when App Binder is closed, is sent as a
  // notification once, until it's resolved.
  property string stickyError: ""
  // What App Binder last wrote, so its own writes aren't read back as edits.
  property string lastConfigText: ""
  // True if app-binder.json exists but couldn't be read: App Binder then
  // never saves over it (like Omarchy's own shell.json handling).
  property bool configUnreadable: false

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
    root.setStatus(root.stickyError, root.stickyError !== "")
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
    if (saveTimer.running) root.saveNow()
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


  // ---------------------------------------------------------------- rows

  function defaultMatch(entry, id) {
    var cls = entry && entry.startupClass ? String(entry.startupClass) : ""
    return cls.length > 0 ? cls : id
  }

  // A row's icon. An absolute icon path is used only if scan-apps.sh vouched
  // for it (a regular, readable file of sane size): a named pipe handed to
  // the image loader would stall image loading for the whole shell.
  function iconFor(icon, id) {
    var value = String(icon || "")
    if (value.length === 0) return Quickshell.iconPath("application-x-executable", true)
    if (value.charAt(0) === "/") {
      var info = root.appInfo[id]
      if (!info || info.icon !== value) return Quickshell.iconPath("application-x-executable", true)
      return "file://" + value.split("/").map(encodeURIComponent).join("/")
    }
    // Anything else must be a plain theme icon name: "../" or other path
    // parts would let the theme lookup reach an arbitrary file.
    if (!/^[A-Za-z0-9][A-Za-z0-9._+-]{0,254}$/.test(value)) return Quickshell.iconPath("application-x-executable", true)
    var themed = Quickshell.iconPath(value, true)
    return themed.length > 0 ? themed : Quickshell.iconPath("application-x-executable", true)
  }

  function rebuild() {
    var values = DesktopEntries.applications.values || []
    var seen = Object.create(null)
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

  readonly property int maxApps: 1000
  readonly property var keysPattern: /^[A-Za-z0-9 +:_]+$/

  // One app's saved settings, with every field checked: the file is
  // hand-editable and anything unexpected is dropped rather than trusted.
  function cleanApp(a) {
    if (!a || typeof a !== "object" || Array.isArray(a)) return null
    function str(v, max) { return typeof v === "string" ? v.slice(0, max) : "" }
    var out = {
      name: str(a.name, 256),
      keys: str(a.keys, 128),
      label: str(a.label, 64),
      match: str(a.match, root.matchMaxLength),
      desktop: 0,
      desktopAuto: a.desktopAuto === true
    }
    if (out.keys !== "" && !root.keysPattern.test(out.keys)) { out.keys = ""; out.label = "" }
    var d = Number(a.desktop)
    if (d === Math.floor(d) && d >= 0 && d <= 10) out.desktop = d
    // Missing (not empty) means "saved before 0.2.0": migrateReplaces fills it.
    if (Array.isArray(a.replaces)) {
      out.replaces = a.replaces.filter(function(c) {
        return typeof c === "string" && c.length <= 128 && root.keysPattern.test(c)
      }).slice(0, 16)
    }
    return out
  }

  function loadConfig(text, missing) {
    if (text === root.lastConfigText && !missing) return // our own save, read back
    var next = Object.create(null)
    var dropped = 0
    try {
      var parsed = missing ? {} : JSON.parse(text)
      var apps = parsed && typeof parsed === "object" && parsed.apps && typeof parsed.apps === "object" ? parsed.apps : {}
      var ids = Object.keys(apps)
      for (var i = 0; i < ids.length; i++) {
        var id = ids[i]
        var clean = (Object.keys(next).length < root.maxApps && id.length > 0 && id.length <= 256
          && !/[\u0000-\u001f\u007f]/.test(id)) ? root.cleanApp(apps[id]) : null
        if (clean) next[id] = clean
        else dropped++
      }
      root.configUnreadable = false
    } catch (e) {
      root.configUnreadable = true
      root.reportProblem("Couldn't read " + root.configPath + " (" + e + "). Shortcuts are off, and App Binder won't save over the file until it's fixed.")
    }
    if (!root.configUnreadable) {
      root.clearProblem()
      root.apps = next
      if (dropped > 0) root.setStatus("Ignored " + dropped + " damaged entries in " + root.configPath + ".", true)
      root.writeBindings()
    }
    if (root.opened) root.rebuild()
  }

  // Merge `patch` into one app's settings and save.
  function setApp(id, patch) {
    var row = root.rowById(id)
    var next = Object.create(null)
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
    var next = Object.create(null)
    var cleared = []
    for (var k in root.apps) {
      var a = root.apps[k]
      if (k !== exceptId && a.keys === keys) {
        var copy = JSON.parse(JSON.stringify(a))
        copy.keys = ""
        copy.label = ""
        copy.replaces = []
        next[k] = copy
        cleared.push(a.name || k)
      } else {
        next[k] = a
      }
    }
    root.apps = next
    return cleared
  }

  // ------------------------------------------------- data for Hyprland

  // Text with every unpaired surrogate replaced by U+FFFD, so it always
  // encodes (encodeURIComponent throws on an unpaired surrogate).
  function wellFormed(str) {
    var out = ""
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i)
      if (c >= 0xD800 && c <= 0xDBFF) {
        var n = i + 1 < str.length ? str.charCodeAt(i + 1) : 0
        if (n >= 0xDC00 && n <= 0xDFFF) { out += str.charAt(i) + str.charAt(i + 1); i++ }
        else out += "�"
      } else if (c >= 0xDC00 && c <= 0xDFFF) {
        out += "�"
      } else {
        out += str.charAt(i)
      }
    }
    return out
  }

  // A field for the bindings file: "=" plus the text percent-encoded, so it
  // never holds a space or newline. hypr/app-binder.lua decodes it as data.
  function field(v) { return "=" + encodeURIComponent(root.wellFormed(String(v))) }
  // A list: its items' fields joined by commas ("=a,=,=b"), "=" when empty.
  function fieldList(list) {
    if (list.length === 0) return "="
    return list.map(function(v) { return root.field(v) }).join(",")
  }

  // Lowercase letters and digits only ("Vintage Story" -> "vintagestory").
  function squash(str) { return String(str).toLowerCase().replace(/[^a-z0-9]/g, "") }

  // Names that identify an app: its ID, its name, and its name without a
  // trailing version ("Vintage Story 1.21.0" -> "Vintage Story").
  function nameKeys(id, name) {
    var keys = [root.squash(id), root.squash(name), root.squash(name.replace(/\s+v?\d[\w.\-]*$/, ""))]
    return keys.filter(function(k, i) { return k !== "" && keys.indexOf(k) === i })
  }

  // The command a terminal app runs, the way Omarchy's launcher does it (it
  // goes through omarchy-launch-tui), or [] for any other app.
  function terminalCommand(id) {
    var entry = DesktopEntries.byId(id)
    if (!entry || !entry.runInTerminal) return []
    return (entry.command || []).map(function(w) { return String(w) })
      .filter(function(w) { return !/^%[a-zA-Z]$/.test(w) && w.length <= 4096 }).slice(0, 64)
  }

  // The bindings file: one line per bound app, plain data.
  //   B id name keys match desktop steam_id terminal-command replaces names
  function buildBindings() {
    var lines = []
    var ids = Object.keys(root.apps).sort()
    for (var i = 0; i < ids.length; i++) {
      var id = ids[i]
      var a = root.apps[id]
      if (!a.keys) continue
      var name = (a.name || id).slice(0, 256)
      var info = root.appInfo[id]
      var steam = info && info.kind === "steam" ? String(info.location || "").match(/rungameid\/(\d{1,20})$/) : null
      lines.push(["B", root.field(id), root.field(name), root.field(a.keys),
        root.field((a.match || id).slice(0, root.matchMaxLength)), root.field(a.desktop || 0),
        root.field(steam ? steam[1] : ""), root.fieldList(root.terminalCommand(id)),
        root.fieldList(a.replaces || []), root.fieldList(root.nameKeys(id, name))].join(" "))
    }
    return lines.join("\n") + "\n"
  }

  // Combos taken over in a bindings file's text.
  function replacesIn(text) {
    var out = []
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var t = lines[i].split(" ")
      if (t[0] !== "B" || !t[8] || t[8] === "=") continue
      var items = t[8].split(",")
      for (var j = 0; j < items.length; j++) {
        try { if (items[j].length > 1) out.push(decodeURIComponent(items[j].slice(1))) } catch (e) {}
      }
    }
    return out
  }

  property string lastBindingsText: ""
  property var lastReplaces: []
  property bool reloadAfterWrite: false

  // Write the bindings file if it changed, then have Hyprland pick it up.
  // A full Hyprland reload only when a taken-over binding was released, the
  // one case where Hyprland has to restore its original binding.
  function writeBindings() {
    if (!root.bindingsPath || root.configUnreadable) return
    var text = root.buildBindings()
    if (text === root.lastBindingsText) return
    var now = root.replacesIn(text)
    root.reloadAfterWrite = root.lastReplaces.some(function(c) { return now.indexOf(c) === -1 })
    root.lastReplaces = now
    root.lastBindingsText = text
    bindingsFile.setText(text)
  }

  // Saves are batched: holding a key that changes a row saves once.
  function save() { saveTimer.restart() }

  function saveNow() {
    saveTimer.stop()
    if (root.configUnreadable) {
      root.setStatus("Not saved: " + root.configPath + " couldn't be read. Fix or remove it first.", true)
      return
    }
    var json = JSON.stringify({ version: 1, apps: root.apps }, null, 2) + "\n"
    if (json !== root.lastConfigText) {
      root.lastConfigText = json
      configFile.setText(json)
    }
    root.writeBindings()
  }

  Timer {
    id: saveTimer
    interval: 300
    onTriggered: root.saveNow()
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
    Hyprland.dispatch("hl.dsp.submap('appbinder')")
    captureTimer.restart()
    var row = root.rowById(id)
    root.setStatus("Press the shortcut for " + (row ? row.name : id) + "…   Esc cancels · Backspace clears", false)
  }

  function endCapture() {
    if (root.captureId === "") return
    root.captureId = ""
    root.pendingCapture = null
    captureTimer.stop()
    Hyprland.dispatch("hl.dsp.submap('reset')")
    // Make sure recording mode really ended: if Hyprland is somehow still in
    // it, every shortcut would stay dead.
    submapCheck.restart()
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
        combo: root.comboFor(Number(b.modmask), keyPart),
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

  // Hyprland's spelling of a binding ("SUPER + CTRL + B"), rebuilt from its
  // modmask because `hyprctl binds` lists some keys without their modifiers.
  // This is the string hl.unbind needs to remove that exact binding.
  function comboFor(mask, keyPart) {
    var names = []
    if (mask & 64) names.push("SUPER")
    if (mask & 4) names.push("CTRL")
    if (mask & 8) names.push("ALT")
    if (mask & 1) names.push("SHIFT")
    names.push(keyPart)
    return names.join(" + ")
  }

  // Every non-App Binder binding on this combo. A binding can be registered
  // by key name ("B") or by key code ("code:56"), so both are checked.
  function conflictsFor(mask, keycode, label) {
    var found = []
    for (var i = 0; i < root.binds.length; i++) {
      var b = root.binds[i]
      if (!b || b.mouse || b.submap !== "") continue
      if (b.description.indexOf("App Binder:") === 0) continue
      if (b.modmask !== mask) continue
      var sameCode = b.keycode !== 0 && b.keycode === keycode
      var sameName = b.keycode === 0 && b.key.toUpperCase() === label.toUpperCase()
      if (sameCode || sameName) found.push(b)
    }
    return found
  }

  function keycodeOf(keys) {
    var m = String(keys || "").match(/code:(\d+)$/)
    return m ? Number(m[1]) : 0
  }

  function bindTitle(b) {
    return b.description || (b.dispatcher + " " + b.arg)
  }

  function maskOf(keys) {
    var mask = 0
    var parts = String(keys || "").toUpperCase().split("+")
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i].trim()
      if (p === "SUPER") mask |= 64
      else if (p === "CTRL") mask |= 4
      else if (p === "ALT") mask |= 8
      else if (p === "SHIFT") mask |= 1
    }
    return mask
  }

  // Shortcuts saved before 0.2.0 have no `replaces` list, so a binding they
  // took over (e.g. Omarchy's Super+Ctrl+B Bluetooth) kept firing alongside
  // them. Taking it over always required confirming, so record it now.
  function migrateReplaces() {
    var next = Object.create(null)
    var changed = false
    for (var k in root.apps) {
      var a = root.apps[k]
      if (a.keys && a.replaces === undefined) {
        var copy = JSON.parse(JSON.stringify(a))
        var keyName = String(a.label || "").split("+").pop()
        var hits = root.conflictsFor(root.maskOf(a.keys), root.keycodeOf(a.keys), keyName)
        copy.replaces = hits.map(function(b) { return b.combo })
        next[k] = copy
        changed = true
      } else {
        next[k] = a
      }
    }
    if (!changed) return
    root.apps = next
    root.save()
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
      root.setApp(id, { keys: "", label: "", replaces: [] })
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
      label: labels.join("+") + "+" + keyName,
      replaces: []
    }
    var taken = root.conflictsFor(mask, keycode, keyName)
    if (taken.length > 0) {
      capture.replaces = taken.map(function(b) { return b.combo })
      root.pendingCapture = capture
      root.setStatus(capture.label + " is currently “" + taken.map(root.bindTitle).join("”, “")
        + "”.   Enter takes it over · Esc picks another", true)
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
    var patch = { keys: capture.keys, label: capture.label, replaces: capture.replaces }
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
    var row = root.rowById(id)
    root.matchDraft = row ? String(row.match || "").slice(0, root.matchMaxLength) : ""
    root.matchCursor = root.matchDraft.length
    root.matchAllSelected = true
    root.editingMatchId = id
    clientsProc.running = true
    keyCatcher.forceActiveFocus()
    root.setStatus("Pick the app's window below, or type a window class, optionally followed by title:<window title>. Use * as a wildcard. Enter saves · Esc cancels", false)
  }

  function cancelEditMatch() {
    root.editingMatchId = ""
    root.setStatus("", false)
    keyCatcher.forceActiveFocus()
  }

  // Typing in the window match editor. Plain keys only: no paste.
  function handleMatchKey(event) {
    event.accepted = true
    var k = event.key
    var mods = event.modifiers & (Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier)
    var d = root.matchDraft
    var c = root.matchCursor
    var all = root.matchAllSelected
    if (k === Qt.Key_Return || k === Qt.Key_Enter) { root.commitMatch(root.editingMatchId, d); return }
    if (k === Qt.Key_Escape) { root.cancelEditMatch(); return }
    if (mods === Qt.ControlModifier && k === Qt.Key_A) { root.matchAllSelected = true; return }
    if (k === Qt.Key_Left) { c = all ? 0 : Math.max(0, c - 1); all = false }
    else if (k === Qt.Key_Right) { c = all ? d.length : Math.min(d.length, c + 1); all = false }
    else if (k === Qt.Key_Home) { c = 0; all = false }
    else if (k === Qt.Key_End) { c = d.length; all = false }
    else if (k === Qt.Key_Backspace) {
      if (all) { d = ""; c = 0; all = false }
      else if (c > 0) { d = d.slice(0, c - 1) + d.slice(c); c-- }
    } else if (k === Qt.Key_Delete) {
      if (all) { d = ""; c = 0; all = false }
      else if (c < d.length) d = d.slice(0, c) + d.slice(c + 1)
    } else if (mods === 0 && event.text && event.text.length === 1
               && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
      if (all) { d = ""; c = 0; all = false }
      if (d.length >= root.matchMaxLength) return
      d = d.slice(0, c) + event.text + d.slice(c)
      c++
    } else {
      return // anything else, including Ctrl+V, does nothing
    }
    root.matchDraft = d
    root.matchCursor = c
    root.matchAllSelected = all
  }

  function commitMatch(id, value) {
    var row = root.rowById(id)
    var v = String(value || "").trim().slice(0, root.matchMaxLength)
    if (v === "" && row) v = row.defaultMatch
    root.editingMatchId = ""
    root.setApp(id, { match: v })
    root.setStatus((row ? row.name : id) + " matches windows: “" + v + "”", false)
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

  function reportProblem(text) {
    if (text === root.stickyError) return
    root.stickyError = text
    root.setStatus(text, true)
    if (!root.opened) Quickshell.execDetached(["omarchy-notification-send", "App Binder", text])
  }

  function clearProblem() {
    if (root.stickyError === "") return
    if (root.status === root.stickyError) root.setStatus("", false)
    root.stickyError = ""
  }

  // ---------------------------------------------------------------- IO

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadConfig(text(), false)
    onLoadFailed: function(error) {
      if (error === FileViewError.FileNotFound) root.loadConfig("", true)
      else {
        root.configUnreadable = true
        root.reportProblem("Couldn't read " + root.configPath + ". Shortcuts are off, and App Binder won't save over the file until it's fixed.")
      }
    }
    onFileChanged: reload()
    onSaveFailed: root.setStatus("Couldn't save " + root.configPath + ".", true)
  }

  // ------------------------------------------------ install shortcuts in Hyprland

  // The plain-data file hypr/app-binder.lua reads.
  FileView {
    id: bindingsFile
    path: root.bindingsPath
    atomicWrites: true
    printErrors: false
    // What Hyprland has from an earlier run, so a released takeover is noticed.
    onLoaded: root.lastReplaces = root.replacesIn(text())
    onSaved: {
      if (root.reloadAfterWrite) { root.reloadAfterWrite = false; reloadProc.running = true }
      else root.applyBindings()
    }
    onSaveFailed: root.reportProblem("Couldn't write " + root.bindingsPath + ", so shortcut changes can't reach Hyprland.")
  }

  // Run hypr/app-binder.lua inside Hyprland. Runtime bindings are wiped by
  // every config reload, so this runs at startup, on each configreloaded, and
  // after the bindings file changes.
  function applyBindings() {
    if (/\]==\]|[\u0000-\u001f]/.test(root.runtimePath)) {
      root.setStatus("App Binder's folder path has characters it can't pass to Hyprland.", true)
      return
    }
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
        if (out !== "" && out !== "ok") root.reportProblem("Couldn't install shortcuts in Hyprland: " + out.slice(0, 300))
        else if (root.stickyError.indexOf("Couldn't install shortcuts") === 0) root.clearProblem()
        bindsProc.running = true
      }
    }
  }

  // Restores Hyprland's own binding for a combo whose takeover was removed;
  // App Binder re-applies its shortcuts on the configreloaded event.
  Process {
    id: reloadProc
    command: ["hyprctl", "reload"]
  }

  Timer {
    id: submapCheck
    interval: 400
    onTriggered: submapProc.running = true
  }

  Process {
    id: submapProc
    command: ["hyprctl", "submap"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var current = String(text || "").trim()
        if (root.captureId === "" && current !== "" && current !== "default") Hyprland.dispatch("hl.dsp.submap('reset')")
      }
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event) return
      if (event.name === "configreloaded") root.applyBindings()
      else if (event.name === "openwindow" || event.name === "windowtitlev2") root.maybeLearn()
    }
  }

  // Files from earlier versions: the old generated Lua data and learned
  // matches. Both are rebuilt in the new format.
  Process {
    id: cleanupProc
    command: ["rm", "-f", "--"].concat(root.obsoletePaths)
  }

  Component.onCompleted: {
    cleanupProc.running = true
    root.applyBindings()
    scanProc.running = true
  }

  Component.onDestruction: {
    if (saveTimer.running) root.saveNow()
    if (root.captureId !== "") Hyprland.dispatch("hl.dsp.submap('reset')")
  }

  // ----------------------------------------------------- learning windows
  //
  // Linux has no reliable link from a window to the launcher entry that
  // started it, so App Binder learns it once, when it launches an app: the
  // standard launcher library records the entry in the app's environment,
  // and every process the app starts inherits it. The first window whose
  // process carries that record and started after the launch is the app.
  // Its match is saved as the row's window match (visible, and editable).
  //
  // The record can be stale: a launcher already running (Steam, Heroic)
  // passes on whatever started it, and so does a terminal. So it only counts
  // for processes newer than the launch, and never for a window that is
  // itself another app's own window.

  readonly property string launchInfoScript: decodeURIComponent(String(Qt.resolvedUrl("launch-info.sh")).replace(/^file:\/\//, ""))
  readonly property int launchGraceSeconds: 60
  // id -> { t, desktop }: launches hypr/app-binder.lua is waiting on.
  property var pendingLaunches: Object.create(null)
  property var learnWindows: []

  function loadPending(text) {
    var next = Object.create(null)
    var lines = String(text || "").split("\n").slice(0, 1000)
    for (var i = 0; i < lines.length; i++) {
      var t = lines[i].split(" ")
      if (t[0] !== "P" || !t[1] || t[1].charAt(0) !== "=") continue
      try {
        var id = decodeURIComponent(t[1].slice(1))
        var at = Number(t[2])
        if (id && isFinite(at)) next[id] = { t: at, desktop: Number(t[3]) || 0 }
      } catch (e) {}
    }
    root.pendingLaunches = next
  }

  function hasRecentLaunch() {
    var now = Date.now() / 1000
    for (var id in root.pendingLaunches) if (now - root.pendingLaunches[id].t < root.launchGraceSeconds) return true
    return false
  }

  function maybeLearn() { if (root.hasRecentLaunch()) learnTimer.restart() }

  // The match to save for a window: its class, plus its title when the class
  // is one many apps share; just the title if it has no class.
  function matchFor(w) {
    var full = w.title.trim()
    var title = full.length > 200 ? full.slice(0, 199) + "*" : full
    if (!w.cls) return "title:" + title
    if (root.sharedClasses.indexOf(w.cls.toLowerCase()) !== -1 && title) return w.cls + " title:" + title
    return w.cls
  }

  // True if a window's class is another app's own launcher entry, e.g.
  // Heroic's window when Heroic started in order to launch a game.
  function otherAppsWindow(cls, id) {
    if (!cls || cls === id) return false
    return !!(DesktopEntries.byId(cls) || DesktopEntries.byId(cls.toLowerCase()) || root.appInfo[cls])
  }

  function learnFrom(infoText) {
    var info = Object.create(null)
    var lines = String(infoText || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var f = lines[i].split("\t")
      if (f.length === 3) info[f[0]] = { id: f[1], start: Number(f[2]) }
    }
    var now = Date.now() / 1000
    for (var id in root.pendingLaunches) {
      var p = root.pendingLaunches[id]
      var a = root.apps[id]
      if (now - p.t >= root.launchGraceSeconds || !a || !a.keys) continue
      var row = root.rowById(id)
      var defaultMatch = row ? row.defaultMatch : id
      // A window match you set yourself always wins.
      if (a.match && a.match !== defaultMatch) continue
      var best = null
      for (var j = 0; j < root.learnWindows.length; j++) {
        var w = root.learnWindows[j]
        var rec = info[String(w.pid)]
        if (!rec || rec.id !== id || !(rec.start >= p.t - 1) || root.otherAppsWindow(w.cls, id)) continue
        if (!best || rec.start < best.start) best = { w: w, start: rec.start }
      }
      if (!best) continue
      var learned = root.matchFor(best.w)
      if (learned && learned !== a.match) root.setApp(id, { match: learned })
    }
  }

  Timer {
    id: learnTimer
    interval: 500
    onTriggered: learnClientsProc.running = true
  }

  Process {
    id: learnClientsProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var wins = []
        var pids = []
        try {
          var list = JSON.parse(text)
          for (var i = list.length - 1; i >= 0 && wins.length < 64; i--) {
            var c = list[i]
            var pid = Number(c.pid)
            if (!(pid > 0) || c["class"] === "org.quickshell") continue
            wins.push({ pid: pid, cls: String(c["class"] || "").slice(0, 200), title: String(c.title || "") })
            if (pids.indexOf(String(pid)) === -1) pids.push(String(pid))
          }
        } catch (e) { return }
        if (pids.length === 0) return
        root.learnWindows = wins
        launchInfoProc.command = ["bash", root.launchInfoScript].concat(pids)
        launchInfoProc.running = true
      }
    }
  }

  // Reads /proc for the windows' processes (see launch-info.sh).
  Process {
    id: launchInfoProc
    onRunningChanged: running ? launchInfoDeadline.restart() : launchInfoDeadline.stop()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.learnFrom(text)
    }
  }

  Timer {
    id: launchInfoDeadline
    interval: 5000
    onTriggered: if (launchInfoProc.running) launchInfoProc.running = false
  }

  FileView {
    id: pendingFile
    path: root.pendingPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadPending(text())
    onLoadFailed: root.pendingLaunches = Object.create(null)
    onFileChanged: reload()
  }

  // ------------------------------------------------------- other processes

  Process {
    id: bindsProc
    command: ["hyprctl", "binds"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.binds = root.parseBinds(text)
        root.migrateReplaces()
      }
    }
  }

  // Classifies desktop entries (native / Flatpak / web app / ...) so
  // look-alike apps can be told apart. See scan-apps.sh.
  Process {
    id: scanProc
    command: ["bash", root.scanScript]
    // The script does all its file reading itself, so stopping it (here, or
    // when the shell unloads App Binder) leaves nothing running behind it.
    onRunningChanged: running ? scanDeadline.restart() : scanDeadline.stop()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop()
        if (lines.length === 0 || lines[lines.length - 1] !== "END") return // stopped partway
        var next = Object.create(null)
        for (var i = 0; i < lines.length; i++) {
          var f = lines[i].split("\t")
          if (f.length < 5 || !f[0]) continue
          next[f[0]] = { file: f[1], kind: f[2], location: f[3], icon: f[4] }
        }
        root.appInfo = next
        if (root.opened) root.rebuild()
        root.writeBindings()
      }
    }
  }

  // A scan normally takes well under a second; never let one run on.
  Timer {
    id: scanDeadline
    interval: 10000
    onTriggered: if (scanProc.running) scanProc.running = false
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // One chip per class. A class that several different apps share
        // (Proton gives games it has no ID for "steam_app_default") gets one
        // chip per window instead, matching class and title together.
        // Titles come from any app, so they're cut to a sane length.
        var titles = Object.create(null)
        try {
          var list = JSON.parse(text)
          for (var i = 0; i < list.length && i < 200; i++) {
            var c = String(list[i]["class"] || "").slice(0, 200)
            if (!c || c === "org.quickshell") continue
            if (!titles[c]) titles[c] = []
            var t = String(list[i].title || "").trim().slice(0, 200)
            if (t && titles[c].indexOf(t) === -1 && titles[c].length < 20) titles[c].push(t)
          }
        } catch (e) {}
        var out = []
        for (var cls in titles) {
          var shared = root.sharedClasses.indexOf(cls.toLowerCase()) !== -1 || titles[cls].length > 1
          if (shared && titles[cls].length > 0) {
            for (var j = 0; j < titles[cls].length; j++) out.push(cls + " title:" + titles[cls][j])
          } else {
            out.push(cls)
          }
        }
        out.sort()
        root.windowClasses = out.slice(0, 100)
      }
    }
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadSettings(text())
    onLoadFailed: function(error) {
      root.settings = root.defaultSettings
      // Create it with documented defaults, but never over a file that exists.
      if (error === FileViewError.FileNotFound) settingsFile.setText(root.defaultSettingsText)
    }
    onFileChanged: reload()
  }

  Timer {
    id: captureTimer
    interval: root.setting("capture_timeout_seconds") * 1000
    onTriggered: {
      root.endCapture()
      root.setStatus("Stopped waiting for a shortcut.", false)
    }
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      if (root.opened) root.rebuild()
      scanProc.running = true
    }
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
          var ms = Style.duration(root.setting("scroll_glide_ms"))
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
          if (root.editingMatchId !== "") { root.handleMatchKey(event); return }
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
          // Held keys don't repeat edits: each would be a save.
          else if (event.isAutoRepeat && (k === Qt.Key_Right || k === Qt.Key_Left || k === Qt.Key_Delete)) { }
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
              NumberAnimation { duration: Style.duration(280); easing.type: Easing.OutCubic }
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
            NumberAnimation { duration: Style.duration(260); easing.type: Easing.OutCubic }
          }
          Behavior on opacity {
            enabled: root.animateSettings
            NumberAnimation { duration: Style.duration(200) }
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
          Text { width: root.matchWidth; text: "Window match"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
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
                  source: root.iconFor(rowItem.modelData.icon, rowItem.modelData.id)
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
                  // Plain text plus a drawn cursor; typing goes through
                  // root.handleMatchKey. Only exists while this row edits.
                  Loader {
                    id: matchEditor
                    anchors.fill: parent
                    anchors.leftMargin: Style.spacing.sm
                    anchors.rightMargin: Style.spacing.sm
                    active: rowItem.isEditing
                    sourceComponent: Item {
                      clip: true
                      FontMetrics {
                        id: metrics
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }
                      readonly property real cursorX: metrics.advanceWidth(root.matchDraft.slice(0, root.matchCursor))
                      // Scroll so the cursor stays in view.
                      readonly property real shift: Math.min(0, width - cursorX - Style.space(4))

                      // Character position closest to x (in this item's coordinates).
                      function indexAt(x) {
                        var target = x - shift
                        var best = 0
                        var bestDist = Math.abs(target)
                        for (var i = 1; i <= root.matchDraft.length; i++) {
                          var dist = Math.abs(metrics.advanceWidth(root.matchDraft.slice(0, i)) - target)
                          if (dist < bestDist) { best = i; bestDist = dist }
                        }
                        return best
                      }

                      Rectangle {
                        visible: root.matchAllSelected && root.matchDraft !== ""
                        x: parent.shift
                        anchors.verticalCenter: parent.verticalCenter
                        width: draftText.implicitWidth
                        height: draftText.implicitHeight
                        color: root.selectedBackground
                      }
                      Text {
                        id: draftText
                        x: parent.shift
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.PlainText
                        text: root.matchDraft
                        color: root.matchAllSelected ? root.selectedText : rowItem.textColor
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }
                      Rectangle {
                        x: parent.shift + parent.cursorX
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(1, Style.space(2))
                        height: metrics.height
                        color: rowItem.textColor
                      }
                    }
                  }
                  // Clicks inside the editor stay in the editor: a click
                  // places the cursor, a double-click selects everything.
                  MouseArea {
                    anchors.fill: parent
                    visible: rowItem.isEditing
                    cursorShape: Qt.IBeamCursor
                    onPressed: function(mouse) {
                      if (matchEditor.item) {
                        root.matchCursor = matchEditor.item.indexAt(mouse.x - matchEditor.x)
                        root.matchAllSelected = false
                      }
                      keyCatcher.forceActiveFocus()
                    }
                    onDoubleClicked: root.matchAllSelected = true
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
            text: "Click or ↵ set shortcut · ←/→ or click desktop · click match to edit · Del clear · type to filter · Esc close"
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
