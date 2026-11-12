-- App Binder runtime: per-app focus-or-launch shortcuts.
--
-- The App Binder plugin owns the shortcut table and writes it to
-- ~/.config/omarchy/app-binder-data.lua. The plugin runs this file inside
-- Hyprland (`hyprctl eval`) when the shell starts and after every config
-- reload, so nothing needs adding to hyprland.lua. Re-running it is safe: it
-- first removes the bindings it made last time.
-- This file turns each row into a binding:
--   app focused     -> go back to the window you were on before
--   app running     -> switch to its desktop and focus its most
--                      recently used window (never starts a second copy)
--   app not running -> switch to the row's desktop (or the first empty one
--                      for "Any"), then launch it there
--
-- Open the App Binder window with SUPER+CTRL+ALT+SPACE.

-- Optional multi-monitor hook: if ~/.config/hypr/linked-desktops.lua exists
-- (a module with switch / focus_window / first_empty), App Binder uses it so
-- a "desktop" can span several monitors. Otherwise it switches plain
-- Hyprland workspaces.
local has_linked, linked = pcall(require, "hypr.linked-desktops")
if not has_linked then
  linked = {
    switch = function(n)
      hl.dispatch(hl.dsp.focus({ workspace = tostring(n) }))
    end,
    focus_window = function(win)
      hl.dispatch(hl.dsp.focus({ window = "address:" .. win.address }))
    end,
    first_empty = function()
      local used = {}
      for _, w in ipairs(hl.get_windows()) do
        if w.workspace and w.workspace.id then used[w.workspace.id] = true end
      end
      for n = 1, 10 do
        if not used[n] then return n end
      end
      return nil
    end,
  }
end

local HOME = os.getenv("HOME") or ""
local DATA = HOME .. "/.config/omarchy/app-binder-data.lua"
local LEGACY_DATA = HOME .. "/.config/hypr/app-binder-data.lua" -- before 0.1.0
local PLUGIN_ID = "cantcode.app-binder"
local OPENER = "SUPER + CTRL + ALT + SPACE"

-- Remove what the previous run bound (a config reload starts from scratch
-- anyway; this covers repeat runs without a reload, e.g. a shell restart).
local previous = rawget(_G, "__app_binder_bound") or {}
for _, keys in ipairs(previous) do pcall(hl.unbind, keys) end
local bound = {}

-- Opener for the App Binder window. Only App Binder's own previous binding is
-- removed (above): if you use this combo for something else, it's left alone
-- and both fire.
o.bind(OPENER, "App Binder", "omarchy-shell shell toggle " .. PLUGIN_ID .. " '{}'")
table.insert(bound, OPENER)

-- Empty submap used while the plugin records a shortcut, so Hyprland lets the
-- pressed combo through to the plugin instead of firing its current binding.
-- The plugin always resets it; this bind is the manual escape hatch. Defined
-- once per config load.
if not rawget(_G, "__app_binder_submap") then
  hl.define_submap("appbinder", function()
    hl.bind("SUPER + CTRL + ALT + SHIFT + Escape", hl.dsp.submap("reset"))
  end)
  rawset(_G, "__app_binder_submap", true)
end

local function notify(message)
  hl.exec_cmd(o.notify(message)) -- o.notify only builds the command
end

