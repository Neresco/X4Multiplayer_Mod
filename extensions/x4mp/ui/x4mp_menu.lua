-- X4MP - Multiplayer menu integration
--
-- Adds "Host Multiplayer" / "Join Multiplayer" entries to the X4 main menu
-- (OptionsMenu). Clicking a button triggers the native x4mp bridge:
--
--   Lua (this file)  -> api.raise_event("x4mp_host_request")
--     C++ (x4native) -> dispatches to event bus
--       C++ (x4mp)   -> on_host_request() -> NewMultiplayerGame()
--
-- The same pattern applies for "x4mp_join_request" (with the server IP as arg).
--
-- Menu injection strategy:
--   The main menu is the vanilla "OptionsMenu" (gameoptions.lua). Its options
--   live in `config.optionDefinitions["main"]`, where `config` is a local
--   upvalue of menu.displayOptions. We pull that upvalue (same trick as
--   x4n_settings_menu.lua) and append two rows to the main menu. We then wrap
--   menu.submenuHandler to intercept our custom submenu names and trigger the
--   host/join actions instead of navigating.
--
-- IMPORTANT: this file may execute BEFORE x4native.lua sets
-- _G.__X4NATIVE_API. We therefore do NOT fail at load time when the API is
-- missing; instead we retry on every UI-init event until the API appears.

local api = _G.__X4NATIVE_API

local TEXT_HOST = "Host Multiplayer"
local TEXT_JOIN = "Join Multiplayer"

local function server_address()
    local addr = os and os.getenv and os.getenv("X4MP_SERVER_IP")
    if addr and addr ~= "" then return addr end
    return "192.168.1.16"
end

-- ---------------------------------------------------------------------------
-- Trigger helpers (round-trip through the x4native bridge)
-- ---------------------------------------------------------------------------

local function trigger_host()
    if api and api.log then api.log(1, "X4MP menu: requesting HOST") end
    -- Call the C++ event directly. The x4mp extension subscribes to
    -- "x4mp_host_request" via api->subscribe(). api.raise_event() dispatches
    -- through the core event bus to all matching subscriptions.
    pcall(function()
        api.raise_event("x4mp_host_request")
    end)
end

local function trigger_join()
    local addr = server_address()
    if api and api.log then api.log(1, "X4MP menu: requesting JOIN -> " .. tostring(addr)) end
    -- Call the C++ event directly. The x4mp extension subscribes to
    -- "x4mp_join_request" via api->subscribe(). api.raise_event() dispatches
    -- through the core event bus to all matching subscriptions.
    pcall(function()
        api.raise_event("x4mp_join_request", addr)
    end)
end

-- ---------------------------------------------------------------------------
-- Menu injection (OptionsMenu upvalue pattern)
-- ---------------------------------------------------------------------------

local function find_options_menu()
    if type(Menus) ~= "table" then return nil end
    for _, m in ipairs(Menus) do
        if m and m.name == "OptionsMenu" then return m end
    end
    return nil
end

local _debug
local function load_debug()
    if _debug ~= nil then return _debug end
    local ok, lib = pcall(require, "debug")
    _debug = (ok and type(lib) == "table") and lib or false
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

local installed = false

