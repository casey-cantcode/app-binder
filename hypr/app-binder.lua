-- App Binder runtime: per-app focus-or-launch shortcuts.
--
-- The App Binder plugin owns the shortcut table and writes it to
-- ~/.config/omarchy/app-binder-data.lua. The plugin runs this file inside
-- Hyprland (`hyprctl eval`) when the shell starts and after every config
-- reload, so nothing needs adding to hyprland.lua. Re-running it is safe: it
-- first removes the bindings it made last time.
-- This file turns each row into a binding:
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

-- "zen" matches class zen exactly (case-insensitive); "*hey.com*" is a glob.
local function matcher(match)
  local m = string.lower(match or "")
  if m == "" then return function() return false end end
  if m:find("*", 1, true) then
    local escaped = (m:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"))
    local pattern = "^" .. (escaped:gsub("%*", ".*")) .. "$"
    return function(s) return s ~= nil and string.lower(s):find(pattern) ~= nil end
  end
  return function(s) return s ~= nil and string.lower(s) == m end
end

local function find_window(match)
  local test = matcher(match)
  local best, best_rank = nil, math.huge
  for _, w in ipairs(hl.get_windows()) do
    if w.class ~= "org.quickshell" and (test(w.class) or test(w.initial_class)) then
      local rank = w.focus_history_id
      if type(rank) ~= "number" or rank < 0 then rank = 1e6 end
      if rank < best_rank then best, best_rank = w, rank end
    end
  end
  return best
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Ignore repeat presses while a just-launched app is still starting up.
local launching = {}

local function activate(app)
  local win = find_window(app.match)
  if win then
    launching[app.id] = nil
    linked.focus_window(win)
    return
  end
  local now = os.time()
  if launching[app.id] and now - launching[app.id] < 4 then return end
  launching[app.id] = now

  local desktop = tonumber(app.desktop) or 0
  if desktop < 1 or desktop > 10 then desktop = linked.first_empty() end
  if desktop then linked.switch(desktop) end
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
  o.notify("App Binder: could not load " .. data_path .. ": " .. tostring(apps))
  apps = {}
end

for _, app in ipairs(apps or {}) do
  if type(app) == "table" and app.keys and app.keys ~= "" and app.id then
    pcall(hl.unbind, app.keys)
    local done, err = pcall(o.bind, app.keys, "App Binder: " .. (app.name or app.id),
      function() activate(app) end)
    if done then
      table.insert(bound, app.keys)
    else
      o.notify("App Binder: could not bind " .. app.keys .. ": " .. tostring(err))
    end
  end
end

rawset(_G, "__app_binder_bound", bound)