-- "zen" matches class zen exactly (case-insensitive); "*hey.com*" is a glob.
local function pattern_test(match)
  local m = string.lower(match or "")
  if m == "" then return nil end
  if m:find("*", 1, true) then
    local escaped = (m:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"))
    local pattern = "^" .. (escaped:gsub("%*", ".*")) .. "$"
    return function(s) return s ~= nil and string.lower(s):find(pattern) ~= nil end
  end
  return function(s) return s ~= nil and string.lower(s) == m end
end

-- A match is a window class, optionally followed by "title:<title>":
--   "zen"                                class only
--   "steam_app_default title:Battle.net" class and title (for runtimes such as
--                                        Proton that give many games one class)
--   "title:World of Warcraft"            title only
-- Both parts accept * wildcards.
local function matcher(match)
  local m = match or ""
  local class_part, title_part = m, nil
  local at = m:find("title:", 1, true)
  if at then
    class_part = m:sub(1, at - 1)
    title_part = m:sub(at + 6)
  end
  class_part = class_part:match("^%s*(.-)%s*$")
  title_part = title_part and title_part:match("^%s*(.-)%s*$")
  local class_test = pattern_test(class_part)
  local title_test = title_part and pattern_test(title_part)
  if not class_test and not title_test then return function() return false end end
  return function(w)
    if class_test and not (class_test(w.class) or class_test(w.initial_class)) then return false end
    if title_test and not title_test(w.title) then return false end
    return true
  end
end

-- Most recently used window that passes test, or nil.
local function best_window(test)
  local best, best_rank = nil, math.huge
  for _, w in ipairs(hl.get_windows()) do
    if w.class ~= "org.quickshell" and test(w) then
      local rank = w.focus_history_id
      if type(rank) ~= "number" or rank < 0 then rank = 1e6 end
      if rank < best_rank then best, best_rank = w, rank end
    end
  end
  return best
end

-- Folders that hold launcher entries, in the order launchers search them:
-- the user's applications folder first, then the system ones.
local function desktop_dirs()
  local home = os.getenv("HOME") or ""
  local dirs = { (os.getenv("XDG_DATA_HOME") or (home .. "/.local/share")) .. "/applications" }
  for dir in string.gmatch(os.getenv("XDG_DATA_DIRS") or "/usr/local/share:/usr/share", "[^:]+") do
    table.insert(dirs, dir .. "/applications")
  end
  return dirs
end

-- True if a launcher entry with this ID exists.
local function has_entry(id)
  if not id or id == "" then return false end
  for _, dir in ipairs(desktop_dirs()) do
    local f = io.open(dir .. "/" .. id .. ".desktop")
    if f then f:close(); return true end
  end
  return false
end

-- The Exec line of an app's launcher entry.
local function desktop_exec(id)
  for _, dir in ipairs(desktop_dirs()) do
    local f = io.open(dir .. "/" .. id .. ".desktop")
    if f then
      local in_entry, exec = false, nil
      for line in f:lines() do
        if line:match("^%[") then in_entry = (line == "[Desktop Entry]") end
        if in_entry and not exec then exec = line:match("^Exec=(.*)$") end
      end
      f:close()
      return exec
    end
  end
  return nil
end

local steam_ids = {}
local function steam_id(app)
  if steam_ids[app.id] == nil then
    local exec = desktop_exec(app.id) or ""
    steam_ids[app.id] = exec:match("steam://rungameid/(%d+)") or false
  end
  return steam_ids[app.id] or nil
end

-- Lowercase letters and digits only, so "Vintage Story", "vintagestory" and
-- "Vintage-Story" compare equal.
local function squash(s)
  return (string.lower(s or ""):gsub("[^%w]", ""))
end

-- Names that identify an app, squashed: its launcher ID, its name, and its
-- name without a trailing version ("Vintage Story 1.21.0" -> "vintagestory").
local function app_keys(app)
  local keys = {}
  local function add(s)
    local k = squash(s)
    if k ~= "" then keys[k] = true end
  end
  add(app.id)
  add(app.name)
  add((app.name or ""):gsub("%s+v?%d[%w%.%-]*$", ""))
  return keys
end

-- ------------------------------------------------------- learned windows
--
-- Linux has no reliable link from a window to the launcher entry that
-- started it, so instead of guessing every time, App Binder learns it once.
-- When it launches an app, the standard launcher library records which
-- launcher entry started it (GIO_LAUNCHED_DESKTOP_FILE) in the app's
-- environment, and every process the app starts inherits that. The first
-- window whose process carries this app's record, and started after the
-- launch, is the app. App Binder saves an exact match from that window and
-- uses it from then on.
--
-- The record is inherited, so it can be stale: a launcher that was already
-- running (Steam, Heroic) passes on whatever started it, and so does a
-- terminal. That's why it's only trusted for processes newer than the launch,
-- and never for a window that is itself another launcher entry's app.

local STATE_DIR = os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")
local LEARNED = STATE_DIR .. "/app-binder-learned.lua"

-- Window classes that many unrelated apps share, so they need the title too.
local SHARED_CLASSES = { steam_app_default = true }

local function load_learned()
  local ok, t = pcall(dofile, LEARNED)
  return (ok and type(t) == "table") and t or {}
end

local function save_learned(t)
  local f = io.open(LEARNED, "w")
  if not f then return end
  f:write("-- Window matches App Binder learned by watching apps it launched.\n")
  f:write("-- Safe to delete: App Binder learns them again.\n")
  f:write("return {\n")
  for id, l in pairs(t) do
    f:write(string.format("  [%q] = { match = %q, under = %q },\n", id, l.match or "", l.under or ""))
  end
  f:write("}\n")
  f:close()
end

-- The launcher entry ID recorded in a process's environment, or nil.
local function launch_record(pid)
  if type(pid) ~= "number" or pid <= 0 then return nil end
  local f = io.open("/proc/" .. pid .. "/environ", "rb")
  if not f then return nil end
  local env = f:read("a") or ""
  f:close()
  local path = env:match("%zGIO_LAUNCHED_DESKTOP_FILE=([^%z]+)") or env:match("^GIO_LAUNCHED_DESKTOP_FILE=([^%z]+)")
  return path and path:match("([^/]+)%.desktop$") or nil
end

-- When a process started, in seconds since the epoch, or nil.
local boot_time
local function process_start(pid)
  if type(pid) ~= "number" or pid <= 0 then return nil end
  if not boot_time then
    local f = io.open("/proc/stat")
    if not f then return nil end
    boot_time = tonumber((f:read("a") or ""):match("btime (%d+)"))
    f:close()
    if not boot_time then return nil end
  end
  local f = io.open("/proc/" .. pid .. "/stat")
  if not f then return nil end
  local stat = f:read("a") or ""
  f:close()
  -- Fields after the ")" that ends the process name; start time is field 22,
  -- the 20th one here, counted in clock ticks (100 per second) since boot.
  local rest = stat:match("%)%s+(.*)$")
  if not rest then return nil end
  local n, ticks = 0, nil
  for field in rest:gmatch("%S+") do
    n = n + 1
    if n == 20 then ticks = tonumber(field); break end
  end
  return ticks and (boot_time + ticks / 100) or nil
end

-- The exact match to save for a window.
local function match_for(w)
  local class = w.class or ""
  if class == "" then return "title:" .. (w.title or "") end
  if SHARED_CLASSES[string.lower(class)] and (w.title or "") ~= "" then
    return class .. " title:" .. w.title
  end
  return class
end

-- The window this app's launch (at time `since`) produced, or nil. If there
-- are several, it's the one whose process started first: whatever the app
-- launches in turn (a game started from Battle.net) inherits the same record
-- but always starts later.
local function launched_window(app, since)
  local first, first_start = nil, math.huge
  for _, w in ipairs(hl.get_windows()) do
    if w.class ~= "org.quickshell" and launch_record(w.pid) == app.id then
      local started = process_start(w.pid)
      -- A window that is another launcher entry's own app (e.g. Heroic's
      -- window when Heroic starts in order to launch a game) isn't this app.
      local other = w.class ~= app.id
        and (has_entry(w.class) or has_entry(string.lower(w.class or "")))
      if started and started >= since - 1 and not other and started < first_start then
        first, first_start = w, started
      end
    end
  end
  return first
