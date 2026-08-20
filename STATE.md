# X4 Multiplayer Mod — Session State & Next Steps

> Saved 2026-08-08 (before a PC restart). Read this before continuing.

## 0. CURRENT STATE (latest, 2026-08-20) — read this first

**Architecture:** hybrid/thin-client reconciliation over a single consolidated TCP
connection (7778). The host streams every ship in each client's sector; the client
binds them to its local ships and pins them to the host's interpolated position.

**Simulation mode (client) — THIN-CLIENT is now the STANDARD:**
- `X4MP_INERT=1` (default): ships are inert + driven purely by the host stream
  (no local AI). Smoothest sync — **the highway flicker is gone.**
- `X4MP_INERT=0`: HYBRID — the local sim keeps running for ships and is
  reconciled to the host (can flicker).
- Chosen in the launcher ("Simulation mode"), thin-client = option 1 (standard).

**Glide convergence (fixes the highway sector-entry teleport):** on sector entry a
bound ship diverged <= `X4MP_GLIDE_MAX` (20 km) glides in at `X4MP_GLIDE_SPEED`
(1500 m/s) instead of teleporting; far (offscreen) ships snap. `g_missing_prune_ms`
is 30 s (aligned with the ghost stale threshold).

**Features (thin-client build):**
- ✅ Core sync: player position, ships, other players (ghosts), camera snap — flicker-free.
- ✅ Stations both directions (host→client `STA`, client→host `ACT BUILD`).
- 🟡 Trading cargo (`CARGO`) — deployed, needs in-game testing. (Credits not synced.)
- 🟡 Combat kills + player death (`KILL`/`PLAYERDIED`) — deployed, needs testing.
- 🟡 Boarding: the player can board + capture (local); the capture result
  propagates (`ACT CAPTURE`/`CAPTURE`). Thin-client inert exemption
  (`BoardingOperationStarted`/`Removed` MD events) lets the local boarding run.
  The boarding marines/phase animation is NOT recreated on other clients.
- ⚪ Not implemented: shot/projectile replication, trading credits, full boarding
  operation on peers (all need Linux SDK RE or host-side `CreateBoardingOperation`).

**Deployment:** source of truth is this machine (192.168.1.101). Build locally,
scp `.so` + `x4mp_run.sh`/launcher to 192.168.1.16. Both machines run the game
with `-showfps -nocputhrottle`. Current `x4mp_stream.so` md5 `01e9307e...`.

**To test the 🟡 items:** board a ship with cargo + trade (trading), kill a ship
(combat), board + capture a ship (boarding).

---

## 1. What is this project
Turn X4: Foundations (singleplayer) into a LAN multiplayer setup:
- **Machine 2 (192.168.1.16)** runs as HOST (server).
- **Machine 1 (192.168.1.101)** runs as CLIENT and joins by IP.
- Both machines render a window (menu-driven host/join).
- Uses the game's exported functions `NewMultiplayerGame()` / `ConnectToMultiplayerGame()`
  (RakNet transport, no Steam needed — no-Steam dev file is used).
- Bridge is the `x4native` C++ extension (loaded by the game) + `x4mp` extension.

## 2. IMPORTANT — CRITICAL BUG FIXED (do not revert)
**The game crashed (SIGSEGV) whenever `NewMultiplayerGame` was called, and whenever
the resolution was changed.** Root cause: a cross-instance race in the x4native
**proxy** (`libx4native_64.so`). Multiple proxy instances were all
`copy_file()`-ing to the SAME `x4native_core_live.so` path concurrently,
corrupting the file before `dlopen`/`dlsym` — crashing when a worker thread
("Movement worker", spawned by NewMultiplayerGame or a resolution change)
re-entered `load_core()`.

**Fix applied** in `X4-C++-Extension-Linux/source-code/X4Native/src/proxy/proxy.cpp`:
- `load_core()` now `dlopen()`s the ORIGINAL `x4native_core.so` directly
  (no copy to a shared live path).
- `core_needs_reload()` now returns `false` (no live copy to compare).
- Added a `std::recursive_mutex` around core load/reload/destructor (defensive).

**This fixed BOTH crashes.** Verified: game stays alive after `NewMultiplayerGame`,
host socket stays active, resolution changes no longer crash.

**Deployed:** `X4 Foundations/extensions/x4native/native/libx4native_64.so`
(backup of the old one kept as `libx4native_64.so.bak`).

## 3. Other findings
- The shim (`libshim/vkshim.c`, LD_PRELOAD) and `VK_ICD_FILENAMES` (forcing radv)
  are **NOT needed** for normal rendering. The game works fine with its default
  Vulkan driver. The launch scripts still load the shim + force radv — **cleanup pending**.
- The game's built-in Lua has **NO `os.getenv`** (`os.getenv = nil`). Lua cannot read
  env vars. Only the C++ extension can read env vars. (This is why the Lua-side
  auto-host attempt failed.)
- The game loads saves via the Lua global `LoadGame(filename)` or the C function
  `ContinueGameStart()`. The game also has a `loadSave` Lua event that calls
  `LoadGame`. Save files live in `~/.config/EgoSoft/X4/save/` (e.g. `save_010.xml.gz`).
- Valid gamestart IDs are in `libraries/gamestarts.xml` (e.g.
  `x4ep1_gamestart_boron1`, `x4ep1_gamestart_terran1`, ...).

