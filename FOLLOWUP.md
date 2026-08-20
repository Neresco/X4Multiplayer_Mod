# X4MP — Player-Action Replication (Follow-up Design)

> Status: **transport done + validated.** Specific actions are next.
> This is the second half of the multiplayer system. The first half
> (NPC-ship sync / reconciliation) is complete — see STATE.md 2026-08-16.

## Goal
Make player actions (shoot, build, trade, board, ...) performed on any client
**real for everyone**, with the **host as the authority**. Today only the
client's PLAYER position is shared; a client-built station or a client's shot
exists only in that client's local universe.

## Architecture (5 steps)
1. **Detect** — the client's local sim performs an action (fire/build/...).
2. **Send** — client sends `ACT <type> <params...>` to the host over the
   control channel (UDP 7777).
3. **Execute** — the host runs the action authoritatively in its universe.
4. **Broadcast** — the host streams the resulting state (new/changed objects)
   to all clients over the data stream (TCP 7778).
5. **Apply** — clients reconcile the result using the existing binding/ghost
   machinery (a new station appears for everyone; a destroyed ship vanishes).

Steps 4-5 largely reuse the NPC-sync reconciliation already built.

## DONE (this session)
- **Action transport (step 2)**: client -> host `ACT` channel.
  - Client: `net_send` of `ACT <type> <params>\n`; test trigger
    `X4MP_TEST_ACTION=1` sends a periodic `ACT test n=<tick>` every ~5s.
  - Host: `process_message` handles `ACT`, refreshes liveness, logs
    `[ACT] from <ip> (id=<n>): <msg>`.
  - VALIDATED: host log shows `ACT test n=...` arriving every ~6.5s from the
    client (id=1); client stays stable (no FATAL).

## COMPLETED THIS SESSION (2026-08-19/20)

### Phase B — Building: client->host (ACT BUILD) + host->client (STA) DONE
- **Client->host** (`ACT BUILD`): implemented earlier — the client reports its
  new PF stations (baseline at ready, re-sent every ~10 s, host dedupes via
  `spawned[seq]`, spawns a ghost under the client's ghost faction, removes on
  disconnect). Host-side verified: spawns + dedupe working.
- **Host->client** (`STA`): NEW this session — the mirror direction.
  - Host: `g_host_station_baseline` computed once at universe-ready (the save's
    PF stations). Every ~10 s the host re-enumerates PF stations; any that are
    NOT in the baseline (host player builds) are streamed to all clients as
    `STA <id> <sectormacro> <x> <y> <z> <yaw> <pitch> <roll> player <macro>`.
  - Client (`x4mp_stream`): parses `STA`, spawns a station ghost ONCE when the
    client is in that sector (zone-limited, `is_station` RemoteObj), never
    binds (stations are static + not in the ship index), no per-frame updates.
  - Re-sent each cycle so the client's 30 s stale-drop never removes it; the
    zone-cleanup removes the RemoteObj+ghost when the client leaves the sector
    (re-spawns on return).
  - Verified: host `station baseline: 0` (save_009 has no PF stations), no
    false STA, streaming healthy.

### Phase A — Combat: kill + player-death propagation DONE (v1)
- **Detection** uses typed MD events (`md_subscribe_before`, type IDs from
  `sdk/sdk/x4_md_events.h`), NOT polling or x4n::hook:
  - `KilledData` type **237**: source_id = killed, raw_event+0x18 = killer.
  - (`AttackStarted` 32 / `AttackStopped` 33 exist too, unused in v1 — see
    limitation below.)
- **Client (`x4mp_stream`)**: `on_md_killed` captures (killer,killed) with pure
  memory reads (worker-thread safe); `process_md_kills` runs on the main thread
  in `on_frame_update`, builds `PlayerShipIDs` once, and:
  - player killed a ship -> `ACT KILL <host_id>` (host_id via reverse scan of
    `g_bindings`),
  - player's own ship died -> `ACT PLAYERDIED` (NEVER RemoveComponent locally —
    that aborts to the menu).
  - ACT lines are queued (`g_pending_acts`) and raised to x4mp (`x4mp.send_act`)
    which sends them over the control channel.
