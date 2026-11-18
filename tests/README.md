# In-game join menu regression

From this repository's root, execute `tests/join_menu.lua` with LuaJIT 2.1.
It stubs the game/GUI boundaries and runs the actual shared Lua implementation.
No game assets, sockets or desktop input are needed.

The regression covers rebuilding the main menu after its definitions are
replaced, repeated installation without duplicate controls, original Host
delegation, a late legacy menu installer, request-before-sync ordering,
stale/cancelled verification, duplicate load prevention, invalid saves and retry.
Run it against all packaged copies or verify they are byte-identical.

Runtime acceptance still requires opening the picker and resizing/reopening
menus inside X4, then observing an authorized host snapshot sync and native
universe readiness. The UI requires the optional `x4mp_join` native bridge and
a compatible background coordinator; it does not implement admin authorization.
