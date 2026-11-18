# In-game join interface (experimental source)

Join Multiplayer opens an X4 menu with saved servers, manual IP/hostname entry,
Player name, status, Request to join and cancellation. Hosting continues through
the existing in-game Host action. Both platform packages use the same Lua source.

The intended sequence is request admission, receive approval where required,
sync a compatible server snapshot, validate it, load it, then complete the native
handshake. A separate window or manual save copying is not the player workflow.
The coordinator must not report a loadable snapshot before authorization and
integrity checks. A name is a visible label, not proof of identity or admin rights.
Current native packets accept 1-32 ASCII letters, digits, underscores or hyphens
for the Player name. The setting is stored in X4's local UI user data.

## Dependencies and limits

This source needs the matching `x4mp_join` API-v1 bridge from X4Native and a
compatible background coordinator. Install/configure those through the platform
package's deployment process; they must not require a separate player interface.
The bridge's README defines its local IPC contract. A missing bridge produces an
in-game service-unavailable error; legacy immediate Join must not bypass sync.
Native X4MP must be configured for the coordinator's snapshot slot and transport.

The interface is not a complete public multiplayer service. Verified identities,
admin admission queues, secure snapshot transfer and server discovery require
compatible server implementation. Selecting a display name cannot grant authority.
The current development adapter accepts preconfigured authenticated profiles only.
Cancellation covers waiting/sync/validation; loading and full disconnect/reconnect
still depend on the native lifecycle. Readiness must come from the definitive
universe-generated event, including after UI reload, rather than a player-ID poll.

Run `tests/join_menu.lua` with LuaJIT for menu/state regressions. Native builds,
visual UI acceptance and a live connected world are separate checks. The source
is a draft until the coordinator is packaged and Windows/Linux runtime acceptance
is complete; do not merge the UI alone into a release lacking its dependencies.