end

-- If this app's launch produced a window, save an exact match for it.
local function learn(app, since)
  local win = launched_window(app, since)
  if not win then return nil end
  local learned = load_learned()
  learned[app.id] = { match = match_for(win), under = app.match or "" }
  save_learned(learned)
  return win
end

-- The app's window, found in order of confidence:
--   1. the row's window match (default or user-set)
--   2. the match App Binder learned when it launched the app, as long as the
--      row's own match hasn't been changed since
--   3. Steam games: Proton names a game's window steam_app_<id>, the same id
--      as the steam://rungameid/<id> its launcher entry runs
--   4. a window class that is the app's ID or name, ignoring case, spaces,
--      punctuation and a version number on the name
--   5. a window title that is the app's name, compared the same way. This
--      covers games from launchers such as Heroic, which share a generic
--      window class.
-- 4 and 5 are guesses for apps App Binder hasn't launched (and learned) yet.
local function find_window(app)
  local win = best_window(matcher(app.match))
  if win then return win end
  local l = load_learned()[app.id]
  if l and l.under == (app.match or "") then
    win = best_window(matcher(l.match))
    if win then return win end
  end
  local sid = steam_id(app)
  if sid then
    local cls = "steam_app_" .. sid
    win = best_window(function(w) return w.class == cls or w.initial_class == cls end)
    if win then return win end
  end
  local keys = app_keys(app)
  win = best_window(function(w) return keys[squash(w.class)] or keys[squash(w.initial_class)] end)
  if win then return win end
  return best_window(function(w) return keys[squash(w.title)] end)
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Switching desktops and focusing a window both move the mouse cursor in
-- Hyprland (Omarchy turns on cursor.warp_on_change_workspace). App Binder
-- should never move the cursor, so it turns both warps off for its own switch
-- and then restores whatever the user's config had. If something still moved
-- the cursor, it is put back where it was.
local function keep_cursor(fn)
  local pos = hl.get_cursor_pos()
  local no_warps = hl.get_config("cursor.no_warps")
  local warp_ws = hl.get_config("cursor.warp_on_change_workspace")
  local suppressed = pcall(hl.config, { cursor = { no_warps = true, warp_on_change_workspace = 0 } })
  local ok, err = pcall(fn)
  if suppressed then
    pcall(hl.config, { cursor = { no_warps = no_warps, warp_on_change_workspace = warp_ws } })
  end
  local now = hl.get_cursor_pos()
  if pos and now and (math.abs(now.x - pos.x) > 0.5 or math.abs(now.y - pos.y) > 0.5) then
    pcall(hl.dispatch, hl.dsp.cursor.move({ x = pos.x, y = pos.y }))
  end
  if not ok then error(err, 0) end
