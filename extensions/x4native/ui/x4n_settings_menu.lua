-- X4Native — Extension settings injector
--
-- Adds custom rows to the vanilla Settings -> Extensions -> "..." submenu
-- for extensions that declared a "settings" array in their x4native.json.
--
-- Strategy (see docs/rev/EXTENSION_SETTINGS_UI.md for the full analysis):
--   1. Find the OptionsMenu in the global `Menus` table.
--   2. Pull the `config` upvalue out of `menu.displayOptions` so we can
--      mutate `config.optionDefinitions["extensionsettings"]`.
--   3. Wrap `menu.submenuHandler` — on every entry into "extensionsettings",
--      strip previously-injected rows and re-inject this extension's rows.
--
-- The injection is idempotent and tagged (`__x4n = true`) so vanilla rows
-- are untouched on shutdown/hot-reload.

-- Requires the x4native API handle exported by x4native.lua.
local api = _G.__X4NATIVE_API
if not api then
    DebugError("X4Native settings menu: __X4NATIVE_API not set — skipping")
    return
end

-- "Yes" / "No" / "Enabled" / "Disabled" labels reused from the vanilla menu.
local TEXT_YES      = ReadText(1001, 2617)
local TEXT_NO       = ReadText(1001, 2618)
local TEXT_ENABLED  = ReadText(1001, 12642)
local TEXT_DISABLED = ReadText(1001, 12641)

local INJECT_TAG = "__x4n"

-- ---------------------------------------------------------------------------
-- Lookup helpers
-- ---------------------------------------------------------------------------

local function find_options_menu()
    if type(Menus) ~= "table" then return nil end
    for _, m in ipairs(Menus) do
        if m and m.name == "OptionsMenu" then return m end
    end
    return nil
end

-- Retrieve the `config` local upvalue of menu.displayOptions.
--
-- X4 nils the `debug` global in its Lua environment. The debug library is
-- still available via require("debug") in LuaJIT, though, so load it
-- lazily and cache the result.
local _debug
local function load_debug()
    if _debug ~= nil then return _debug end
    local ok, lib = pcall(require, "debug")
    _debug = (ok and type(lib) == "table") and lib or false
    if not _debug then
        DebugError("X4Native settings menu: debug library unavailable — cannot access upvalues")
    end
    return _debug
end

local function get_config_upvalue(fn)
    if type(fn) ~= "function" then return nil end
    local d = load_debug()
    if not d or not d.getupvalue then return nil end
    for i = 1, 100 do
        local name, val = d.getupvalue(fn, i)
        if not name then return nil end
        if name == "config" then return val end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Row builders — one per setting type. Each returns an option table in the
-- shape menu.displayOption() understands (see ego_gameoptions/gameoptions.lua).
-- ---------------------------------------------------------------------------

local function current_settings_for(ext_id)
    if not api.get_extension_settings then return {} end
    local ok, result = pcall(api.get_extension_settings, ext_id)
    if not ok or type(result) ~= "table" then return {} end
    return result
end

local function build_toggle(ext_id, s)
    return {
        id        = "x4n_" .. s.id,
        name      = s.name,
        valuetype = "button",
        [INJECT_TAG] = true,
        value = function()
            local rows = current_settings_for(ext_id)
            for _, r in ipairs(rows) do
                if r.id == s.id then
                    return r.current and TEXT_ENABLED or TEXT_DISABLED
                end
            end
            return TEXT_DISABLED
        end,
        callback = function()
            local rows = current_settings_for(ext_id)
            local current = false
            for _, r in ipairs(rows) do
                if r.id == s.id then current = r.current; break end
            end
            api.set_extension_setting(ext_id, s.id, not current)
        end,
    }
end

local function build_slider(ext_id, s)
    return {
        id        = "x4n_" .. s.id,
        name      = s.name,
        valuetype = "slidercell",
        [INJECT_TAG] = true,
        value = function()
            local rows = current_settings_for(ext_id)
            local startv = s.default
            for _, r in ipairs(rows) do
                if r.id == s.id then startv = r.current; break end
            end
            return {
                min       = s.min,
                max       = s.max,
                step      = s.step or 1,
                start     = startv,
                minSelect = s.min,
                maxSelect = s.max,
            }
        end,
        callback = function(value)
            api.set_extension_setting(ext_id, s.id, value)
        end,
    }
end

local function build_dropdown(ext_id, s)
    return {
        id        = "x4n_" .. s.id,
        name      = s.name,
        valuetype = "dropdown",
        [INJECT_TAG] = true,
        value = function()
            local rows = current_settings_for(ext_id)
            local current = s.default
            local opts = {}
            if s.options then
                for i, o in ipairs(s.options) do
                    opts[i] = { id = o.id, text = o.text, icon = "",
                                displayremoveoption = false }
                end
            end
            for _, r in ipairs(rows) do
                if r.id == s.id then current = r.current; break end
            end
            return opts, current
        end,
        callback = function(_, selected_id)
            api.set_extension_setting(ext_id, s.id, selected_id)
        end,
    }
end

local ROW_BUILDERS = {
    toggle   = build_toggle,
    slider   = build_slider,
    dropdown = build_dropdown,
}

-- ---------------------------------------------------------------------------
-- Injection
-- ---------------------------------------------------------------------------

local function strip_injected(defs)
    local i = #defs
    while i > 0 do
        if defs[i] and defs[i][INJECT_TAG] then
            table.remove(defs, i)
        end
        i = i - 1
    end
end

local function inject_for(menu, config)
    local defs = config and config.optionDefinitions
                 and config.optionDefinitions["extensionsettings"]
    if not defs then return end
    strip_injected(defs)

    local ext = menu.selectedExtension
    if not ext or not ext.id then return end

    local rows = current_settings_for(ext.id)
    if type(rows) ~= "table" or #rows == 0 then
        if api.log then
            api.log(0, "Settings menu: no rows for ext '" .. tostring(ext.id) .. "'")
        end
        return
    end

    -- Visual separator from the vanilla rows.
    table.insert(defs, { id = "line", [INJECT_TAG] = true })

    local added = 0
    for _, r in ipairs(rows) do
        local builder = ROW_BUILDERS[r.type]
        if builder then
            table.insert(defs, builder(ext.id, r))
            added = added + 1
        end
    end
    if api.log then
        api.log(1, "Settings menu: injected " .. tostring(added)
                    .. " row(s) for ext '" .. tostring(ext.id) .. "'")
    end
end

-- ---------------------------------------------------------------------------
-- Installation
-- ---------------------------------------------------------------------------

local installed = false

local function install()
    if installed then return true end
    local menu = find_options_menu()
    if not menu then return false end

    local config = get_config_upvalue(menu.displayOptions)
    if not config or not config.optionDefinitions
       or not config.optionDefinitions["extensionsettings"] then
        DebugError("X4Native settings menu: could not access OptionsMenu.config upvalue")
        return false
    end

    local orig_handler = menu.submenuHandler
    if type(orig_handler) ~= "function" then return false end

    menu.submenuHandler = function(optionParameter)
        if optionParameter == "extensionsettings" then
            inject_for(menu, config)
        end
        return orig_handler(optionParameter)
    end

    installed = true
    if api.log then api.log(1, "Settings menu injector installed") end
    return true
end

-- Try immediately; if OptionsMenu isn't loaded yet, retry on UI-init events.
if not install() then
    local function try_install()
        if install() then
            -- All retries armed via RegisterEvent; once installed, do nothing.
        end
    end
    RegisterEvent("gfx_ok", try_install)
    RegisterEvent("show",   try_install)
end
