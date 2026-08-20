# X4MP — X4: Foundations LAN Multiplayer Mod

Turn **X4: Foundations** (singleplayer) into a **LAN multiplayer** setup:
one machine runs the **HOST** (the authoritative universe) and one or more
machines join as **CLIENTS**. Every participant renders a normal X4 window —
no headless server, no Steam/EgoNet, direct IP networking over your LAN.

Built for the **Linux** version of X4: Foundations (x86-64).

## What works today

- **Hybrid simulation with reconciliation.** The host runs the full universe;
  each client loads the *same save* and fully simulates its own sector. The
  host streams every ship in each client's sector; the client binds them to
  its local ships and pins them to the host's truth. All participants see the
  **same** ship state at any speed (tested at 15 km/s highway speeds). Sector-
  entry reconciliation *glides* ships into place instead of teleporting
  (no highway flicker), and you can pick **thin-client** or **hybrid**
  simulation per client in the launcher.
- **Players see each other.** Each player's ship appears on every other
  participant as a ghost ship (owned by a distinct, real in-game faction so
  colours and relations are unambiguous).
- **Station builds replicate (both ways).** A station the client builds
  appears on the host (`ACT BUILD`); a station the host player builds appears
  on every client (`STA` stream) — spawned as a ghost in the client's universe
  when it is in that sector.
- **Combat kills replicate.** When a player destroys an enemy ship (or their
  own ship is destroyed), the kill is detected via the game's MD `Killed`
  event and propagated: the host removes its authoritative copy and re-
  broadcasts `KILL`/`PLAYERDIED`, so the ship vanishes for every participant.
  (See limitations — damage/projectile visuals are not yet synced.)
- **Trading replicates (ship cargo + station inventory).** When a player trades
  at a station: (1) the ship's cargo is synced (`ACT CARGO` → `CARGO`) so every
  participant sees the same cargo; and (2) the **station trade** is relayed
  host-authoritatively (`ACT TRADE`) — the discrete trade (derived from the ship's
  cargo change) is applied to the host's copy of that station and re-broadcast
  (`TRADE`), so every client's station stock converges. Buys sync instantly
  (`DropCargo`, bulk); sells converge (`AddTradeWare`, single-unit, bounded by
  the ship's cargo hold). The station is located by its UniverseID (same save ⇒
  static IDs match) with a position fallback. (Credits and a station's own
  production economy are not synced — see limitations.)