- **Host (`x4mp`)**: `process_message` ACT branch:
  - `ACT KILL <host_id>` -> `RemoveComponent(host_id)`, drop from
    `g_host_only_objects`, broadcast `KILL <host_id>` to all clients (data
    channel -> x4mp_stream).
  - `ACT PLAYERDIED` -> remove this client's ghost (`g_client_ships[key]`),
    relay `PLAYERDIED <key>` to the OTHER clients.
- **Clients apply** (`x4mp_stream` render_pass): `KILL`/`PLAYERDIED` lines queue
  into `g_kill_q`; render_pass removes the RemoteObj's spawned ghost AND its
  bound local ship (PlayerShipIDs-guarded so the player's own ship is never
  removed).
- **v1 limitation — no targeted attack orders on Linux**: the exported
  `CreateOrder3` takes no target parameter; targets are set via
  `SetOrderParamInternal`, which is only resolvable through a Windows-specific
  byte-signature DB (`native/version_db/internal_functions.json`, no Linux
  build exists). So we replicate the terminal combat events (kills + player
  death) rather than each shot. Damage and projectile visuals are not synced;
  only kills propagate. Full shot/attack-order replication requires a Linux
  internal-function DB (CreateOrderInternal/SetOrderParamInternal) + a hull
  setter — future work.

### Phase C — Trading: player cargo replication DONE (v1)
- **Model**: diff-based cargo sync. Each client fully simulates its own sector
  (stations + trading) locally, so the player can already trade; this replicates
  the resulting **cargo state** so every participant's view of the player's ship
  converges.
