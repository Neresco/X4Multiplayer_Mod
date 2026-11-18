-- Run with LuaJIT from the repository root. Stub only game/GUI boundaries;
-- exercise the shipped menu implementation and the real callback ordering.
local userdata, events, sent, delayed = {}, {}, {}, {}
local valid = true
local reloads = 0
package.loaded.ffi = { C = {
    GetUserData = function(k) return userdata[k] or "" end,
    SetUserData = function(k,v) userdata[k] = v end,
    ReloadSaveList = function() reloads = reloads + 1 end,
    IsSaveListLoadingComplete = function() return true end,
    IsSaveValid = function() return valid end,
}, cdef = function() end, string = function(v) return v end }
function RegisterEvent(name, fn) events[name] = fn end
function DebugError() end
function getElapsedTime() return 1 end
Helper = {addDelayedOneTimeCallbackOnUpdate = function(fn) delayed[#delayed + 1] = fn end}
__X4NATIVE_API = {raise_event = function(name, value) sent[#sent + 1] = {name, value} end}
local config = {optionDefinitions = {main = {{id="vanilla"}}}}
local menu = {name = "OptionsMenu", displayOption = function() end,
    submenuHandler = function(name) sent[#sent + 1] = {"original", name} end}
menu.displayOptions = function(name) return config.optionDefinitions[name] end
Menus = {menu}
dofile("extensions/x4mp/ui/x4mp_join_menu.lua")
for _, row in ipairs(config.optionDefinitions.x4mp_join) do
    if row.id == "x4mp_request" then row.callback() end
end
assert(userdata["x4mp.join.phase"] == "error" and #sent == 0, "missing service failed open")
events["x4mp.join_flow.session"](nil, "test-session")
local function count(id)
    local n = 0
    for _, row in ipairs(config.optionDefinitions.main) do if row.id == id then n = n + 1 end end
    return n
end
local function option(id)
    for _, row in ipairs(config.optionDefinitions.x4mp_join) do if row.id == id then return row end end
    error("missing " .. id)
end
local function tick() local fn = table.remove(delayed, 1); assert(fn); fn() end
local function joins()
    local n = 0
    for _, event in ipairs(sent) do if event[1] == "x4mp_join_request" then n = n + 1 end end
    return n
end
assert(count("vanilla") == 1 and count("x4mp_join") == 1 and count("x4mp_host") == 1)
for i=1,5 do events.gfx_ok(); menu.displayOptions("main") end
assert(count("x4mp_join") == 1 and count("x4mp_host") == 1)
config.optionDefinitions.main = {{id="vanilla"}}
menu.displayOptions("main")
assert(count("x4mp_join") == 1 and count("x4mp_host") == 1, "resize lost controls")
menu.submenuHandler("x4mp_host")
assert(sent[#sent][1] == "original", "host action replaced")
events["x4mp.join_flow.servers"](nil, "test|Test server|127.0.0.1")
option("x4mp_server").callback(nil, "test")
option("x4mp_request").callback()
assert(sent[#sent][1] == "x4mp.join_flow.request" and sent[#sent][2] == "join-1|127.0.0.1")
assert(joins() == 0, "join preceded snapshot sync")
events["x4mp.join_flow.status"](nil, "wrong|verified|ready|127.0.0.1|save_001")
tick(); assert(joins() == 0 and reloads == 0, "stale reply accepted")
option("x4mp_cancel").callback()
events["x4mp.join_flow.status"](nil, "join-1|verified|ready|127.0.0.1|save_001")
tick(); assert(joins() == 0, "cancelled reply loaded world")
option("x4mp_request").callback()
assert(sent[#sent][2] == "join-2|127.0.0.1")
events["x4mp.join_flow.status"](nil, "join-2|verified|ready|127.0.0.1|save_001")
tick(); assert(joins() == 1 and reloads == 1, "verified snapshot was not joined")
events["x4mp.join_flow.status"](nil, "join-2|verified|ready|127.0.0.1|save_001")
tick(); assert(joins() == 1, "duplicate join")
events["x4mp.join_flow.status"](nil, "join-2|error|disconnected||")
option("x4mp_request").callback()
valid = false
events["x4mp.join_flow.status"](nil, "join-3|verified|ready|127.0.0.1|save_001")
tick(); assert(joins() == 1, "invalid save joined")
assert(userdata["x4mp.join.phase"] == "error")
print("PASS: menu rebuild/idempotence, host delegation, request ordering, stale/cancel/duplicate replies, invalid save and retry")
-- Reproduce the actual load order: the legacy installer retries after the
-- join UI is already installed. Its wrapper must still open the picker.
__X4NATIVE_API.log = function() end
local callbacks = events
function RegisterEvent(name, fn)
    local prior = callbacks[name]
    callbacks[name] = function(...) if prior then prior(...) end; return fn(...) end
end
dofile("extensions/x4mp/ui/x4mp_menu.lua")
menu.submenuHandler("x4mp_join")
assert(joins() == 1, "legacy wrapper bypassed snapshot sync")
assert(config.optionDefinitions.x4mp_join.name == "Join Multiplayer")
print("PASS: late legacy installer delegates to in-game picker without immediate join")
events["x4mp.join_flow.session"](nil, "fresh-game-process")
assert(userdata["x4mp.join.phase"] == "idle" and userdata["x4mp.join.id"] == "", "new process retained stale join intent")
print("PASS: new game process resets persisted join phase without losing the server address")
