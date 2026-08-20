#!/bin/bash
# ============================================================================
# x4mp_run.sh — Non-interactive X4 Multiplayer launcher (automation/testing).
#
# No prompts. All options come from environment variables:
#   X4MP_AUTO        "host" | "client"   (required)
#   X4MP_SERVER_IP   host LAN IP          (client; default 192.168.1.16)
#   X4MP_PORT        UDP port             (default 7777)
#   X4MP_MODULE      gamestart id         (host new game; default boron1)
#   X4MP_SAVE        save to load         (host load-save; base name, no .xml.gz)
#   X4MP_DIFFICULTY  difficulty           (default easy)
#   X4MP_OBJMODE     cache|full           (default cache; only used with X4MP_STREAMSHIPS=1)
#   X4MP_STREAMSHIPS 1=host streams full ship universe (OBJ) (default 0)
#   X4MP_CLEANUP     1=remove client's own ships (thin client) (default 0)
#   X4MP_STREAMS     # off-main-thread data streams (default 0)
#   X4MP_PAUSE       1=pause client sim (thin client) (default 0)
#   X4MP_FULLSIM     1=host simulates ALL ships (default 0 = high-sim set only)
#   X4MP_TELEPORT    1=host teleports server player into client sector (default 0)
#   X4MP_SYNC_M      client: drift (m) before a bound ship is corrected (default 100)
#   X4MP_BIND_RADIUS client: max distance (m) for host<->local ship matching (default 1000)
#   X4MP_DEBUG       1=verbose streamed-data logging (default 0)
#
# SIMULATION MODEL: every participant's rendering zone is fully simulated AND
# synced (reconciliation):
#   HOST   : server player's sector (X4 default) + each connected client's
#            current sector (ships there are ActivateObject()'d automatically).
#            The host streams each client the ships in THAT client's current
#            sector (FULL snapshot on join/sector change + every ~5s, deltas
#            in between).
#   CLIENT : loads the same (synced) save; its own game fully simulates the
#            client's current sector natively (ships behave normally). Each
#            host-streamed ship is bound to the matching local ship (same
#            macro, nearest) and corrected to the host position when drift
#            exceeds X4MP_SYNC_M; local ships the host no longer reports are
#            removed. All clients + host show the same ship positions.
#   Thin-client mode (legacy, for testing): X4MP_STREAMSHIPS=1 X4MP_CLEANUP=1
#            [X4MP_PAUSE=1]. The client then renders only host-streamed ships
#            in its current sector (zone-limited; spawning the whole universe
#            crashes the game's ID map).
#   X4MP_UPDATE_HZ   state update rate, 1-60 (default 15; 60=every frame)
#   X4MP_DELTA_M     min movement (m) before an object is re-sent (default 0.5)
#   X4MP_HOST_TIMEOUT  host prunes silent clients after N s (default 30)
#   X4MP_CLIENT_TIMEOUT client reconnects if no host data for N s (default 15)
#   X4MP_UNIVERSE_TIMEOUT client fallback ready after N s if no universe_ready
#   DISPLAY          if unset, Xvfb is started automatically.
#
# NOTE: the client now waits for the game's on_universe_ready signal (the 2nd
# save-load pass) before it starts rendering host-streamed objects. This avoids
# racing the game's background "Movement worker" thread during the universe
# rebuild, which previously caused a SIGSEGV on the client. Do not set
# X4MP_OBJMODE=full unless testing (it enumerates all ~85k ships every frame).
#
# X4 output is written to logs/x4mp_<timestamp>.log and shown in the terminal.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# X4 game directory: set X4MP_GAME_DIR explicitly, or place this script in the
# parent folder of "X4 Foundations" (auto-detected).
GAME_DIR="${X4MP_GAME_DIR:-${SCRIPT_DIR}/X4 Foundations}"
LOG_DIR="${GAME_DIR}/logs"

# --- Validate role ---------------------------------------------------------
ROLE="${X4MP_AUTO:-}"
if [ "$ROLE" != "host" ] && [ "$ROLE" != "client" ]; then
    echo "ERROR: set X4MP_AUTO=host or X4MP_AUTO=client" >&2
    exit 1
fi

