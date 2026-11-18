-- Shared Windows/Linux in-game join UI. No OS APIs, external dialogs, or
-- snapshot I/O here: the join service reports verified state through X4Native.
local ffi = require("ffi")
local C = ffi.C
pcall(ffi.cdef, "const char* GetUserData(const char* name);")
pcall(ffi.cdef, "void SetUserData(const char* name, const char* value);")
pcall(ffi.cdef, "void SaveUIUserData(void);")
pcall(ffi.cdef, "void ReloadSaveList(void);")
pcall(ffi.cdef, "bool IsSaveListLoadingComplete(void);")
pcall(ffi.cdef, "bool IsSaveValid(const char* filename);")

local function saved(key, fallback)
    local ok, value = pcall(function() return ffi.string(C.GetUserData("x4mp.join." .. key)) end)
    return (ok and value ~= "") and value or fallback
end
local function save(key, value) C.SetUserData("x4mp.join." .. key, tostring(value)) end
local state = {
    phase = saved("phase", "idle"), id = saved("id", ""),
    address = saved("address", ""), message = saved("message", "Select a server or enter its address."),
    player_name = saved("player_name", "Player"),
    servers = {}, selected = "manual", reload = false,
}
local service_seen = false
local function busy()
    return state.phase ~= "idle" and state.phase ~= "error" and
        state.phase ~= "cancelled" and state.phase ~= "disconnected"
end
local function set_status(phase, message)
    state.phase, state.message = phase, message
    save("phase", phase); save("message", message)
end
local function api() return _G.__X4NATIVE_API end
local function send(name, value)
    local bridge = api()
    if not bridge then set_status("error", "Multiplayer support is not available."); return false end
    local ok = pcall(bridge.raise_event, name, value)
    if not ok then set_status("error", "The join service could not be reached.") end
    return ok
end
local function request()
    if busy() then return end
    if not service_seen then
        set_status("error", "The multiplayer join service is not available."); return
    end
    if #state.player_name < 1 or #state.player_name > 32 or state.player_name:find("[^A-Za-z0-9_-]") then
        set_status("error", "Use 1-32 letters, numbers, underscores or hyphens for your player name."); return
    end
    local address = state.address:match("^%s*(.-)%s*$")
    if address == "" or #address > 253 or address:find("[^%w%.:%-_]") then
        set_status("error", "Enter a server IP address or hostname."); return
    end
    local counter = (tonumber(saved("counter", "0")) or 0) + 1
    save("counter", counter)
    state.id = "join-" .. counter
    state.address = address; state.reload = false
    save("id", state.id); save("address", address)
    set_status("requesting", "Requesting to join. Waiting for the server...")
    send("x4mp.join_flow.request", state.id .. "|" .. address)
end
local function cancel()
    if not busy() or state.phase == "loading" or state.phase == "connected" then return end
    send("x4mp.join_flow.cancel", state.id)
    -- Retiring the ID immediately prevents a late verification reply loading a
    -- cancelled world, even if a transfer finishes at the same instant.
    state.id = ""; save("id", "")
    set_status("cancelled", "Join cancelled. You can choose another server.")
end

RegisterEvent("x4mp.join_flow.session", function(_, value)
    service_seen = true
    value = tostring(value or "")
    if value ~= saved("session", "") then
        save("session", value)
        state.id = ""; state.reload = false; save("id", "")
        set_status("idle", "Select a server or enter its address.")
    end
end)