- **Boarding works + captures replicate.** The player can board and capture a
  ship. In thin-client mode (the standard) ships are inert, so when a boarding
  operation starts the involved ship is exempted from inert (MD
  `BoardingOperationStarted`/`Removed` events) to let the local boarding run. The
  capture result is detected (`EntityChangedOwner`), reported to the host
  (`ACT CAPTURE`), which makes it authoritative and broadcasts it (`CAPTURE`) so
  every client shows the ship changed hands. (The boarding *animation/marines*
  is local to the player's client — see limitations.)
- **Thin-client is the standard.** Ships are inert and driven purely by the host
  stream (no local AI, no divergence/flicker). Hybrid (local sim for ships) is
  an opt-in alternative in the launcher.
- **In-game menu.** A "Host Multiplayer" / "Join Multiplayer" option is added
  to the main menu (or start immediately with AUTO-START).
- **One port per transport.** Consolidated net mode (default): TCP **7778**
  carries control + data on a single connection. UDP 7777 or the old split-port
  legacy mode are available as options.
- **Interactive launcher** with numbered prompts, automatic save transfer from
  the host, live logs, and sane defaults.
- The whole universe is streamed **without caps** (~85k ships are indexed).

**Not yet implemented:** full boarding *operation* replication to other clients
(the player boards + captures locally, and the capture **result** IS replicated),
and trading *credits*. Player position, ships, host- and client-built stations,
combat kills, trading cargo, and boarding captures are shared today.

**Combat limitations (v1):** kills and player deaths propagate, but individual
shots, damage, and projectile visuals are not synced (the hybrid model simulates
combat locally on each client; only terminal kill events are authoritative on
the host). Full shot-level replication requires a Linux internal-function DB
(`CreateOrderInternal`/`SetOrderParamInternal`) + a hull setter — future work.

**Trading limitations (v1):** cargo state replicates, but *credits* do not —
there is no exported API to read a player's credit balance or set an NPC ghost
faction's money pool.

## Requirements

| | |
|---|---|
| OS | Linux x86-64, **glibc ≥ 2.43** (Debian 13+, Ubuntu 25.04+, Arch, Fedora 41+). Tested on Arch/CachyOS. |
| Game | X4: Foundations **Linux** build installed and runnable on each machine. |
| GPU | Real GPU with a Vulkan driver (the game renders with Vulkan). |
| Network | Machines on the same LAN that can reach each other by IP. |
| SSH | Host ↔ client SSH for automatic save transfer (passwordless keys recommended; see below). |
| Instances | Only **one** X4 instance per machine at a time. |

## Quick start (5 minutes)

```bash
# 1) Get this package onto each machine, then install the extensions:
cd x4mp-release
X4MP_GAME_DIR="/path/to/X4 Foundations" ./install.sh

# 2) On the HOST machine:
X4MP_GAME_DIR="/path/to/X4 Foundations" ./scripts/x4mp_launcher.sh
#    -> Role: 1 (HOST) -> choose NEW GAME or LOAD SAVE -> accept the rest

# 3) On a CLIENT machine:
X4MP_GAME_DIR="/path/to/X4 Foundations" ./scripts/x4mp_launcher.sh
#    -> Role: 2 (CLIENT) -> type the host IP -> pick the save
#    (the save is transferred automatically from the host)
```

Both machines then open the normal X4 window. With the default **IN-GAME
MENU** start mode, click *Host Multiplayer* on the host and *Join
Multiplayer* on the client. Done.

> If your scripts are not next to the "X4 Foundations" folder, pass
> `X4MP_GAME_DIR` (as above) or move `x4mp-release` next to the game.

## Using the launcher (all prompts)

`scripts/x4mp_launcher.sh` walks you through everything. Numbered choices
accept numbers; several prompts accept **multiple** comma-separated numbers.

1. **Role** — `1` HOST or `2` CLIENT.
2. *(client)* **Host IP** — the host prints its LAN IP when it starts.
3. *(host)* **Universe source** — `1` NEW GAME (pick a gamestart) or `2` LOAD
   SAVE (pick from your save list). *(client)* **Save to use** — the launcher
   lists the host's saves; pick a number or type a name. The save is then
   copied from the host automatically (scp). If the copy fails, the launcher
   prints the exact manual command.
4. **Start mode** — `1` IN-GAME MENU (default; use the Host/Join Multiplayer
   menu entries) or `2` AUTO-START (begin hosting/joining as soon as the game
   loads).
5. **Extra launch options** — numbered multi-choice for X4 flags:
   `1` = `-showfps`, `2` = `-nocputhrottle`. Enter e.g. `1,2` to use both,
   or type any flag directly (e.g. `-windowed`).
6. **Data-stream transport** — `tcp` (default, reliable) or `udp`.
7. **Net mode** — numbered: `1` consolidated (one port per transport — TCP
   7778 / UDP 7777; recommended) or `2` legacy (split ports: UDP 7777 control
   + 7778 data).
8. **Debug logging** — verbose sync logs (`X4MP_DEBUG=1`); useful while
   testing, off for normal play.
9. **Log file** — on by default, stored under `<game dir>/logs/`.

The launcher prints a summary and starts X4 with the extensions.

## Non-interactive use (automation)

`scripts/x4mp_run.sh` is env-driven (no prompts). Examples:

```bash
# Host: load a save, consolidated TCP, in-game menu:
X4MP_GAME_DIR="/path/to/X4 Foundations" X4MP_SAVE=save_009 ./scripts/x4mp_run.sh

# Client: join a host, auto-start:
X4MP_GAME_DIR="/path/to/X4 Foundations" X4MP_AUTO=client \
X4MP_SERVER_IP=192.168.1.16 X4MP_SAVE=save_009 ./scripts/x4mp_run.sh
```

## Configuration reference

All settings are environment variables with safe defaults (export before
running, or answer the launcher prompts).

| Variable | Default | Meaning |
|---|---|---|
| `X4MP_AUTO` | unset | `host` / `client` = auto-start (unset = in-game menu). |
| `X4MP_SERVER_IP` | `192.168.1.16` | Host IP (client). |
| `X4MP_SAVE` | unset | Save name to load (without `.xml.gz`). Clients pull it from the host. |
| `X4MP_MODULE` | `x4ep1_gamestart_boron1` | Gamestart id for NEW GAME hosts. |
| `X4MP_DIFFICULTY` | `easy` | Difficulty for NEW GAME hosts. |
| `X4MP_TRANSPORT` | `tcp` | Data transport: `tcp` (reliable) or `udp`. |
| `X4MP_LEGACY_NET` | `0` | `0` = consolidated one-port mode (default); `1` = legacy split ports. |
| `X4MP_PORT` | `7777` | Control port (legacy mode). |
| `X4MP_INERT` | `1` | Freeze the client's local AI for host-driven ships (prevents divergence). |
| `X4MP_CONVERGE_GREEDY` | `1` | On sector entry, snap diverged local ships to the host's positions. |
| `X4MP_BIND_RADIUS` | `1000` | Mid-sector re-match radius (m). |
| `X4MP_CONVERGE_RADIUS` | `20000` | Entry convergence radius (m) when greedy is off. |
| `X4MP_MAX_LAG_M` | `300` | Max interpolation lag behind the host (m). |
| `X4MP_DEBUG` | `0` | Verbose sync/stream logging. |
| `X4MP_LOG` | `1` | Write an on-disk log file. |
| `X4MP_GAME_DIR` | auto | Path to the "X4 Foundations" folder. |

## Networking / firewall

- **Consolidated mode (default):** ONE port per transport — **TCP 7778**
  (control + data on one connection) or **UDP 7777**.
- **Legacy mode (`X4MP_LEGACY_NET=1`):** UDP 7777 (control) + TCP/UDP 7778
  (data).

On the **host**, allow inbound from the LAN:

```bash
# ufw example (consolidated TCP)
sudo ufw allow from 192.168.1.0/24 to any port 7778 proto tcp
```

### Automatic save transfer (SSH keys)

The client pulls the chosen save from the host via `scp` with
`BatchMode=yes`, i.e. **passwordless SSH is required**. One-time setup on the
client machine:

```bash
ssh-keygen -t ed25519          # if you have no key yet
ssh-copy-id user@192.168.1.16  # install it on the host
```

If the transfer fails for any reason, the launcher prints the exact manual
`scp` command — run it and re-launch (or continue with an existing local copy
of the same save).

## How it works (short version)

1. **Host** loads a save and runs the full universe simulation. It keeps a
   *high-simulation set* = the server player's sector + every connected
   client's current sector, and fully simulates those.
2. **Client** loads the *same save*. Its own game fully simulates the client's
   current sector, with local AI frozen (`X4MP_INERT`) so it cannot diverge.
3. The **host streams** the ships of each client's sector (full snapshot on
   join/sector change, then continuously — full state, no deltas; LAN
   bandwidth is cheap).