end

-- Apps launched but whose window hasn't appeared yet. Some take a long time:
-- a game started through Heroic and Wine can take most of a minute. Pressing
-- the shortcut again in that time must not start a second copy, so it goes to
-- the app's desktop and waits instead. Kept in a file because a config reload
-- (which App Binder does after every save) resets Hyprland's Lua state.
local LAUNCH_GRACE = 60 -- seconds
local PENDING = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/app-binder-launching.lua"

local function load_pending()
  local ok, t = pcall(dofile, PENDING)
  return (ok and type(t) == "table") and t or {}
end

local function save_pending(t)
  local f = io.open(PENDING, "w")
  if not f then return end
  f:write("return {\n")
  for id, p in pairs(t) do
    f:write(string.format("  [%q] = { t = %d, desktop = %d },\n", id, p.t or 0, p.desktop or 0))
  end
  f:write("}\n")
  f:close()
end

-- The window used just before the focused one, skipping App Binder's own
-- window. Hyprland numbers focus history from 0 (the focused window) up.
local function previous_window()
  local best, best_rank = nil, math.huge
  for _, w in ipairs(hl.get_windows()) do
    local rank = w.focus_history_id
    if w.class ~= "org.quickshell" and type(rank) == "number" and rank > 0 and rank < best_rank then
      best, best_rank = w, rank
    end
  end
  return best
end

local function activate(app)
  local pending = load_pending()
  local p = pending[app.id]
  -- After a launch, the launch record is the strongest evidence there is.
  local win = p and learn(app, p.t or 0) or find_window(app)
  if win then
    if p then pending[app.id] = nil; save_pending(pending) end
    -- Already on this app: the shortcut works as a toggle and goes back to
    -- the window you came from.
    local active = hl.get_active_window()
    if active and active.address == win.address then
      local back = previous_window()
      if back then keep_cursor(function() linked.focus_window(back) end) end
      return
    end
    keep_cursor(function() linked.focus_window(win) end)
    return
  end

  local now = os.time()
  local name = app.name or app.id
  if p and now - (p.t or 0) < LAUNCH_GRACE then
    if (p.desktop or 0) > 0 then keep_cursor(function() linked.switch(p.desktop) end) end
    local wait = LAUNCH_GRACE - (now - p.t)
    notify(name .. " is still starting. If it doesn't appear, press again after "
      .. wait .. " s to launch it again.")
    return
  end

  local desktop = tonumber(app.desktop) or 0
  if desktop < 1 or desktop > 10 then desktop = linked.first_empty() end
  if desktop then keep_cursor(function() linked.switch(desktop) end) end
  pending[app.id] = { t = now, desktop = desktop or 0 }
  save_pending(pending)
  hl.exec_cmd("uwsm-app -- gtk-launch " .. shell_quote(app.id .. ".desktop"))
end

local function exists(path)
  local f = io.open(path)
  if f then f:close() end
  return f ~= nil
end

local data_path = exists(DATA) and DATA or (exists(LEGACY_DATA) and LEGACY_DATA or nil)
local ok, apps = true, {}
if data_path then ok, apps = pcall(dofile, data_path) end
if not ok then
  notify("App Binder: could not load " .. data_path .. ": " .. tostring(apps))
  apps = {}
end

for _, app in ipairs(apps or {}) do
  if type(app) == "table" and app.keys and app.keys ~= "" and app.id then
    pcall(hl.unbind, app.keys)
    -- Bindings the user chose to take over. Hyprland may register the same
    -- key by name ("SUPER + CTRL + B") rather than by code, so the plugin
    -- records each one's own spelling. A config reload brings them back.
    for _, combo in ipairs(app.replaces or {}) do pcall(hl.unbind, combo) end
    local done, err = pcall(o.bind, app.keys, "App Binder: " .. (app.name or app.id),
      function() activate(app) end)
    if done then
      table.insert(bound, app.keys)
    else
      notify("App Binder: could not bind " .. app.keys .. ": " .. tostring(err))
    end
  end
end

rawset(_G, "__app_binder_bound", bound)