RegisterEvent("x4mp.join_flow.servers", function(_, value)
    local servers = {}
    for line in tostring(value or ""):gmatch("[^\r\n]+") do
        local id, name, address = line:match("^([%w_-]+)|([^|]+)|([%w%.:%-_]+)$")
        if id and #name <= 100 and #address <= 253 then
            servers[#servers + 1] = {id = id, text = name, address = address, icon = "", displayremoveoption = false}
        end
    end
    state.servers = servers
end)
RegisterEvent("x4mp.join_flow.status", function(_, value)
    local id, phase, message, endpoint, slot = tostring(value or ""):match("^([^|]*)|([^|]+)|([^|]*)|([^|]*)|([^|]*)%s*$")
    if not id or state.id == "" or id ~= state.id or state.phase == "cancelled" then return end
    if phase == "verified" then
        if state.phase == "loading" or state.phase == "connected" then return end
        if slot ~= "save_001" or endpoint == "" or endpoint:find("[^%w%.:%-_]") then
            set_status("error", "The server returned an unsupported join target."); return
        end
        state.endpoint, state.slot = endpoint, slot
        if not state.reload then C.ReloadSaveList(); state.reload = true end
        set_status("verified", "Snapshot verified. Preparing to load the universe...")
    elseif phase == "connected" or phase == "error" or phase == "disconnected" or
            phase == "requesting" or phase == "waiting" or phase == "syncing" or phase == "validating" then
        if state.phase == "loading" and phase ~= "connected" and phase ~= "error" and phase ~= "disconnected" then return end
        set_status(phase, message)
    end
end)

local debuglib = require("debug")
local function configuration(fn)
    for i = 1, 100 do
        local name, value = debuglib.getupvalue(fn, i)
        if not name then break end
        if name == "config" then return value end
    end
end
local function rows(config)
    local main = config.optionDefinitions.main
    -- Reapply on every display, even after a resize replaces the definitions.
    for i = #main, 1, -1 do
        if main[i].id == "x4mp_host" or main[i].id == "x4mp_join" then table.remove(main, i) end
    end
    main[#main + 1] = {id = "x4mp_host", name = "Host Multiplayer", submenu = "x4mp_host"}
    main[#main + 1] = {id = "x4mp_join", name = "Join Multiplayer", submenu = "x4mp_join"}
    config.optionDefinitions.x4mp_join = {
        name = "Join Multiplayer",
        {id = "x4mp_server", name = "Saved server", valuetype = "dropdown",
            value = function()
                local options = {{id = "manual", text = "Enter address", icon = "", displayremoveoption = false}}
                for _, server in ipairs(state.servers) do options[#options + 1] = server end
                return options, state.selected
            end,
            selectable = function() return not busy() end,
            callback = function(_, id)
                state.selected = id
                for _, server in ipairs(state.servers) do
                    if server.id == id then state.address = server.address; save("address", state.address) end
                end
                for _, menu in ipairs(Menus) do
                    if menu.name == "OptionsMenu" then menu.displayOptions("x4mp_join"); break end
                end
            end},
        {id = "x4mp_address", name = "Server IP / hostname"},
        {id = "x4mp_player_name", name = "Player name"},
        {id = "x4mp_status", name = "Status"},
        {id = "x4mp_request", name = "Join", valuetype = "button", value = "Request to join",
            selectable = function() return not busy() end, callback = request},
        {id = "x4mp_cancel", name = "Cancel", valuetype = "button", value = "Cancel request",
            selectable = function() return busy() and state.phase ~= "loading" and state.phase ~= "connected" end,
            callback = cancel},
    }
end
local function install()
    for _, menu in ipairs(Menus or {}) do
        if menu.name == "OptionsMenu" then
            if menu.__x4mp_join then rows(menu.__x4mp_join.config); return end
            local config = configuration(menu.displayOptions)
            if not config or not config.optionDefinitions or not config.optionDefinitions.main then return end
            local original_display, original_option, original_submenu = menu.displayOptions, menu.displayOption, menu.submenuHandler
            menu.__x4mp_join = {config = config}
            menu.displayOptions = function(option)
                rows(config)
                return original_display(option)
            end
            menu.displayOption = function(ftable, option, numcols)
                if option.id == "x4mp_address" or option.id == "x4mp_player_name" then
                    local is_name = option.id == "x4mp_player_name"
                    local label = is_name and "Player name" or "Server IP / hostname"
                    local row = ftable:addRow(option, {})
                    row[2]:createText(label, config.standardTextProperties)
                    row[3]:setColSpan(3):createEditBox({height = config.standardTextHeight,
                        active = function() return not busy() end, description = label})
                        :setText(is_name and state.player_name or state.address, {fontsize = config.standardFontSize})
                    row[3].handlers.onTextChanged = function(_, text)
                        if is_name then state.player_name = text; save("player_name", text)
                        else state.address = text; save("address", text) end
                    end
                    row[3].handlers.onEditBoxDeactivated = function() C.SaveUIUserData() end
                elseif option.id == "x4mp_status" then
                    local row = ftable:addRow(false, {})
                    row[2]:setColSpan(4):createText(function() return state.message end,
                        {fontsize = config.standardFontSize, wordwrap = true})
                else return original_option(ftable, option, numcols) end
            end
            menu.submenuHandler = function(option)
                if option == "x4mp_join" then
                    send("x4mp.join_flow.poll")
                    return menu.displayOptions(option)
                end
                return original_submenu(option)
            end
            rows(config)
            DebugError("[X4MP JOIN] in-game menu installed")
        end
    end
end
local timer_started = false
local function tick()
    install()
    send("x4mp.join_flow.poll")
    if state.phase == "verified" and state.reload and C.IsSaveListLoadingComplete() then
        if C.IsSaveValid(state.slot) then
            set_status("loading", "Loading the synced universe and connecting...")
            send("x4mp_set_player_name", state.player_name)
            -- The original native join handler queues the save load through the
            -- game's UI callback; never mutate the game from a network worker.
            send("x4mp_join_request", state.endpoint)
        else set_status("error", "X4 could not load the synced snapshot. Please retry.") end
    end
    Helper.addDelayedOneTimeCallbackOnUpdate(tick, true, getElapsedTime() + 1)
end
local function start()
    install()
    if not timer_started and Helper and Helper.addDelayedOneTimeCallbackOnUpdate then
        timer_started = true
        Helper.addDelayedOneTimeCallbackOnUpdate(tick, true, getElapsedTime() + 1)
    end
end
_G.__X4MP_OPEN_JOIN = function()
    install()
    for _, menu in ipairs(Menus or {}) do
        if menu.name == "OptionsMenu" and menu.__x4mp_join then
            send("x4mp.join_flow.poll")
            return menu.displayOptions("x4mp_join")
        end
    end
    DebugError("X4MP: options menu is not ready for the join interface.")
end
RegisterEvent("show", start)
RegisterEvent("gfx_ok", start)
start()