- **Client (`x4mp_stream`)**: `maybe_send_cargo()` polls the player ship's cargo
  (`GetNumCargo`/`GetCargo`, `tags=""`) every ~5 s (main thread, gated to
  active clients). On change it raises `ACT CARGO <count> <ware> <amt> ...` to
  x4mp, which sends it over the control channel. Only sends when the ship
  actually carries cargo (a flaky empty read can't clear the ghost).
- **Host (`x4mp`)**: `process_message` ACT `CARGO` branch converges the sender's
  ghost cargo via `host_apply_cargo` (diff: `AddTradeWare` buys / `DropCargo`
  sells) and re-broadcasts `CARGO <key> <count> <ware> <amt> ...` to the OTHER
  clients (keyed by the sender's relay key, like PLAYERDIED).
- **Other clients (`x4mp_stream`)**: `parse_line` `CARGO` queues the snapshot;
  `render_pass` applies it to their ghost of that player (`apply_cargo_to_ghost`).
- **v1 limitation — credits NOT synced**: there is no exported API to read the
  player's credit balance or set an NPC ghost faction's money pool
  (`AddPlayerMoney` only affects the local player). Trading's cargo side is
  consistent; credit consistency is future work (needs a credits API / Linux RE).

### Phase C2 — Trading (credits) *(NOT yet implemented)*
Blocked on a credits read/set API (see limitation above).

### Phase D — Boarding: capture propagation DONE (v1)
- **Model**: replicate the boarding *result* (a capture = the boarded ship
  becoming player-owned), not the multi-phase boarding operation itself (marines,
  interior combat, phases — that needs host-side `CreateBoardingOperation` +
  state sync, future work).
- **Detection**: MD `EntityChangedOwner` (type **175**). On the main thread,
  `process_owner_changes` reads each entity's new owner macro (`GetOwnerDetails2`)
  and, if it equals the player faction (`GetOwnerDetails2(GetPlayerObjectID())`),
  treats it as a capture. If the entity is a bound ship (has a host_id) it sends
  `ACT CAPTURE <host_id>`.
- **Host**: `ACT CAPTURE` -> `SetComponentOwner(host_id, client's ghost faction)`
  (makes the capture authoritative) + broadcasts `CAPTURE <host_id> <faction>`.
- **Clients**: apply `SetComponentOwner` to their copy (bound local or ghost).
- Loot (captured cargo) is covered by the cargo sync; the boarding *animation/
  operation* is not replicated (the boarder sees it locally).

### Phase D2 — Boarding operation enablement DONE (local) + peer replication pending
- **Local boarding enabled in thin-client mode**: ships are inert (`INERT=1`),
  which stops the local sim of a boarded ship and would block a boarding.
  Client subscribes to MD `BoardingOperationStarted` (41) / `Removed` (40);
  `process_boarding_events()` exempts the involved ship from inert
  (`ActivateObject(true)` + `g_boarding_exempt` skip in the 3 inert sites) so the
  local boarding runs, then re-inerts on removal. Worker-thread-safe capture;
  PlayerShipIDs-guarded (never touches the player's ship).
- **Capture result propagates** (Phase D, `ACT CAPTURE`) so all clients see the
  ship change hands.
- **NOT yet implemented**: recreating the boarding *operation* (marines/phases)
  on OTHER clients — needs host-side `CreateBoardingOperation`/
  `AddAttackerToBoardingOperation` + phase sync (MD `BoardingPhaseChanged` 42).
  Other clients see the capture, not the boarding animation. The SDK DOES export
  the full boarding API (verified in `x4_game_func_list.inc`).
- **Caveat**: the inert exemption relies on the MD event's `source_id` being the
  boarded ship. Needs in-game testing (I can't drive the game); refine the
  target-identification if the exemption misses the right ship.

## Boarding / flicker notes
- **Port separation (user question)**: redirecting boarding/stations/trading to
  separate ports is feasible but does NOT fix the ship-stream flicker (the flicker
  is reconciliation churn in the OBJ/PLAYER/FULL stream, independent of how the
  low-rate action messages are multiplexed). On LAN over TCP the streams are
  ordered + reliable, so interleaving causes no gaps. Consolidated single-connection
  design retained.
- **Flicker mitigation (this session)**: raised `g_missing_prune_ms` 10 s -> 30 s
  (aligned with the ghost stale threshold) so ships trading in/out of the rendered
  sector or briefly disagreeing on sector do not trigger prune->respawn churn.

## Highway-speed flicker + glide convergence
- **Symptom**: on the highway (15 km/s, many sector transitions every 20-40 s),
  ships flickered. Live `[FLK]` showed `spawn=136`/`zone=229` bursts per sector
  crossing, and `[CONVERGE] maxbind` up to **447 km** — greedy convergence
  *instant-snapped* diverged local ships to host positions (a teleport).
- **Root cause**: the client's local sim moves ships independently; on sector
  entry the host ships have moved kilometres from the local copies, so the one-
  time reconciliation was a visible teleport.
- **Fix (glide convergence)**: a bound ship diverged by **<= `X4MP_GLIDE_MAX`
  (default 20 km)** now *glides* to the host position at **`X4MP_GLIDE_SPEED`
  (default 1500 m/s)** instead of snapping (~13 s for a 19 km ship). Far
  (offscreen) ships still snap. The glide start position is `o.px`, guarded from
  the parse-time interpolation reset while `o.gliding` is set. Verified in log:
  `[DBG] GLIDE host=81307 local=79844 ... dist=19083m`.
- **Simulation mode (launcher)**: the client launcher now offers
  **THIN-CLIENT** (`X4MP_INERT=1`, ships inert + host-driven — the default,
  smoothest) vs **HYBRID** (`X4MP_INERT=0`, local sim runs for ships, reconciled
  to the host). The glide applies to both.

## Action types (phased, each = detect + execute + broadcast)

### Phase C — Trading
- Detect: a player trade completed on the client.
- Send: `ACT trade <partner> <ware> <amount> <price>`.
- Host: apply the trade to the host's economy; broadcast the changed cargo/
  credit state.

### Phase D — Boarding
- Detect: a player boarding action.
- Send: `ACT board <target_macro> <target_pos>`.
- Host: run the boarding op; broadcast the outcome (captured/looted/repulsed).

## Key challenges
1. **Action detection** — reliable, low-overhead detection that the player
   performed an action. Prefer SDK hooks (`x4n::hook::before/after`) over
   polling. The SDK has a rich ship-order API (`x4n_ship.h`: order_attack,
   order_trade_routine, ...) and a hook system (`x4n_hooks.h`).
2. **Target mapping** — client local IDs -> host IDs. Reuse the reconciliation
   binding (macro + nearest) already used for ships.
3. **Authority & preview** — the client shows a local preview instantly; the
   host's result is authoritative and corrected on the next broadcast. Avoid
   double-applying (client local effect + host broadcast).

## Consolidated TCP: now the DEFAULT (X4MP_LEGACY_NET=0), verified

Both extensions default to consolidated mode (one port per transport:
TCP 7778 or UDP 7777). Verified with zero env overrides: host listens on
7778, client connects, handshake OK, full=1 link=1, bindings active,
1 reload cycle, 0 Game Over, host ~27 fps with clients=1.
Legacy split-port mode remains available via `X4MP_LEGACY_NET=1`
(launcher prompt: "legacy").

Final deployed md5s: x4mp.so `23a39c95b6e5a99e2082428159afd337`,
x4mp_stream.so `13130b8a2f2081a9856a47b244d84df8`.
Release tarball (x4mp-release.tar.gz) rebuilt with these.

## Consolidated-TCP reconnect-loop debugging (2026-08-18/19)

### Fixed: ~10 s reconnect loop (EBADF)
Symptom: host `send error fd=35 errno=9 (Bad file descriptor)` every ~10 s,
client `recv=0` + reconnect, host `g_clients` grew to 156 (never pruned),
net_update degraded 1 ms -> 8 ms/frame.

Fix (deployed, verified stable 28+ min vs ~10 s cycle before):
- **Accept dedupe**: on `accept()`, close+erase any stale entry with the same
  peer IP (a reconnect used to leave the old entry alive forever).
- **Dead-entry cleanup** (%300): consolidated TCP entries with `tcp_fd < 0`
  are unrecoverable (reconnect = fresh accept) and are now erased.
- **Full close-site tracing**: every `close()` of a socket we own goes
  through `net_close_fd(fd, site)` which logs `CLOSE fd=N site=...`.
- **FD-table dumps** (`net_dump_fds`): on accept, on EBADF, and every %300
  ticks — `/proc/self/fd` snapshot so a silent fd death is bracketed.
- **Prune-check logging**: the %300 prune block now logs it runs.

Note: the original silent fd closer was never positively identified (all
x4mp.cpp close sites are now logged; the stale-entry lifecycle above was the
only structural anomaly). If the loop ever returns, the CLOSE/FD_TABLE logs
will name the culprit immediately.

### Fixed: FULL lines dropped in consolidated mode
The client's line router only forwarded OBJ/PLAYER to the x4mp_stream event
bridge; `FULL 1` went to process_message and was discarded. Result:
g_full_received stayed 0, greedy convergence + missing-ship prune never ran.
FULL is now routed to the bridge. Also: `on_stream_data` now refreshes
g_last_recv_any (link_alive), which recv_loop did in legacy mode.

### Known issues (follow-up, not regressions)
- **Client ghost ships never spawn on the host**: SpawnObjectAtPos2 fails
  (`Failed to retrieve owner faction with name 'x4mp_client_N'`) — the
  per-client factions are never registered as real game factions. cur_sector
  still works (falls back to host player sector), so streaming is unaffected.
- **Client player sector drifts on its own** after load (observed
  1145 -> 1559 -> 1327 over ~18 min, no user input, autofly/pause/teleport
  all off). Player ship is correctly excluded from binding. Suspect
game-side behaviour after load (queued jump / docking artifact). Capture
  with X4MP_DEBUG=1 (logs client PLAYER sends).
- Host fps with 1 client in sector: ~25-30 (high-sim cost, known/accepted).

## Suggested next steps (in order)
1. Explore the SDK hook system + weapon/projectile detection (research).
2. Implement Phase A (combat) end-to-end as the reference implementation.
3. Generalize the detect->send->execute->broadcast pattern to B/C/D.
4. Add an `ACT` result/broadcast message type for the host->clients direction.

## Env vars (follow-up)
- `X4MP_TEST_ACTION` **0** — 1 = client sends a periodic test ACT (transport
  validation; leave off in use).

## Ownership + enumeration fixes (2026-08-19, session 2)

### Issue 1: ghost factions never spawned ("Failed to retrieve owner faction")
SpawnObjectAtPos2 requires an EXISTING faction. The old fake factions
(x4mp_host / x4mp_client_N) don't exist, so every player-ship ghost failed to
spawn — neither player could ever see the other's ship.
Fix: ghosts use REAL factions, picked deterministically from the sorted
real-faction list (same save -> same list on every machine):
- F_HOST = first faction (host's own player-ship ghost, PLAYER 0)
- F_CLIENT_N = faction index N (client N's player-ship ghost)
- The picker skips the faction the player currently PILOTS (campaign saves:
  the player pilots a foreign "alliance" ship — using it would make the
  host's ghost look like the client's own ship).
- Faction is computed LAZILY at PLAYER/ghost time, never at JOIN time (JOINs
  arrive before the host's universe exists -> empty faction list -> "player"
  fallback bug). Empty = "defer", retried next message.

### Issue 2: 2048-ships-per-faction enumeration cap
GetAllFactionShips was called with a fixed 2048-entry stack buffer at ~9
sites (x4mp + x4mp_stream); large factions silently lost ships, so host FULL
snapshots were incomplete. Fix: enumerate_faction_ships/stations helpers size
the heap buffer from GetNumAllFactionShips/Stations. Host now indexes all
~84k ships ("refreshed ALL ships: 84456").

### Issue 3: client station builds -> host universe (ACT BUILD)
New protocol: client scans player-faction stations every ~10 s (baseline =
the save's stations at ready time, so only NEW builds are reported) and sends
`ACT BUILD <seq> <macro> <pos> <rot> <sector_macro>` (re-sent every cycle;
host dedupes via spawned[seq]). Host spawns the station ghost under the
client's ghost faction in the mapped sector, marks it host-only (never
streamed back to the builder), and removes ghosts when the client leaves.

### Issue 4: client sees host's ships as own — two real bugs found
a) **g_bound_locals leak**: dropping a RemoteObj because its sector differs
   from the client's (zone cleanup) never released its binding -> the local
   ship stayed in g_bound_locals forever -> prune skipped it -> stale frozen
   ships accumulated. Fixed: zone-drop now erases the binding pair.
b) **Index duplicates**: rebuild_local_index filled the index with duplicate
   entries (the same ship is returned by multiple factions' enumerations —
   includehidden aliases). index=158 was really ~10-40 unique ships; the
   duplicates matched the few real bindings and masked the leak. Fixed:
   dedupe during index build ("dupes dropped" logged).
Fleet reassignment (hide the host's PF fleet on the client) is implemented
but correctly SKIPS campaign saves where the player pilots a foreign faction
— there, PF ships ARE the player's own ships.

### Verification status
- Ghost spawn: verified on host ("HOST spawned client ghost ... faction=argon").
- Enumeration: verified (84k ships, no cap).
- ACT BUILD: implemented; functional test needs a user-built station.
- bound_locals leak + index dupes: instrumented (prune-skip counters);
  verifying in current run.
