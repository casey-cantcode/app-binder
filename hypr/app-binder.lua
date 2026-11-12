-- App Binder runtime: per-app focus-or-launch shortcuts.
--
-- The App Binder plugin runs this file inside Hyprland (`hyprctl eval`) when
-- the shell starts, after every config reload, and whenever the shortcuts
-- change, so nothing needs adding to hyprland.lua. Re-running it is safe.
-- Each row of the plugin's table becomes a binding:
--   app focused     -> go back to the window you were on before
--   app running     -> switch to its desktop and focus its most recently
--                      used window (never starts a second copy)
--   app not running -> switch to the row's desktop (or the first empty one),
--                      then launch it there
--
-- This code runs on Hyprland's own thread, so it never waits on anything:
-- it reads only two small files in $XDG_RUNTIME_DIR (tmpfs, private to you),
-- parses them as plain data (never runs them as code), bounds every input,
-- and leaves all work that could block (scanning apps, learning which window
-- belongs to which app) to the plugin, outside Hyprland.

local RUNTIME = os.getenv("XDG_RUNTIME_DIR")
local BINDINGS = RUNTIME and RUNTIME .. "/app-binder-bindings.txt" or nil
local PENDING = RUNTIME and RUNTIME .. "/app-binder-pending.txt" or nil
local PLUGIN_ID = "cantcode.app-binder"
local OPENER = "SUPER + CTRL + ALT + SPACE"

local MAX_FILE = 4 * 1024 * 1024 -- bytes read from the bindings file
local MAX_ROWS = 1000
local MAX_TEXT = 512             -- bytes of a window class or title compared
local LAUNCH_GRACE = 60          -- seconds a launch counts as still starting

local function notify(message)
  hl.exec_cmd(o.notify(message)) -- o.notify only builds the command
end

-- Optional multi-monitor hook: if ~/.config/hypr/linked-desktops.lua exists
-- (a module with switch / focus_window / first_empty), a "desktop" can span
-- several monitors. Otherwise App Binder switches plain workspaces.
local has_linked, linked = pcall(require, "hypr.linked-desktops")
if not has_linked then
  linked = {
    switch = function(n) hl.dispatch(hl.dsp.focus({ workspace = tostring(n) })) end,
    focus_window = function(win) hl.dispatch(hl.dsp.focus({ window = "address:" .. win.address })) end,
    first_empty = function()
      local used = {}
      for _, w in ipairs(hl.get_windows()) do
        if w.workspace and w.workspace.id then used[w.workspace.id] = true end
      end
      for n = 1, 10 do if not used[n] then return n end end
      return nil
    end,
  }
end

-- ------------------------------------------------------------ plain data
-- Fields are percent-encoded (like a URL) and prefixed with "=", so a field
-- never contains a space or newline and an empty field is just "=". A list
-- is its items' fields joined by commas ("=a,=,=b" is a, "", b).