4. The **client reconciles**: each streamed ship binds to the matching local
   ship (same ship type, nearest) and is pinned to the host's interpolated
   position every frame. Ships the host no longer reports are pruned after a
   grace period; new ones are spawned. Player ships never bind — they render
   as ghosts under each player's assigned real faction. On sector entry, a
   bound ship that has diverged from the host by <= `X4MP_GLIDE_MAX` (20 km)
   *glides* into place at `X4MP_GLIDE_SPEED` (1500 m/s) instead of teleporting,
   which is what stops the highway sector-transition flicker. Two **simulation
   modes** (chosen in the launcher): **thin-client** (`X4MP_INERT=1`, the
   default — ships inert and driven purely by the host, no local AI) and
   **hybrid** (`X4MP_INERT=0` — the local simulation keeps running for ships
   and is reconciled to the host).
5. **Client→host:** the client's player position (`PLAYER`), actions
   (`ACT`: `ACT BUILD` for client stations, `ACT KILL <host_id>` and
   `ACT PLAYERDIED` for combat), and camera snaps travel over the same
   connection.
6. **Host→clients (combat/boarding/trading):** `KILL <host_id>` (a ship was
   destroyed), `PLAYERDIED <key>` (another client's player died), `CAPTURE
   <host_id> <faction>` (a boarding capture), and `CARGO <key> <n> <ware> <amt>…`
   (a player's cargo) are broadcast on the data stream; each client applies them
   to its bound local ship / ghost.

## Current status & limitations

- Full boarding *operation* replication (marines/phases) and trading
  *credits* are **not** yet replicated (position + ships + both directions of
  station builds + combat kills + trading cargo + boarding captures are).
- Linux only for now (the native extensions are compiled `.so` files; a
  Windows port of the extensions is future work).
- The host's own autosave can bake ghost objects (player ghosts, simulation
  satellites) into the save file — restart from a known-good save if ghost
  ships appear "from nowhere".
- Expect ~25–30 FPS on a decent host with one or two clients (the cost is the
  high-simulation of multiple sectors, not the network).
- If you update the game, the extensions may need rebuilding against the new
  binary (see `X4-C++-Extension-Linux/` upstream sources).

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Client can't connect | Wrong host IP, firewall blocking 7778, or host not loaded yet. Check the host log for `HOST listening on TCP port 7778`. |
| World differs on client vs host | Client loaded a different save. Re-transfer the exact same save and restart the client. |
| Client reloads the save in a loop | Old bug (fixed): player-ship pruning. Update to the latest `x4mp_stream.so`. Check the log for `Game Over ... killmethod=removed`. |
| Can't see other players' ships | Old bug (fixed): ghost factions. Update to the latest `x4mp.so`. Check the host log for `HOST spawned client ghost`. |
| Ships flicker / pop | Ensure `X4MP_INERT=1` and `X4MP_CONVERGE_GREEDY=1` (defaults); run with `X4MP_DEBUG=1` and look for `[CONVERGE]` / `[FLK]` lines. |
| Client crashes on load | Make sure only one X4 instance runs; the client waits for "universe ready" before rendering. Check the log. |
| GPU / rendering errors | Needs a real Vulkan GPU. AMD `radv` driver is forced via `VK_ICD_FILENAMES` on the test machines; other GPUs may need it unset. |
| Host very slow | Avoid `X4MP_FULLSIM=1` (simulates all ~85k ships). The default per-sector high-sim is much lighter. |

## Package layout

```
x4mp-release/
├── README.md              ← this manual
├── install.sh             ← copies the extensions into your game dir
├── extensions/
│   ├── x4native/          ← foundation bridge (C++ <-> Lua); required
│   ├── x4mp/              ← host + client control channel, net modes, ghosts,
│   │                        station-build replication, in-game menu
│   └── x4mp_stream/       ← client data stream + reconciliation/prune/converge
└── scripts/
    ├── x4mp_launcher.sh   ← INTERACTIVE launcher (for humans)
    └── x4mp_run.sh        ← NON-INTERACTIVE launcher (env-driven)
```