## 4. Current state of each file
| File | State |
|------|-------|
| `X4-C++-Extension-Linux/.../src/proxy/proxy.cpp` | MODIFIED (crash fix). Rebuilt + deployed. |
| `X4-C++-Extension-Linux/.../examples/x4mp/x4mp.cpp` | MODIFIED (reads `X4MP_SAVE`, prevents auto-host when save set). Rebuilt + deployed. **Save-loading itself NOT yet implemented in C++.** |
| `X4 Foundations/extensions/x4mp/ui/x4mp_menu.lua` | REVERTED to clean (menu buttons only). No auto-host logic (os.getenv doesn't work). |
| `x4mp_launcher.sh` | NEW interactive launcher (role / IP / gamestart / save). Works. |
| `test_minimal.sh` | NEW test launcher (no shim, no radv, auto-host). |
| `dedicated_server.sh` / `connect_client.sh` | CLEANED: shim (LD_PRELOAD) and VK_ICD_FILENAMES removed. Use default Vulkan driver. |

## 5. SAVE LOADING — NOW WORKING (2026-08-08)
**Save loading for multiplayer is implemented and verified working.**
Flow implemented in `x4mp.cpp`:
- Reads `X4MP_SAVE` into `g_save`.
- When `X4MP_AUTO=host` and `X4MP_SAVE` is set:
  - Waits until `g_game->IsSaveListLoadingComplete()` returns true (game/save list ready).
  - Raises the game's `loadSave` Lua event via `api->raise_lua_event("loadSave", g_save.c_str())`
    (this calls `LoadGame`).
  - Subscribes to `on_game_loaded`; when it fires, calls `do_host()`.

**CRITICAL: the save filename must be WITHOUT the `.xml.gz` extension**
(e.g. `save_010`, NOT `save_010.xml.gz`). `C.IsSaveValid()` rejects the extension.
The launcher now strips the extension automatically.

Verified in log: save list ready → game loaded → "save loaded — hosting now" →
`NewMultiplayerGame` invoked → host socket active → heartbeat HOST active.

**Deployed:** `X4 Foundations/extensions/x4mp/native/x4mp.so` (rebuilt).
`x4mp_launcher.sh` updated to strip the extension.

## 6. Build commands
```bash
# x4native proxy (crash fix already applied)
cd /home/lunarbuntu/Programming/x4-pack/X4-C++-Extension-Linux/source-code/X4Native
cmake --build build
cp native/libx4native_64.so "/home/lunarbuntu/Programming/x4-pack/X4 Foundations/extensions/x4native/native/"

# x4mp extension
cd /home/lunarbuntu/Programming/x4-pack/X4-C++-Extension-Linux/source-code/X4Native/examples/x4mp
cmake --build build
cp build/x4mp.so "/home/lunarbuntu/Programming/x4-pack/X4 Foundations/extensions/x4mp/native/"
```

## 6b. CLIENT FIX — JOIN TIMING + RETRY (2026-08-09)
**Problem:** client called `ConnectToMultiplayerGame` at extension init (too early),
before the game reached the start menu -> "Failed to initialize the network engine".
It never retried.
**Fix (deployed):** client now waits 20s (game reaches menu at ~14s) before the first
join, then retries every ~5s until `on_game_loaded` fires (client loaded host universe)
or 240 attempts (~20 min). Uses wall-clock delay (NOT `IsSaveListLoadingComplete`,
which returns true immediately at init and is NOT a menu-ready signal).
**Verified:** client waits exactly 20s (init 10:55:24 -> first join 10:55:44).

## 6c. CURRENT BLOCKER — HOST NOT LISTENING (2026-08-09)
Scanning 192.168.1.16 from Machine 1: host pings (0.24ms) but NO ports are open
(6000-6100, 7777, 2302, 27015, 9000-50000 all closed). The host is NOT actually
hosting / the RakNet socket is NOT bound. Likely causes:
- Machine 2 has the OLD x4mp.so (no save-loading fix) -> with a save selected,
  nothing hosts (old code waited for Lua that never fired).
- OR the host process isn't running / crashed.

**To verify/fix host:** deploy the LATEST x4mp.so to Machine 2 (see deploy script),
start the host, and check the host log for:
  "x4mp: NewMultiplayerGame invoked; RakNet host socket active"
  "x4mp: heartbeat — HOST active"
Then re-scan ports from Machine 1 to confirm a socket is bound.

## 6d. CUSTOM NETWORK TRANSPORT — WORKING (2026-08-09)
**DECISION: the built-in SLNet multiplayer does NOT work** (its network engine fails
with "Failed to initialize the network engine (mode 1/2)" — needs Steam). So we
wrote our OWN UDP netcode in x4mp.cpp, completely independent of SLNet.

**Architecture (authoritative server -> thin client):**
   HOST  runs the ENTIRE universe simulation and streams snapshots to clients.
   CLIENT does NOT simulate the universe; it only syncs with the host and renders
   what it needs. Goal: offload universe calculation from client to server.

**Layer 1 (transport) is DONE and VERIFIED WORKING:**
   - Host binds a raw UDP socket on X4MP_PORT (default 7777).
   - Client connects to host IP:port, sends JOIN, host replies WELCOME.
   - VERIFIED: host log "net: HOST listening on UDP port 7777"; client log
     "net: CONNECTED to host (handshake OK)" (repeated as the game reloads the
     extension during startup — expected).
   - Code: custom UDP in x4mp.cpp (net_init_host/client, net_poll, net_update).

**IMPORTANT environment findings (Machine 2 = VM):**
   - Xvfb does NOT work: radv can't present on Xvfb (no DRI3) -> game hangs
     (processes stay ~30-40MB, never load). MUST use the real Xwayland display :0.
   - The XAUTHORITY for :0 is at /run/user/1000/.mutter-Xwaylandauth.<rand> (NOT
     in HOME). x4mp_run.sh now finds it via `find /run/user/$(id -u)`.
   - Game loading can take up to 600s (VM is resource-constrained; the model runs
     on Machine 1 + Machine 2 over RPC, spiking CPU to 99%).
   - Force radv via VK_ICD_FILENAMES (default picks lavapipe which crashes).

## 6e. LAYER 2 SYNC PROTOCOL — WORKING (2026-08-10)
**VERIFIED bidirectional sync between Machine 1 (client) and Machine 2 (host):**
   - HOST -> CLIENT: player-state snapshots. Client log:
       "SNAP id=1272361 pos=(-114194.0, 363.8, 16879.9) rot=(-1.1,0,0) hosttick=12570"
       "SNAP id=1272361 pos=(131107.1, 363.5, -14239.8) rot=(-1.0,0,0) hosttick=12720"
     Position is LIVE and CHANGING between snapshots -> real-time state streaming.
   - CLIENT -> HOST: input/commands. Host log:
       "HOST got INPUT from 192.168.1.101: INPUT tick=270"
   - Message formats (text, one line):
       SNAP <playerid> <x> <y> <z> <yaw> <pitch> <roll> <hosttick>\n
       INPUT tick=<clienttick>\n
   - Host reads state via game func table: GetPlayerObjectID() +
     GetObjectPositionInSector(). Sends every 30 frames. Client stores it in
     g_snap_* (Layer 3 will render it).

**CONCERN: repeated extension reloads.** The client reconnects every ~20s
("client joined id=28,29,30,31"; client re-gets CONNECTED). The game appears to
reload the extension periodically (socket closes+reopens). Sync resumes after
each reload, but this interrupts the stream. Investigate why the extension is
being reloaded (may stop once the universe is fully loaded).

## 6f. THIN CLIENT (OPTION B) — IN PROGRESS (2026-08-10)
**USER DECISION: Option B — true thin client.** Client does NOT simulate the
universe; it only syncs with the host and renders what it needs. No time
constraints.

**Phase 1 DONE — reload loop fixed.** Root cause: the client called the built-in
SLNet `ConnectToMultiplayerGame`, which fails (needs Steam) and the game reloads
the UI every ~20s (re-initializing the extension, closing our socket). FIX: the
client NO LONGER joins via SLNet. Instead it loads the SAME save as the host
(X4MP_SAVE=save_010) to enter a universe, then syncs over our custom network.
Result: client init count dropped from 82+ to 2; client is stable and in universe.

**Phase 2 DONE (pause) — simulation offloaded.** On game loaded, the client
raises Lua event "x4mp.pause" -> x4mp_menu.lua calls Pause(). VERIFIED in log:
"X4MP: client simulation PAUSED (Pause() called)". The client no longer simulates
(AI/economy/combat run only on the host).

**Phase 2 (render) — client renders host state.** Host streams SNAP with zone:
   SNAP <playerid> <zoneid> <x> <y> <z> <yaw> <pitch> <roll> <hosttick>
Client parses it and calls MovePlayerToSectorPos(zone, pos) each frame
(thin_client_render) so the client's player follows the host's position.

**CONCERN: client CPU still ~82%.** The pause stops SIMULATION, but the client
still RENDERS the full universe (it loaded the save) + Machine 1 is shared with
the AI model. To truly reduce client load, the client must render ONLY
host-streamed objects (not the whole universe) — a Layer 3 refinement.

## 6g. DEBUG MODE + SYNC VERIFICATION (2026-08-10)
**X4MP_DEBUG=1** enables a continuous streamed-data display (writes to the x4mp
log AND stdout/terminal). Shows exactly what data is sent/received:
   HOST:   "x4mp: [DBG] HOST streaming player id=.. zone=.. pos=(..) rot=(..) tick=.."
   CLIENT: "x4mp: [DBG] CLIENT received host player id=.. zone=.. pos=(..) .. hosttick=.."
           "x4mp: [DBG] CLIENT applied player pos=(..) zone=.."

**SYNC IS REAL (verified).** Host streams pos=(-68809.8,5444.4,54420.3) zone=389537;
client applies the EXACT same pos+zone. The client follows the host's player.

**Loading timing does NOT cause mismatch:** the client connects to the host's
socket (binds at init, before universe loads) and only receives state once the
host's player is ready. The client always applies the host's latest streamed
state, so timing is irrelevant.

**REAL mismatch = different save files.** Machine 1's save_010 != Machine 2's
save_010 (different universe content). Client follows host's player but the rest
of the world is the client's own save. This is exactly what Option 2 solves.

## 7. Next planned steps (in order)
1. **DONE: Custom network transport (Layer 1)** — see 6d.
2. **DONE: Sync protocol (Layer 2)** — see 6e.
3. **DONE: Fix reload loop + client enters universe via save** — see 6f.
4. **DONE: Pause client simulation (offload)** — see 6f.
5. **DONE: Debug mode (X4MP_DEBUG=1) + sync verification** — see 6g.
6. **Layer 3 — Option 1 (intermediate)**: reduce client rendering load (lower
   view distance / hide distant objects) while it still loads the save.
7. **Layer 3 — Option 2 (goal)**: TRUE thin client — client does NOT load the
   save; renders ONLY host-streamed objects (max offload).
8. **Deploy to Machine 2**: copy the `X4 Foundations/extensions/x4native/` and
   `extensions/x4mp/` folders + the launcher/scripts to Machine 2.

## 8. Useful reference
- Save files: `~/.config/EgoSoft/X4/save/` (save_009.xml.gz, save_010.xml.gz).
- x4native logs: `~/.config/EgoSoft/X4/x4native/x4native.log`.
- Game log (when launched via script): `X4 Foundations/server_logs/game.log`.
- Test log (test_minimal.sh / manual): `X4 Foundations/test_logs/game.log`.
- The game takes ~20s to load extensions and up to ~180s to load a large save.
- Only ONE X4 instance can run at a time on a machine.

## 2026-08-11 — Option 1 intermediate step: client renders host-streamed objects (WORKS)
- Client now syncs the host's save (scp in x4mp_run.sh) and LOADS it (paused, no simulation).
- Client receives host OBJ stream (id, zone, sector, pos, macro) and SPAWNS the objects in its OWN player sector.
- KEY FIX 1: sector IDs are runtime-generated and DIFFER between host/client even with same save. So client creates objects in ITS OWN player sector (GetPlayerZoneID→GetContextByClass "sector"), using host's absolute positions (player placed at host pos → relative offsets match).
- KEY FIX 2: SpawnObjectAtPos2 needs a valid ownerid (e.g. "player"), NOT nullptr — nullptr makes it return 0 (silent fail).
- VERIFIED: 382 objects spawned, 0 failures. e.g. "CLIENT spawned host obj id=391621 macro=ship_arg_xs_pv_04_b_macro as client id=1472815 sector=388178".
- Client CPU 145% (rendering), host 216% (simulation). Offload working.
- Debug: X4MP_DEBUG=1 logs "[DBG] CLIENT spawned ..." / "[DBG] CLIENT render_objects: player_zone=.. client_sector=.. objs=..".
- STILL TODO (Option 2): hide client's OWN new-game/save objects so it renders ONLY host-streamed objects → lower client CPU. Currently client renders full universe + spawned host objects.

## 2026-08-13 — CLIENT SIGSEGV FIX + SERVER STALE-OBJECT PRUNE (deployed)

### Root cause of the client crash (SIGSEGV, "Movement worker" thread)
- Symptom: client crashed with `Speicherzugriffsfehler` ~2s after the SECOND
  `game_loaded` signal while loading save_010. `coredumpctl` showed:
  - Signal 11, crashing thread = **"Movement worker"** (TID 2178750), NOT main.
  - Stack entirely in the X4 binary, ending in
    `std::vector<float>::_M_realloc_append` (heap corruption during a vector
    realloc) — a classic data-race / use-after-free signature.
- Why: X4 loads saves in TWO passes. `on_game_loaded` fires after the FIRST
  pass (entity IDs valid, but universe NOT fully built). Our client marked
  itself ready on that first signal and started calling `SpawnObjectAtPos2` /
  `SetObjectSectorPos` (thin_client_render_objects) EVERY frame while the game
  was still in its SECOND pass, rebuilding the universe. Those main-thread
  calls raced with the game's background Movement worker thread, corrupting the
  object vectors → SIGSEGV.
- The second pass is X4's native save-loading behavior and is NOT optional. The
  correct "world ready" signal is `on_universe_ready` (fires on
  `event_universe_generated` AFTER the 2nd pass / all stations built).

### Fix (x4mp.cpp)
- Client no longer marks itself ready on `on_game_loaded`. It now waits for the
  new `on_universe_ready` handler (subscribed to the core's `on_universe_ready`
  event, raised via the x4native MD cue `x4native.universe_ready`).
  `g_client_ready` is only set in `on_universe_ready`, so host objects are only
  spawned/rendered once the universe is fully built → no race with the Movement
  worker.
- Server: `net_send_objects_host()` and `net_refresh_zone_objects()` now check
  `IsValidComponent()` and skip/prune stale (destroyed) object IDs. This stops
  the log flood of `GetContextByClass(): Failed to retrieve component with ID`
  / `GetObjectPositionInSector(): Failed to retrieve object with ID`.

### Files changed
- `X4-C++-Extension-Linux/.../examples/x4mp/x4mp.cpp` (rebuilt + deployed to
  client `X4 Foundations/extensions/x4mp/native/x4mp.so`).
- `x4mp_run.sh`, `x4mp_launcher.sh`: added X4MP_DEBUG passthrough + docs on the
  universe_ready gating / stale-ID pruning.
- STATE.md (this file).

### Next steps (connection stability, then performance)
1. CONNECTION STABILITY — the client currently reconnects / the socket is
   recreated on every extension reload, and there is no heartbeat/keepalive
   timeout or re-sync after a dropped packet. Investigate:
   - Why the extension/socket is reloaded periodically (was seen before).
   - Add a keepalive + timeout so a dead host is detected and the client
     retries cleanly instead of hanging.
   - Add sequence numbers / ACK for the control channel (JOIN/WELCOME) so a
     dropped handshake is retried.
2. NETWORK PERFORMANCE — the OBJ stream currently sends full text lines for
   every object every frame (cache mode) or enumerates all ~85k ships (full
   mode). Options:
   - Binary protocol (fixed-size structs) instead of ASCII text → ~10x less
     bandwidth and CPU for parsing.
   - Delta compression: only send objects whose position changed.
   - Only stream objects in the player's view radius, not the whole zone.
   - Rate-limit position updates (e.g. 10-20 Hz) instead of every frame.

## 2026-08-13 — TESTING STATUS + ENVIRONMENTAL FINDING
- Crash fix VERIFIED: client runs stable (no SIGSEGV) for 12+ min while
  receiving host OBJ/SNAP data. Before the fix it crashed within ~15s of the
  second game_loaded (Movement worker SIGSEGV). The client now correctly waits
  for on_universe_ready (or the X4MP_UNIVERSE_TIMEOUT fallback) before spawning.
- ENVIRONMENTAL ISSUE (Machine 1, not a code bug): the client machine is shared
  with the AI model (llama-server ~144% CPU) and its disk (nvme1n1) is saturated
  (~676GB written; X4 alone wrote 23GB). The client's save load / new-game
  universe generation stalls in wait_dev_flush (D state) for 10+ minutes, so
  game_loaded/universe_ready never fire in a reasonable time. This blocks
  full end-to-end render verification on Machine 1. On Machine 2 (host) the
  same save loads + reaches universe_ready in ~26s.
- Mitigation tried: renice llama-server to priority 15, X4 to -5 (helps CPU but
  not the disk I/O stall).
- To fully verify end-to-end rendering, run the client on a machine that is not
  disk/CPU saturated, or pause the AI model during the test.
- New env var: X4MP_UNIVERSE_TIMEOUT (seconds, default 180, 0=strict). Fallback
  that marks the client ready if on_universe_ready does not fire in time. Only
  takes effect after game_loaded has fired.

## 2026-08-13 — CONNECTION STABILITY (deployed + verified)
Added to x4mp.cpp (rebuilt + deployed to both machines):
- HOST: tracks per-client last-seen time and PRUNES dead clients after
  X4MP_HOST_TIMEOUT (default 30s). Verified: "pruned 1 dead client(s); 0 remain".
  Previously g_clients grew forever and the host streamed to crashed clients.
- HOST: a re-JOIN from an existing client refreshes liveness and re-sends
  WELCOME (handles client link drops).
- CLIENT: tracks last-received time from the host. If no data for
  X4MP_CLIENT_TIMEOUT (default 15s), it drops back to unconnected and re-sends
  JOIN to re-establish the handshake (handles host restart / link drop).
- PING/PONG keepalive: host sends PING every ~5s; client answers PONG.
- New env vars: X4MP_HOST_TIMEOUT, X4MP_CLIENT_TIMEOUT (seconds).
- VERIFIED end-to-end crash fix: client reached game_loaded -> universe_ready
  (safe path, not fallback) -> spawned host objects with NO crash.

### IMPORTANT TESTING NOTE
The client machine (Machine 1) is shared with the AI model (llama-server ~146%
CPU) and its disk (nvme1n1) is saturated. X4's save load / new-game generation
can stall for 10+ min in wait_dev_flush. When the load drops, the client works
fine (verified above). For reliable testing, reduce AI-model load or use a
less-loaded machine.

## 2026-08-13 — NETWORK PERFORMANCE (deployed)
Added to x4mp.cpp (rebuilt + deployed to both machines):
- RATE LIMITING: host now streams SNAP/OBJ at a configurable rate (default 15 Hz,
  X4MP_UPDATE_HZ, 1-60) instead of every frame at 60fps. ~4x less bandwidth/CPU.
- DELTA COMPRESSION: host only re-sends an object if it moved beyond
  X4MP_DELTA_M meters (default 0.5m), with a periodic forced full refresh. Most
  objects (stations, idle ships) are not re-sent every tick -> large bandwidth cut.
- New clients force a full object stream (delta state cleared on JOIN) so they
  receive the complete zone immediately.
- Client INPUT uplink rate-limited to the same update interval.
- New env vars: X4MP_UPDATE_HZ, X4MP_DELTA_M.

### Performance analysis / remaining ideas (not yet implemented)
- ASCII text protocol: each OBJ line ~100 bytes; 382 objects * 15 Hz ≈ 570 KB/s.
  A binary fixed-size struct protocol would cut this ~10x and remove sscanf CPU.
- View-radius streaming: only stream objects within the player's view distance
  instead of the whole zone (biggest possible win for large zones).
- Client-side: only spawn objects once and update via SetObjectSectorPos (already
  done); avoid re-parsing unchanged data.
- Consider UDP fragmentation: batch is capped at 60000 bytes (near the 65507
  UDP max). Fine for now, but a binary protocol would avoid fragmentation.

## 2026-08-15 — FULL-UNIVERSE SHIP STREAMING + SECTOR PLACEMENT (deployed)
Addressed the user's request to stream the host's REAL, complete universe state
(not just the player's current zone) with no duplicates.

### Host (x4mp.cpp)
- `net_refresh_zone_objects` now enumerates ALL ships across every sector
  (~85k), not just the player's zone. Positions streamed every frame from the
  cache with delta compression.
- STATIONS are intentionally NOT streamed: the client loads the SAME synced
  save and keeps its own stations, which preserve sector ownership/claims.
  Streaming stations would duplicate them on the client.
- Added `sector_macro` to `ZoneObj`; each OBJ line now carries the object's
  sector MACRO name so the client can place it in the matching local sector.
- OBJ format: `OBJ <id> <sectormacro> <x> <y> <z> <yaw> <pitch> <roll> <faction> <macro>`
  (multi-packet batching).

### Client (x4mp_stream.cpp)
- Added `sector_macro` to `RemoteObj`, `g_sector_map` (macro->local sector id),
  and `build_sector_map()` called on universe_ready.
- **CRITICAL FIX**: `get_macro()` must query the Lua API
  `GetComponentData(id,"macro")` (like the host), NOT `GetComponentName()`
  which returns DISPLAY names ("Argon Prime") that never match the host's
  streamed macros ("cluster_113_sector001_macro"). With the wrong lookup the
  map had only 2 sectors; with the Lua lookup it builds 139 sectors correctly.
- `render_pass` places each object in the mapped local sector (fallback: player
  sector). Objects spawn in the correct sectors.

### Verified (client + host both running stably)
- Client sector map: 139 sectors, correct macro names.
- Client spawns host ships across 110+ unique sectors, no SDL error / no crash.
- Host streams all ships; client cleanup removes its own ships (keeps stations).
- No duplicate stations (host doesn't stream them; client keeps its own).

### Remaining / not implemented
- Client->host simulation actions (shooting, building, trading) are NOT
  streamed to the host; only the client's PLAYER position is sent. The host's
  simulation does not reflect client actions.
- Task 3 (pending): refactor platform shims into platform/lin + platform/win.

## 2026-08-16 — HIGH SIMULATION PER RENDERING ZONE (deployed to both machines)

### Problem (from the 2026-08-15 20:54 client log)
- Client CRASHED: `AutoIDMap::Insert(): ID map is full` -> FATAL exit 1079.
  The thin-client mode spawned ghosts for the ENTIRE host universe
  (83k ships x ~30 sub-objects = ~2.5M objects), exhausting the game's ID map.
- The host fully simulated only the server player's zone (X4 default);
  client rendering zones were only "simulated" via the unreliable
  host-player-teleport hack. User requirement: the high-simulation value must
  apply to connecting clients too, so each client's own rendering zone is
  fully simulated and ships behave normally.

### New simulation model (the default now)
Every participant's rendering zone is fully simulated:
- **HOST** (x4mp.cpp): a HIGH-SIMULATION SECTOR SET = server player's sector
  + every connected client's current sector (tracked via PLAYER messages).
  `net_maintain_universe()` (every ~5s) ActivateObject()s all ships in those
  sectors + places a player-owned satellite in each. Same treatment the server
  player's zone gets by default, extended to client zones. Sector-macro
  lookups are deduplicated per pass (~140 Lua calls, not 85k).
- **CLIENT** (x4mp_stream.cpp + x4mp.cpp): the client keeps its OWN locally
  simulated universe (the synced save — cleanup is OFF by default now). X4
  natively fully simulates the client's current sector, so ships in the
  client's rendering zone behave normally. The client receives ONLY human
  PLAYER ghosts (host ship cid=0 + other clients), each now carrying its
  SECTOR MACRO so the ghost is rendered in the correct mapped sector and only
  when the client is actually in that sector.

### Zone-limited client rendering (fixes the ID-map crash)
- x4mp_stream render_pass now renders ONLY objects in the client's CURRENT
  sector. OBJ ghosts from other sectors are dropped (memory/ID-bounded).
  PLAYER ghosts are kept so they reappear when the client flies over.
- Even in thin-client mode (X4MP_STREAMSHIPS=1) the client now spawns only
  its current sector's ships (~hundreds), not 83k — the ID-map crash cannot
  recur.

### New / changed env vars (defaults in bold)
- `X4MP_STREAMSHIPS` **0** — 1 = legacy full-universe OBJ broadcast.
- `X4MP_FULLSIM` **0** (was 1) — 1 = ActivateObject ALL ships (CPU-heavy).
- `X4MP_TELEPORT` **0** — 1 = legacy host-player-into-client-sector teleport.
- `X4MP_CLEANUP` **0** (was 1 in x4mp_run.sh) — 1 = remove client's own ships.
- `X4MP_PAUSE` **0** (unchanged) — client sim runs (that IS the client's
  high simulation in its rendering zone).
- PLAYER wire format: `PLAYER <cid> <x> <y> <z> <yaw> <pitch> <roll> <macro> <faction> <sectormacro>`
  (10th field optional on receive; old 9-field hosts still work).

### Deployed
- x4mp.so (md5 9c37ffd8...) + x4mp_stream.so (md5 a32b8900...) on BOTH
  machines; sources + launchers synced to 192.168.1.16 (host source tree was
  stale before this — local is now the source of truth).
- x4mp_run.sh / x4mp_launcher.sh / x4mp_launch_both.sh updated (launch_both
  no longer forces X4MP_FULLSIM=1; its ship-count wait still works — the
  "refreshed ALL ships: N" debug line now reports the real ship count).

### Known limitation / next steps
- Client and host universes DIVERGE over time (client simulates locally, no
  reconciliation). Next: per-sector host_id<->local_ship binding (macro +
  proximity) with soft position correction (drift > threshold) so the client's
  rendering zone tracks the host's truth.
- Client->host actions (shooting/building/trading) still not streamed.

## 2026-08-16 (later) — FLICKER FIX: lifecycle reconciliation (Phases 1-4)

### Root cause of the remaining flicker (transition / "massive movement")
Position pinning fixed STEADY ships, but ships in TRANSITION still flickered.
Signature in the client `[FLK]` counters during highway flight: `zone` and
`spawn` huge and continuous (100-1400 / 100-700 per 15s), while
`stale`/`bindrel`/`death` ~0. Two compounding causes:
1. **Local-sim divergence**: inactive sectors simulate independently of the
   host. On re-entry, host ships can't bind to their (moved/docked) local
   counterparts within the fixed 20km converge radius -> they are GHOSTED
   (`spawn++`) instead of bound. (Measured divergences up to ~214-295 km.)
2. **Sector-transition churn**: on each jump the old sector's objects are
   dropped (`zone++`).
3. **Latent host bug**: when a client enters a sector the host hasn't indexed
   yet (maintenance pass pending), the host sent an EMPTY FULL -> the client
   would prune its whole local sector. (Latent: 10s prune grace > 5s index
   refresh, but fixed defensively.)

### The fix (all in x4mp_stream.cpp unless noted; deployed to both machines)
- **Phase 1 — persistent AI suppression (X4MP_INERT, now DEFAULT ON):**
  `rebuild_local_index()` deactivates (ActivateObject false) EVERY local ship
  in the sector on entry, so the client's own AI can't dock/move/destroy them
  and diverge. Bound ships + ghosts are also re-deactivated every pin pass.
  `X4MP_INERT=0` restores local AI.
- **Phase 2 — greedy convergence (X4MP_CONVERGE_GREEDY, default ON):** on
  sector entry (first FULL snapshot), each host ship binds to the NEAREST
  same-macro local ship with NO distance limit (was 20km). Diverged ships are
  SNAPPED to the host position (one-time, masked by the sector change) instead
  of ghosted. After convergence, the tight 1km bind radius applies for
  re-matching. This is the main transition-flicker fix.
- **Phase 3 — binding stability:** bindings are keyed by host id and only
  released when the local ship is truly invalid; prune keeps its 10s grace
  gated by full-snapshot + link-alive. (Mostly already in place.)
- **Phase 4 — smooth transitions:** no per-object fade API exists in the SDK,
  so smoothness comes from the cleaner binding (fewer ghosts, no flapping) +
  snap-on-entry (masked by the sector view change).
- **Host (x4mp.cpp):** empty-FULL is now gated on `g_last_index_rebuild >=
  c.cur_sector_set_time`, so a not-yet-indexed sector is never reported empty.
- **Diagnostics:** `[CONVERGE]` logs per sector entry (index/host/bound/ghost/
  maxbind distance); `[FLK]` per-15s mechanism rates. Both under X4MP_DEBUG=1.
- **Test hook (X4MP_AUTOFLY=1, OFF by default):** teleports the client player
  to a sequence of sectors to exercise transitions. NOTE: MovePlayerToSectorPos
  does NOT change the player zone when the player ship is docked (e.g. at the
  Prime Hub), so the auto-fly only works once the ship is in space. The
  sector-change code path is identical to the start-sector convergence, which
  IS validated.

### Verified (start sector, X4MP_DEBUG=1)
- `[CONVERGE] sector=.. index=222 host=214..241 bound=182..196 ghost=18..59
  maxbind=214..295km` — 75-92% of host ships bound to local ships; diverged
  ships (up to 295km) snapped, not ghosted. No FATAL / no ID-map crash.
- `[FLK]` in the static start system: `zone=0`, low `spawn`/`stale` (normal
  trader dock/undock mirrored from the host), no abnormal popping.
- Deployed md5: x4mp.so e4e69e7297c1a6fe79fc6af136f08422, x4mp_stream.so
  cfea0ad586471d989c1be929a0c103d8 (both machines match).

### New / changed env vars (client)
- `X4MP_INERT` **1** (was 0) — default ON now.
- `X4MP_CONVERGE_GREEDY` **1** (new) — greedy (no-radius) entry binding.
- `X4MP_AUTOFLY` **0** (new) + `X4MP_AUTOFLY_INTERVAL` **10** — test hook.
- `X4MP_CONVERGE_RADIUS` (default 20000) is now only used when greedy is OFF.

### Still to validate / next
- **User highway validation**: fly the highway with host+client; check
  `[CONVERGE]` (bound vs ghost) and `[FLK]` (spawn/zone should be far lower
  than the 100-700 / 100-1400 seen before). The auto-fly can't reproduce this
  (docked player), so this needs the user driving.
- **FOLLOW-UP (big): player-action replication.** Client actions (shoot/build/
  trade/board) -> host executes authoritatively -> broadcast result to all
  clients. This is what makes a client-built station (or shot) real for
  everyone. NPC-ship sync (this work) and player-action replication are the two
  halves of the multiplayer system.
  - **STARTED: the action transport (client -> host `ACT` channel) is DONE and
    VALIDATED** (host log shows `ACT test n=...` arriving from the client). See
    `FOLLOWUP.md` for the full design (5-step architecture, phased action types
    A=combat B=building C=trading D=boarding, key challenges, next steps).
    Env: `X4MP_TEST_ACTION=1` sends a periodic test ACT (off by default).
    Deployed md5 (with ACT transport): x4mp.so 4f281a5da6ce129850384ff084a298fc.

## 2026-08-17 — Interactive launcher + distribution package

### Launcher rewrite (`x4mp_launcher.sh`)
Rewrote the launcher to be friendly for humans. Features:
- Role select (HOST / CLIENT).
- HOST: new gamestart OR load an existing save (lists local saves).
- CLIENT: host IP + save picker. **Lists the host's saves over ssh** and lets
  you pick by number or name. **Transfers the save automatically** (scp from
  the host's `~/.config/EgoSoft/X4/save/`); on failure it prints the exact
  manual `scp` command and warns that a manual transfer is needed.
- **Extra X4 flags** prompt (e.g. `-nocputhrottle -showfps`) for both roles.
- **Logging** prompt: on/off + where to store log files.
- Prints a launch summary and confirms before starting.
- **`X4MP_GAME_DIR`** env (or place the script next to the "X4 Foundations"
  folder) so it works regardless of install location. (Applied to
  `x4mp_run.sh` too.)
- Bug fixed: `${ARR[$((n-1))].xml.gz}` was a *bad substitution* when picking a
  save by number (now `${ARR[$((n-1))]}` + normalize). ssh/scp stdin is guarded
  (`ssh -n`, `scp ... < /dev/null`) so they don't eat interactive input.
- Both host + client flows dry-run tested (abort before launch).

### Distribution package (`x4mp-release/` + `x4mp-release.tar.gz`, 887 KB)
Self-contained package to hand to other testers:
```
x4mp-release/
├── README.md        <- full manual (install + run + config + troubleshooting)
├── install.sh       <- copies extensions/ into your game dir (X4MP_GAME_DIR)
├── extensions/      <- x4native + x4mp + x4mp_stream (built .so + UI + xml)
└── scripts/         <- x4mp_launcher.sh (interactive) + x4mp_run.sh (env)
```
- Install: `X4MP_GAME_DIR="/path/to/X4 Foundations" ./install.sh`
  (or `cp -r extensions/* "<game>/extensions/"`).
- Run host: `X4MP_GAME_DIR=... scripts/x4mp_launcher.sh` -> role 1.
- Run client: same -> role 2, enter host IP, pick save (auto-transferred).
- The .so files in the package were verified (md5) to match the deployed builds.
- `x4mp_launch_both.sh` was NOT included (it's specific to this two-machine
  systemd+ssh setup, not general-purpose).

---

## 2026-08-17 — TCP/UDP CONSOLIDATION: one port per transport (implemented, untested)

### Goal
Standardize on TCP (reliability for upcoming stations/boarding/combat) and use
ONE port per transport: **TCP 7778** (default) or **UDP 7777** (secondary),
carrying control + data on a single connection. Keep the current working setup
(UDP 7777 control + TCP/UDP 7778 data) as a legacy fallback.

### Findings (A/B test, 1 client in sector)
- TCP host fps ~31.8, UDP host fps ~28.7 — **transport is NOT the FPS cause.**
- net_update is only ~3 ms of a ~35 ms frame (~9%). The rest is the game's own
  simulation (the high-sim: host simulating the client's sector ships).

### Design (Option A: x4mp owns the connection on both sides)
- **x4mp** = the networking extension (owns the socket on host AND client).
- **x4mp_stream** = pure reconciliation; receives OBJ/PLAYER lines via the
  `x4mp_stream.data` event (raised by x4mp); keeps `render_pass` unchanged.
- **TCP mode:** host LISTENS on 7778; client CONNECTS (conventional client->
  server, fixes the JOIN chicken-and-egg). Control (JOIN/PLAYER/INPUT/ACT/
  WELCOME/PING/SNAP) + data (OBJ/PLAYER-relay) all ride `c.tcp_fd`.
- **UDP mode:** control + data on 7777 (not yet wired; legacy UDP path kept).

### Changes (all gated behind `X4MP_LEGACY_NET`, default 1 = legacy)
- `x4mp.cpp`:
  - `g_legacy_net`, `g_listen_sock` (host TCP listener), `g_client_tcp_*` (client).
  - `net_init_host`: bind TCP listener on 7778 (new mode) instead of UDP 7777.
  - `net_init_client`: create TCP socket + connect to host 7778 (new mode).
  - `net_poll`: new-TCP case — host accepts per-client conns (NetClient created
    on ACCEPT) + recvs per `c.tcp_fd`; client recvs from `g_sock`, routes
    OBJ/PLAYER -> `x4mp_stream.data` event, WELCOME/PING -> process_message.
  - `net_send_ctrl`/`net_send_ctrl_host`/`net_send_client`: route control over
    `c.tcp_fd`/`g_sock` (new mode) or UDP 7777 (legacy). WELCOME/PING/SNAP use them.
  - `net_update`: don't bail on `g_sock<0` in new mode; skip host->client TCP
    connect; client reconnects on drop.
- `x4mp_stream.cpp`:
  - `on_stream_data` event bridge -> `parse_line`; `g_sub_data` subscription.
  - init: skip socket/recv when `X4MP_LEGACY_NET=0` (x4mp owns the connection).
- `x4mp_launcher.sh`: "Net mode" prompt (legacy / consolidated) + summary line.
- `x4mp-release/README.md`: transport section + config table (X4MP_TRANSPORT,
  X4MP_LEGACY_NET) + firewall note.

### Status
- **Both extensions compile clean; deployed to local + host (md5-verified).**
  Default is still LEGACY, so the current working setup is untouched.
- **NOT YET TESTED in-game** (needs both machines + a display; user at work).
- UDP consolidated mode (control+data on 7777) also implemented (host data via
  g_sock; client routes OBJ/PLAYER to the event; no separate data socket).
- New build md5: x4mp.so `dc3f58eceeb1dcb167d5889a57003c22`,
  x4mp_stream.so `15b7621c23489ccec070fc49bfaa8f38`.
- x4mp-release/ distribution package updated with the new .so files.

### To test (when both machines are up)
1. Host: launcher -> role 1 -> Net mode: **consolidated** -> transport tcp.
2. Client: launcher -> role 2 -> Net mode: **consolidated** -> transport tcp.
3. Verify: host log "HOST listening on TCP port 7778 (consolidated control+data)";
   client log "CLIENT connecting to <host>:7778"; client ships reconcile (no flicker).
4. If anything misbehaves: set `X4MP_LEGACY_NET=1` (legacy) to fall back instantly.

### Known edge cases (deferred)
- Client reconnect creates a 2nd NetClient on the host (old one pruned after
  the 30s host timeout). Acceptable for now.
- UDP consolidated mode (control+data on 7777) not yet wired; legacy UDP works.

## 2026-08-18/19 — CONSOLIDATED TCP: reconnect loop + save-reload loop FIXED (verified)

### Bug 1: ~10 s reconnect loop (EBADF) — FIXED
Host sent `HOST send error fd=35 errno=9 (EBADF)` every ~10 s; client saw
`recv=0`, reconnected; host `g_clients` grew to 156 (prune never fired);
net_update degraded 1 ms -> 8 ms/frame.

Fixes in x4mp.cpp (all deployed + verified):
- **Accept dedupe**: on `accept()`, close+erase stale entries with the same
  peer IP (reconnects used to leave the old entry forever).
- **Dead-entry cleanup** (%300): consolidated-TCP entries with `tcp_fd < 0`
  are unrecoverable and are erased.
- **`net_close_fd(fd, site)`**: every socket close now logs
  `CLOSE fd=N site=...`.
- **`net_dump_fds(why)`**: /proc/self/fd table dumped on accept, on EBADF,
  and every %300 ticks. Prune block logs that it runs.
Result: connection stable 28+ min (was ~10 s). The original silent fd
closer was never positively identified, but all close sites are now traced,
so any regression names its culprit immediately.

### Bug 2: client save-reload loop (Game Over: killmethod=removed) — FIXED
With consolidation, two client-side wiring gaps surfaced:
- **FULL lines were dropped**: x4mp's client line router only forwarded
  OBJ/PLAYER to the x4mp_stream event bridge; `FULL 1` went to
  process_message and vanished -> g_full_received stayed 0.
  (x4mp.cpp: FULL now routed to the bridge in both TCP and UDP branches.)
- **link_alive stayed false**: g_last_recv_any was only refreshed in the
  legacy recv_loop; the event bridge never refreshed it.
  (x4mp_stream.cpp: on_stream_data now refreshes it.)

With FULL + link alive, missing-ship PRUNING activated — and it deleted the
PLAYER'S OWN SHIP: when the save's player is DOCKED,
GetPlayerControlledShipID() returns 0, so rebuild_local_index's exclusion
failed, the docked player ship entered the local index, the host never
streams it (host skips its own player from OBJ), and prune removed it after
10 s -> `Game Over - Player has died (killmethod=removed)` -> main menu ->
extension re-init -> save reload -> loop (32+ cycles observed).

Fix (x4mp_stream.cpp + x4mp.cpp): `PlayerShipIDs` collects the player ship
from ALL sources (GetPlayerControlledShipID, GetPlayerShipID,
GetPlayerOccupiedShipID, GetPlayerObjectID, its "ship" context); used both
at index-build time and re-checked live in the prune loop. Same exclusion
hardened in thin_client_cleanup_own_objects (X4MP_CLEANUP=1 path).

### Bug 3 (process management): pkill/pgrep regex footgun
Game comm is `Main()`. `pkill -x 'Main()'` treats `()` as an empty regex
group and matches nothing; `pkill -f "X4 -nologo"` matches (and kills) its
own shell. Use escaped parens `pkill -x 'Main\(\)'` or kill by PID.

### Verification (this session)
- Client loads save_009 (X4MP_SAVE MUST be passed to the client launch too —
  without it the client starts thin-client NEW-GAME Boron1, which has its
  own unstable campaign-cue behaviour).
- 1 reload cycle, 0 Game Over, 0 extra MD-cue errors, full=1 link=1,
  bindings=9/158 index, host clients=1 stable, host ~27 fps.
- New md5s: x4mp.so `57da1a3976e4c7a1f3337083f6f9d791`,
  x4mp_stream.so `20c5f6dfe9a8a13a9bc172bf2673f3b3`.

### Remaining known issues (see FOLLOWUP.md)
- Client ghost ships never spawn on the host: faction `x4mp_client_N` is
  never registered as a real game faction (SpawnObjectAtPos2 fails).
- Host streams only a subset of a sector's ships (GetAllFactionShips is
  capped at 2048/faction).
- x4mp_stream DBG summary/FLK lines only appear after 300 render ticks;
  short cycles never reach them (dbg_tick is static per extension load).

## 2026-08-19 — Ownership/enumeration/stations fixes (session 2, verified)

### Issue 1 — ghost factions never spawned (FIXED, verified)
`SpawnObjectAtPos2` requires an EXISTING faction; the old fake factions
(x4mp_host / x4mp_client_N) made every player-ship ghost fail. Fix: ghosts use
REAL factions picked deterministically from the sorted real-faction list
(excluding "player" AND the faction the player currently pilots — campaign
saves have the player aboard a foreign "alliance" ship). F_HOST = index 0,
F_CLIENT_N = index N. Faction is computed LAZILY at PLAYER/ghost time (JOINs
arrive before the host universe exists). Verified: "HOST spawned client ghost
... faction=antigone".

### Issue 2 — 2048-ships-per-faction cap (FIXED, verified)
~9 enumeration sites used fixed 2048 stack buffers. New
enumerate_faction_ships/stations helpers size heap buffers from
GetNumAllFactionShips/Stations. Host now indexes all ~84k ships
("refreshed ALL ships: 84456").

### Issue 3 — client station builds -> host (IMPLEMENTED)
`ACT BUILD <seq> <macro> <pos> <rot> <sector_macro>`: client scans
player-faction stations every ~10 s, baseline = the save's stations at ready
(only NEW builds reported), re-sends each cycle (host dedupes via
spawned[seq]). Host spawns the station ghost under the client's ghost faction
in the mapped sector, marks host-only, removes on disconnect. Functional test
needs a user-built station.

### Issue 4 — client sees host's ships as own (FIXED)
Three bugs combined:
(a) ghost faction collision (host ghost under the piloted "alliance" faction
   looked like the client's own ship) — fixed by the pilot-faction skip.
(b) g_bound_locals LEAK: zone-cleanup dropped a RemoteObj without releasing
   its binding -> local ship skipped by prune forever (frozen stale ships).
(c) INDEX DUPLICATES: the same ship is returned by multiple factions'
   enumerations (includehidden aliases) -> index=158 was really ~10 unique
   ships; duplicates masked (b). Fixed: dedupe in rebuild_local_index +
   release bindings on zone-drop. Verified: "10 ships, 148 dupes dropped",
   bound_locals == bindings == 8, client view now matches host truth.
Fleet reassignment (hide host's PF fleet on client) implemented but correctly
skips campaign saves where PF ships are the player's own.

### Launcher (numbered multi-choice)
- "Extra launch options": numbered multi-select (1 = -showfps, 2 =
  -nocputhrottle); enter "1,2" for both; custom flags can be typed directly.
- "Net mode": numbered single-choice (1 = consolidated, 2 = legacy).
Synced to all 4 copies (md5 36a35dfc20844daedbebfe748ec61250); tarball rebuilt.

### Final deployed md5s (this session)
x4mp.so `30d2d2cd3e5d974c98f71de9555a1401`,
x4mp_stream.so `8a4dce4648a3bd2b444e07673c531a0f`.

### Known/deferred
- Host autosave can bake ghost objects into the save (observed: sim satellite
  from an old session is now IN save_009). Mitigate by not long-running the
  host, or prune ghosts before save.
- Host-built stations are not yet replicated to clients (client->host works).
- Host fps ~25 with one client (high-sim cost, accepted).