# --- Env -------------------------------------------------------------------
export X4MP_AUTO="${ROLE}"
export X4MP_SERVER_IP="${X4MP_SERVER_IP:-192.168.1.16}"
export X4MP_PORT="${X4MP_PORT:-7777}"
export X4MP_MODULE="${X4MP_MODULE:-x4ep1_gamestart_boron1}"
export X4MP_DIFFICULTY="${X4MP_DIFFICULTY:-easy}"
export X4MP_SAVE="${X4MP_SAVE:-}"
# X4MP_OBJMODE  cache|full  (default cache). Only used with X4MP_STREAMSHIPS=1.
export X4MP_OBJMODE="${X4MP_OBJMODE:-cache}"
# X4MP_STREAMSHIPS  0 (default): clients keep their own locally simulated
#   universe and only receive human PLAYER ghosts. 1: host streams the full
#   ship universe (OBJ) — thin-client / testing mode.
export X4MP_STREAMSHIPS="${X4MP_STREAMSHIPS:-0}"
# X4MP_CLEANUP  0 (default) keeps the client's own ships (its local universe
#   is the rendering content). 1 removes them (thin client; combine with
#   X4MP_STREAMSHIPS=1).
export X4MP_CLEANUP="${X4MP_CLEANUP:-0}"
# X4MP_STREAMS  number of off-main-thread data streams (0=off, single-threaded
#   and safest). 1-8 spawns per-category stream threads on ports 7778+.
export X4MP_STREAMS="${X4MP_STREAMS:-0}"
# X4MP_PAUSE  0 (default) keeps the client's local simulation running — that
#   is what fully simulates the client's rendering zone (ships behave
#   normally). 1 pauses it (thin-client offload).
export X4MP_PAUSE="${X4MP_PAUSE:-0}"
# X4MP_FULLSIM  0 (default): the host fully simulates the high-simulation set
#   (server player's sector + each connected client's current sector)
#   automatically. 1: force-simulate ALL ~85k ships (CPU-heavy, testing).
export X4MP_FULLSIM="${X4MP_FULLSIM:-0}"
# X4MP_TELEPORT  0 (default): the host does NOT teleport the server player
#   into client sectors (per-sector ActivateObject handles that). 1: legacy
#   teleport behaviour.
export X4MP_TELEPORT="${X4MP_TELEPORT:-0}"
# X4MP_DEBUG  1 enables continuous streamed-data logging (verifies sync).
export X4MP_DEBUG="${X4MP_DEBUG:-0}"
# Network performance / stability (override via env if needed).
export X4MP_UPDATE_HZ="${X4MP_UPDATE_HZ:-15}"     # state update rate (1-60)
export X4MP_DELTA_M="${X4MP_DELTA_M:-0.5}"       # min movement before re-send
export X4MP_HOST_TIMEOUT="${X4MP_HOST_TIMEOUT:-30}"   # prune silent clients (s)
export X4MP_CLIENT_TIMEOUT="${X4MP_CLIENT_TIMEOUT:-15}" # client reconnect timeout (s)
export X4MP_UNIVERSE_TIMEOUT="${X4MP_UNIVERSE_TIMEOUT:-180}" # client fallback ready (s)
# X4MP_LOG=0 disables the on-disk log entirely (game stdout goes to /dev/null).
# X4MP_LOG=1 (default) writes logs/x4mp_<ts>.log and keeps only the newest few.
export X4MP_LOG="${X4MP_LOG:-1}"
# Extra X4 command-line flags (e.g. "-showfps -nocputhrottle"). Passed through
# verbatim to the game launch. Set by the launcher from its numbered options.
export X4MP_GAME_ARGS="${X4MP_GAME_ARGS:-}"
export SteamAppId="294140"
export SteamGameId="294140"
export LD_LIBRARY_PATH="${GAME_DIR}/lib:${LD_LIBRARY_PATH:-}"

# Force the real GPU Vulkan driver (radv). On the VM the loader otherwise picks
# lavapipe which crashes X4 (SIGSEGV in libvulkan_lvp.so). Harmless elsewhere.
export VK_ICD_FILENAMES="/usr/share/vulkan/icd.d/radeon_icd.x86_64.json"