local function install()
    if installed then return true end

    -- Refresh the API handle in case it was set after this file loaded.
    api = _G.__X4NATIVE_API
    if not api then return false end

    local menu = find_options_menu()
    if not menu then return false end

    local config = get_config_upvalue(menu.displayOptions)
    if not config or type(config) ~= "table" then
        if api.log then api.log(0, "X4MP menu: could not access OptionsMenu.config upvalue") end
        return false
    end

    local main_defs = config.optionDefinitions and config.optionDefinitions["main"]
    if type(main_defs) ~= "table" then
        if api.log then api.log(0, "X4MP menu: main optionDefinitions not found") end
        return false
    end

    -- Remove any previously injected rows (idempotent).
    for i = #main_defs, 1, -1 do
        local o = main_defs[i]
        if o and (o.id == "x4mp_host" or o.id == "x4mp_join") then
            table.remove(main_defs, i)
        end
    end

    -- Append our two rows to the main menu.
    table.insert(main_defs, {
        id = "x4mp_host",
        name = TEXT_HOST,
        submenu = "x4mp_host",
    })
    table.insert(main_defs, {
        id = "x4mp_join",
        name = TEXT_JOIN,
        submenu = "x4mp_join",
    })

    -- Wrap submenuHandler to intercept our custom submenus.
    local orig_handler = menu.submenuHandler
    if type(orig_handler) == "function" then
        menu.submenuHandler = function(optionParameter)
            if optionParameter == "x4mp_host" then
                -- Defer the host call by 0.1s using the same pattern the game
                -- itself uses (gameoptions.lua line 13413). Calling
                -- NewMultiplayerGame synchronously from the menu handler
                -- crashes the game. The C++ bridge calls it with the correct
                -- 2-arg signature (modulename, difficulty).
                if type(Helper) == "table" and Helper.addDelayedOneTimeCallbackOnUpdate then
                    Helper.addDelayedOneTimeCallbackOnUpdate(function()
                        trigger_host()
                    end, true, getElapsedTime() + 0.1)
                else
                    trigger_host()
                end
                return
            elseif optionParameter == "x4mp_join" then
                trigger_join()
                return
            end
            return orig_handler(optionParameter)
        end
    end

    installed = true
    if api.log then api.log(1, "X4MP menu: main-menu buttons installed") end
    return true
end

-- Try immediately; retry on UI-init events if the menu isn't loaded yet.
if not install() then
    local function retry()
        if install() then
            -- installed; nothing else to do
        end
    end
    pcall(function()
        RegisterEvent("gfx_ok", retry)
        RegisterEvent("show",    retry)
    end)
end

-- ---------------------------------------------------------------------------
-- THIN CLIENT: pause/unpause the local simulation on command from C++.
-- The host is authoritative; the client must NOT simulate. C++ raises
-- "x4mp.pause" / "x4mp.unpause" (via api->raise_lua_event) to freeze/thaw
-- the local universe so we only render host-streamed state.
-- ---------------------------------------------------------------------------
pcall(function()
    RegisterEvent("x4mp.pause", function()
        local a = _G.__X4NATIVE_API
        if type(Pause) == "function" then
            Pause()
            if a and a.log then a.log(1, "X4MP: client simulation PAUSED (Pause() called)") end
        else
            if a and a.log then a.log(1, "X4MP: Pause() NOT available in this environment") end
        end
    end)
    RegisterEvent("x4mp.unpause", function()
        local a = _G.__X4NATIVE_API
        if type(Unpause) == "function" then
            Unpause()
            if a and a.log then a.log(1, "X4MP: client simulation UNPAUSED") end
        end
    end)
    -- Debug: enumerate which Lua game-API functions are available for object
    -- enumeration (so we know what the host can use to stream the universe).
    -- The game exposes its API via global tables like C, Helper, MD, and also
    -- as globals. Probe all of them.
    RegisterEvent("x4mp.debug_api", function()
        local a = _G.__X4NATIVE_API
        local function dump(tblname)
            local t = _G[tblname]
            if type(t) ~= "table" then
                if a and a.log then a.log(1, "X4MP: table [" .. tblname .. "] is " .. type(t)) end
                return
            end
            local keys = {}
            for k, v in pairs(t) do
                if type(k) == "string" then table.insert(keys, k) end
            end
            table.sort(keys)
            if a and a.log then a.log(1, "X4MP: table [" .. tblname .. "] has " .. #keys .. " keys") end
            local interesting = {}
            for _, k in ipairs(keys) do
                if k:find("Object") or k:find("Sector") or k:find("Zone") or k:find("Ship")
                   or k:find("GetPlayer") or k:find("GetComponent") then
                    table.insert(interesting, k)
                end
            end
            if #interesting > 0 then
                if a and a.log then a.log(1, "X4MP: [" .. tblname .. "] object/sector keys: " .. table.concat(interesting, ", ")) end
            end
        end
        dump("C")
        dump("Helper")
        dump("MD")
    end)
end)