local function decode(token)
  if type(token) ~= "string" or token:sub(1, 1) ~= "=" then return nil end
  return (token:sub(2):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function decode_list(token)
  if token == "=" then return {} end -- the empty list
  if type(token) ~= "string" or token:sub(1, 1) ~= "=" then return nil end
  local out = {}
  for item in (token .. ","):gmatch("([^,]*),") do
    local v = decode(item)
    if not v then return nil end
    out[#out + 1] = v
  end
  return out
end

local function encode(s)
  return "=" .. tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)
end

local function read_file(path, limit)
  if not path then return nil end
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read(limit)
  f:close()
  return text
end

local function tokens(line)
  local out = {}
  for t in line:gmatch("%S+") do out[#out + 1] = t end
  return out
end

-- -------------------------------------------------------------- matching

local function lower_capped(s)
  return type(s) == "string" and string.lower(s:sub(1, MAX_TEXT)) or nil
end

-- A glob test for one part of a match. "*" matches anything; there are no
-- other special characters. Linear time: pieces between stars are found left
-- to right with plain search and never backtrack (Lua patterns could take
-- minutes on a hostile window title, and Hyprland's Lua timeout can't stop
-- them).
local function glob(pattern)
  local pat = string.lower(pattern)
  if pat == "" then return nil end
  if not pat:find("*", 1, true) then return function(s) return s == pat end end
  local parts, start = {}, 1
  while true do
    local i = pat:find("*", start, true)
    if not i then parts[#parts + 1] = pat:sub(start); break end
    parts[#parts + 1] = pat:sub(start, i - 1)
    start = i + 1
  end
  local first, last = parts[1], parts[#parts]
  return function(s)
    if not s or #s < #first + #last then return false end
    if s:sub(1, #first) ~= first then return false end
    if #last > 0 and s:sub(-#last) ~= last then return false end
    local pos, limit = #first + 1, #s - #last
    for i = 2, #parts - 1 do
      local piece = parts[i]
      if #piece > 0 then
        local a, b = s:find(piece, pos, true)
        if not a or b > limit then return false end
        pos = b + 1
      end
    end
    return true
  end
end

-- A match is a window class, optionally followed by "title:<title>", e.g.
-- "zen", "steam_app_default title:Battle.net" or "title:World of Warcraft".
local function matcher(match)
  local m = match or ""
  local class_part, title_part = m, nil
  local at = m:find("title:", 1, true)
  if at then class_part, title_part = m:sub(1, at - 1), m:sub(at + 6) end
  local class_test = glob(class_part:match("^%s*(.-)%s*$"))
  local title_test = title_part and glob(title_part:match("^%s*(.-)%s*$"))
  if not class_test and not title_test then return function() return false end end
  return function(w)
    if class_test and not (class_test(lower_capped(w.class)) or class_test(lower_capped(w.initial_class))) then
      return false
    end
    if title_test and not title_test((lower_capped(w.title) or ""):match("^%s*(.-)%s*$")) then return false end
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

-- Lowercase letters and digits only, so "Vintage Story" and "vintagestory"
-- compare equal. The plugin sends each app's names already squashed.
local function squash(s)
  return type(s) == "string" and (string.lower(s:sub(1, MAX_TEXT)):gsub("[^%w]", "")) or ""
end

-- The app's window, most confident first: its window match (set by you, or
-- learned by the plugin the first time App Binder launched the app), then
-- Steam's steam_app_<id> class, then a class or title that is the app's ID
-- or name (ignoring case, spaces, punctuation and a version number).
local function find_window(app)
  local win = best_window(app.test)
  if win then return win end
  if app.steam_id ~= "" then
    local cls = "steam_app_" .. app.steam_id
    win = best_window(function(w) return w.class == cls or w.initial_class == cls end)
    if win then return win end
  end
  local keys = app.names
  if next(keys) == nil then return nil end
  win = best_window(function(w) return keys[squash(w.class)] or keys[squash(w.initial_class)] end)
  if win then return win end
  return best_window(function(w) return keys[squash(w.title)] end)
end

-- The window used just before the focused one, skipping App Binder's own.
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

-- Switching desktops and focusing a window both move the mouse cursor in
-- Hyprland (Omarchy turns on cursor.warp_on_change_workspace). App Binder
-- never moves the cursor: it turns both warps off for its own switch, puts
-- your settings back, and returns the cursor if something still moved it.
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

-- --------------------------------------------------------- pending launches
-- Apps launched whose window hasn't appeared yet. Some take most of a
-- minute (a game through Heroic and Wine); pressing the shortcut again in
-- that time goes to the app's desktop instead of starting a second copy.
-- Kept in memory and in a small file, because a config reload resets
-- Hyprland's Lua state. The plugin also reads the file, to learn the window.

local pending = rawget(_G, "__app_binder_pending")
if type(pending) ~= "table" then
  pending = {}
  for line in (read_file(PENDING, 65536) or ""):gmatch("[^\n]+") do
    local t = tokens(line)
    local id, at, desktop = decode(t[2]), math.tointeger(tonumber(t[3])), math.tointeger(tonumber(t[4]))
    local now = os.time()
    if t[1] == "P" and id and #id <= 1024 and at and desktop
      and at >= now - LAUNCH_GRACE and at <= now + 5 and desktop >= 0 and desktop <= 10 then
      pending[id] = { t = at, desktop = desktop }
    end
  end
  rawset(_G, "__app_binder_pending", pending)
end

local function save_pending()
  if not PENDING then return end
  local now, lines = os.time(), {}
  for id, p in pairs(pending) do
    local age = now - p.t
    if age >= 0 and age < LAUNCH_GRACE then
      lines[#lines + 1] = string.format("P %s %d %d", encode(id), p.t, p.desktop)
    else
      pending[id] = nil
    end
  end
  local tmp = PENDING .. ".tmp"
  local f = io.open(tmp, "wb")
  if not f then return end
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
  os.rename(tmp, PENDING)
end

-- ---------------------------------------------------------------- activate

local function launch(app)
  if #app.tui > 0 then
    local words = {}
    for i, w in ipairs(app.tui) do words[i] = o.shell_quote(w) end
    hl.exec_cmd("omarchy-launch-tui " .. table.concat(words, " "))
  else
    hl.exec_cmd("uwsm-app -- gtk-launch " .. o.shell_quote(app.id .. ".desktop"))
  end
end

local function activate(app)
  local win = find_window(app)
  if win then
    if pending[app.id] then pending[app.id] = nil; pcall(save_pending) end
    -- Already on this app: the shortcut toggles back to where you were.
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
  local p = pending[app.id]
  -- A launch counts as still starting for LAUNCH_GRACE seconds. A negative
  -- age (the clock was set back) counts as expired, never as forever.
  if p and now - p.t >= 0 and now - p.t < LAUNCH_GRACE then
    if p.desktop > 0 then keep_cursor(function() linked.switch(p.desktop) end) end
    notify(app.name .. " is still starting. If it doesn't appear, press again after "
      .. (LAUNCH_GRACE - (now - p.t)) .. " s to launch it again.")
    return
  end

  local desktop = app.desktop
  if desktop < 1 then desktop = linked.first_empty() or 0 end
  if desktop > 0 then keep_cursor(function() linked.switch(desktop) end) end
  pending[app.id] = { t = now, desktop = desktop }
  launch(app)
  pcall(save_pending) -- launching never depends on this file being writable
end

-- ------------------------------------------------------------- the binds

-- Bindings are removed by their key strings, never through keybind objects
-- kept from an earlier run. Hyprland's Lua state survives a config reload
-- but the reload frees every binding, so a kept object can point at freed
-- memory, and calling it crashes Hyprland. A key string is looked up fresh.
-- The cost: unbinding a combo also removes anyone else's binding on it.
-- App Binder only binds combos you gave it (taking over an existing binding
-- always asks first), plus its own opener.

-- A 0.2.1 pre-release kept keybind objects here. Drop them without
-- touching them (they may already be freed); each row's keys are unbound
-- by string below anyway.
rawset(_G, "__app_binder_binds", nil)
rawset(_G, "__app_binder_static", nil)

for _, keys in ipairs(rawget(_G, "__app_binder_bound") or {}) do
  if type(keys) == "string" then pcall(hl.unbind, keys) end
end
local bound = {}
rawset(_G, "__app_binder_bound", bound)

pcall(hl.unbind, OPENER)
if pcall(o.bind, OPENER, "App Binder", { panel = PLUGIN_ID }) then bound[#bound + 1] = OPENER end

-- Empty submap used while the plugin records a shortcut, so the pressed
-- combo reaches the plugin instead of firing its current binding. The
-- plugin always leaves it; this is the manual escape hatch. Defined once per
-- Hyprland session.
if not rawget(_G, "__app_binder_submap") then
  pcall(hl.define_submap, "appbinder", function()
    hl.bind("SUPER + CTRL + ALT + SHIFT + Escape", hl.dsp.submap("reset"))
  end)
  rawset(_G, "__app_binder_submap", true)
end

if not RUNTIME then
  if not rawget(_G, "__app_binder_warned") then
    notify("App Binder: XDG_RUNTIME_DIR isn't set, so app shortcuts are off.")
    rawset(_G, "__app_binder_warned", true)
  end
  return
end

local text = read_file(BINDINGS, MAX_FILE) or ""
local rows, skipped = {}, 0
for line in text:gmatch("[^\n]+") do
  local t = tokens(line)
  if t[1] == "B" and #rows < MAX_ROWS then
    -- B id name keys match desktop steam_id tui-words replaces names
    local row = {
      id = decode(t[2]), name = decode(t[3]), keys = decode(t[4]), match = decode(t[5]),
      desktop = tonumber(decode(t[6]) or ""), steam_id = decode(t[7]),
      tui = decode_list(t[8]), replaces = decode_list(t[9]), name_keys = decode_list(t[10]),
    }
    -- Limits are in bytes: the plugin caps text at 256 characters, which is
    -- at most 1024 bytes in UTF-8.
    local valid = row.id and row.id ~= "" and #row.id <= 1024
      and row.name and #row.name <= 1024
      and row.keys and #row.keys <= 128 and row.keys:match("^[%w %+:_]+$")
      and row.match and #row.match <= 1024
      and row.desktop and row.desktop == math.floor(row.desktop) and row.desktop >= 0 and row.desktop <= 10
      and row.steam_id and row.steam_id:match("^%d*$") and #row.steam_id <= 20
      and row.tui and #row.tui <= 64 and row.replaces and #row.replaces <= 16
      and row.name_keys and #row.name_keys <= 8
    if valid then
      row.test = matcher(row.match)
      row.names = {}
      for _, k in ipairs(row.name_keys) do if k ~= "" then row.names[squash(k)] = true end end
      rows[#rows + 1] = row
    else
      skipped = skipped + 1
    end
  end
end
if skipped > 0 then notify("App Binder: skipped " .. skipped .. " damaged shortcut entries.") end

for _, app in ipairs(rows) do
  -- Bindings you chose to take over. A config reload brings them back.
  for _, combo in ipairs(app.replaces) do
    if combo:match("^[%w %+:_]+$") then pcall(hl.unbind, combo) end
  end
  pcall(hl.unbind, app.keys)
  local ok, err = pcall(o.bind, app.keys, "App Binder: " .. app.name, function() activate(app) end)
  if ok then
    bound[#bound + 1] = app.keys
  else
    notify("App Binder: could not bind " .. app.keys .. ": " .. tostring(err))
  end
end