# --- Display ---------------------------------------------------------------
# Prefer the user's existing Xwayland display :0 (used by the interactive
# session on this machine). It needs the mutter Xwayland auth cookie.
XAUTH_FILE="$(find /run/user/$(id -u) -maxdepth 1 -name '.mutter-Xwaylandauth.*' 2>/dev/null | head -1)"
if [ -S "/tmp/.X11-unix/X0" ] && [ -n "${XAUTH_FILE:-}" ]; then
    export DISPLAY=":0"
    export XAUTHORITY="${XAUTH_FILE}"
    echo ">> Using existing Xwayland display :0 (auth=${XAUTH_FILE})"
elif [ -n "${DISPLAY:-}" ] && [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ]; then
    echo ">> Reusing DISPLAY=${DISPLAY}"
else
    # Fall back to Xvfb (disable access control so X4 can connect).
    XVFB_DISPLAY=":99"
    if ! kill -0 "$(cat "${LOG_DIR}/xvfb.pid" 2>/dev/null)" 2>/dev/null; then
        rm -f "/tmp/.X11-unix/X${XVFB_DISPLAY#:}"
        setsid Xvfb "${XVFB_DISPLAY}" -screen 0 1280x720x24 -nolisten tcp -ac \
            >> "${LOG_DIR}/xorg.log" 2>&1 &
        echo $! > "${LOG_DIR}/xvfb.pid"
        sleep 2
    fi
    export DISPLAY="${XVFB_DISPLAY}"
    echo ">> Started Xvfb on ${XVFB_DISPLAY}"
fi

# --- Save sync (client) -----------------------------------------------------
# The client must load the SAME save as the host so sector/zone IDs match.
# X4 stores saves in ~/.config/EgoSoft/X4/save/ (NOT the game's save/ folder).
# Copy the host's CURRENT save into the local config save folder before
# starting, so the client loads the exact universe the host is running.
if [ "$ROLE" = "client" ] && [ -n "${X4MP_SAVE:-}" ]; then
    SAVE_DIR="${HOME}/.config/EgoSoft/X4/save"
    SAVE_FILE="${SAVE_DIR}/${X4MP_SAVE}.xml.gz"
    # scp expands ~ on the remote side; use the standard config save path.
    HOST_SAVE="~/.config/EgoSoft/X4/save/${X4MP_SAVE}.xml.gz"
    mkdir -p "${SAVE_DIR}"
    echo ">> Syncing save '${X4MP_SAVE}' from host ${X4MP_SERVER_IP}..."
    if scp -q "${X4MP_SERVER_IP}:${HOST_SAVE}" "${SAVE_FILE}"; then
        echo ">> Save synced: ${SAVE_FILE}"
    else
        echo ">> WARN: save sync failed — using local save if present"
    fi
fi

# --- Launch ----------------------------------------------------------------
mkdir -p "${LOG_DIR}"
# Keep only the newest few logs so the logs dir does not grow unbounded.
# NOTE: paths contain a space ("X4 Foundations"), so a plain `xargs rm` would
# split on the space and fail (and, under `set -e`, kill the launch before the
# game starts). Use null-delimited xargs + `|| true` so cleanup can never abort.
ls -1t "${LOG_DIR}"/x4mp_*.log 2>/dev/null | tail -n +4 | tr '\n' '\0' | xargs -0 -r rm -f || true

GAME_ARGS="${X4MP_GAME_ARGS:-}"
# shellcheck disable=SC2086  # GAME_ARGS is intentionally word-split
if [ "${X4MP_LOG}" = "0" ]; then
    echo ">> Logging DISABLED (X4MP_LOG=0) — output to /dev/null"
    cd "${GAME_DIR}"
    stdbuf -oL -eL ./X4 -nologo -nosound -noinput ${GAME_ARGS} 2>&1 > /dev/null
else
    LOG_FILE="${LOG_DIR}/x4mp_$(date +%Y%m%d_%H%M%S).log"
    echo ">> Role=${ROLE}  IP=${X4MP_SERVER_IP}  Port=${X4MP_PORT}"
    echo ">> Game args: ${GAME_ARGS:-<none>}" 
    echo ">> X4 output log: ${LOG_FILE}"
    echo ">> (tail -f '${LOG_FILE}' to watch live)"
    cd "${GAME_DIR}"
    stdbuf -oL -eL ./X4 -nologo -nosound -noinput ${GAME_ARGS} 2>&1 | tee "${LOG_FILE}"
fi
