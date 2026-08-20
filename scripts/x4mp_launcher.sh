#!/bin/bash
# ============================================================================
# x4mp_launcher.sh — Interactive X4 Multiplayer launcher (for humans)
# ----------------------------------------------------------------------------
# A friendly, step-by-step launcher. It asks for:
#   * role            HOST or CLIENT
#   * HOST:           universe source (new gamestart / load an existing save)
#   * CLIENT:         host IP + which save to pull. The save is transferred
#                     AUTOMATICALLY from the host (it asks where the save
#                     lives); if the copy fails it prints the exact manual
#                     scp command and warns that a manual transfer is needed.
#   * extra X4 flags  e.g. -nocputhrottle -showfps (both roles)
#   * logging         on/off + where log files are stored
# then launches X4 with the x4native + x4mp extensions.
#
# Non-interactive automation: use x4mp_run.sh (env-driven, no prompts).
#
# X4 output is written to a per-launch log file (if enabled) and shown live in
# the terminal.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# X4 game directory: set X4MP_GAME_DIR explicitly, or place this script in the
# parent folder of "X4 Foundations" (auto-detected).
GAME_DIR="${X4MP_GAME_DIR:-${SCRIPT_DIR}/X4 Foundations}"
SAVE_DIR="${HOME}/.config/EgoSoft/X4/save"     # where X4 actually reads/writes saves
DEFAULT_IP="192.168.1.16"
DEFAULT_LOG_DIR="${GAME_DIR}/logs"

# ---------------------------------------------------------------------------
# Main playable gamestarts (id => short description). Users may also type a
# custom id (e.g. x4ep1_gamestart_terran1) or a tutorial id.
# ---------------------------------------------------------------------------
declare -A STARTS=(
  ["x4ep1_gamestart_boron1"]="Boron (Kingdom End) 1"
  ["x4ep1_gamestart_boron2"]="Boron (Kingdom End) 2"
  ["x4ep1_gamestart_terran1"]="Terran 1"
  ["x4ep1_gamestart_terran2"]="Terran 2"
  ["x4ep1_gamestart_split1"]="Split 1"
  ["x4ep1_gamestart_split2"]="Split 2"
  ["x4ep1_gamestart_pirate1"]="Pirate 1"
  ["x4ep1_gamestart_pirate2"]="Pirate 2"
  ["x4ep1_gamestart_trade"]="The Young Gun (Trade)"
  ["x4ep1_gamestart_fight"]="The Fighter"
  ["x4ep1_gamestart_discover"]="The Explorer"
  ["x4ep1_gamestart_scientist"]="The Scientist"
  ["x4ep1_gamestart_boso"]="Boso Ta"
  ["x4ep1_gamestart_hyperion"]="Hyperion"
  ["x4ep1_gamestart_workshop"]="Workshop"
  ["x4ep1_gamestart_hub"]="The Hub"
  ["x4ep1_gamestart_intro"]="Intro"
  ["x4ep1_gamestart_dlc_mini_02"]="DLC Mini 02"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# ask_yesno "prompt" [Y|n]  ->  sets REPLY_YN to 1 (yes) or 0 (no)
ask_yesno() {
    local prompt="$1" def="${2:-Y}" hint="Y/n"
    [ "${def^^}" = "N" ] && hint="y/N"
    local ans
    read -r -p "$prompt [$hint]: " ans
    ans="${ans:-$def}"
    case "${ans^^}" in Y*) REPLY_YN=1 ;; *) REPLY_YN=0 ;; esac
}

# Best-effort local (LAN) IPv4 address.
detect_local_ip() {
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | grep -v '^127\.' | head -1
}

echo "=================================================="
echo "  X4 Multiplayer Launcher"
echo "=================================================="

# --- Role -------------------------------------------------------------------
echo ""
echo "Select role:"
echo "  1) HOST   (start a universe on THIS machine)"
echo "  2) CLIENT (join a host by IP)"
read -r -p "Choice [1/2]: " ROLE
ROLE="${ROLE:-1}"

EXTRA_FLAGS=""
X4MP_DEBUG=0

if [ "$ROLE" = "2" ]; then
    # ============================ CLIENT ====================================
    read -r -p "Host IP [${DEFAULT_IP}]: " SERVER_IP
    SERVER_IP="${SERVER_IP:-$DEFAULT_IP}"
    ROLE_NAME="client"
    export X4MP_SERVER_IP="${SERVER_IP}"

    # --- which save (list what the host has, then pick/type) ---------------
    echo ""
    echo ">> Saves available on host ${SERVER_IP} (in ${SAVE_DIR} there):"
    # -n keeps ssh from reading (and consuming) our interactive stdin.
    mapfile -t HOST_SAVES < <(ssh -n -o ConnectTimeout=6 -o BatchMode=yes "${SERVER_IP}" \
        "ls -1t ${SAVE_DIR}/*.xml.gz 2>/dev/null | xargs -n1 basename" 2>/dev/null)
    if [ "${#HOST_SAVES[@]}" -gt 0 ]; then
        for i in "${!HOST_SAVES[@]}"; do printf "  %2d) %s\n" "$((i+1))" "${HOST_SAVES[$i]}"; done
    else
        echo "  (could not list remote saves — type the name below manually)"
    fi
    read -r -p "Save to use — name [save_010] or number [1-${#HOST_SAVES[@]}]: " SAVE_PICK
    if [[ "${SAVE_PICK}" =~ ^[0-9]+$ ]] && [ "${SAVE_PICK}" -ge 1 ] && [ "${SAVE_PICK}" -le "${#HOST_SAVES[@]}" ]; then
        SAVE_NAME="${HOST_SAVES[$((SAVE_PICK-1))]}"
    else
        SAVE_NAME="${SAVE_PICK:-save_010}"
    fi
    # Normalize to a full filename (with .xml.gz), regardless of how it was given.
    SAVE_NAME="${SAVE_NAME%.xml.gz}.xml.gz"
    SAVE_BASE="${SAVE_NAME%.xml.gz}"
    export X4MP_SAVE="${SAVE_BASE}"

    # --- where is the save on the host? ------------------------------------
    read -r -p "Save location on host [${SAVE_DIR}]: " REMOTE_SAVE_DIR
    REMOTE_SAVE_DIR="${REMOTE_SAVE_DIR:-${SAVE_DIR}}"

    # --- transfer it automatically -----------------------------------------
    LOCAL_SAVE="${SAVE_DIR}/${SAVE_NAME}"
    mkdir -p "${SAVE_DIR}"
    echo ">> Transferring save '${SAVE_NAME}' from ${SERVER_IP}:${REMOTE_SAVE_DIR} ..."
    # < /dev/null keeps scp from reading (and consuming) our interactive stdin.
    if scp -o ConnectTimeout=10 -o BatchMode=yes "${SERVER_IP}:${REMOTE_SAVE_DIR}/${SAVE_NAME}" "${LOCAL_SAVE}" 2>/dev/null < /dev/null; then
        echo ">> Save synced: ${LOCAL_SAVE}"
    else
        echo ""
        echo ">> ============================================================"
        echo ">>  WARN: AUTOMATIC SAVE TRANSFER FAILED"
        echo ">>  The client MUST load the exact same save as the host, or"
        echo ">>  sectors/objects will not match. Transfer it manually with:"
        echo ""
        echo ">>    scp ${SERVER_IP}:${REMOTE_SAVE_DIR}/${SAVE_NAME} ${LOCAL_SAVE}"
        echo ""
        echo ">>  Then re-run this launcher — or, if a local copy of"
        echo ">>  '${SAVE_NAME}' already exists, continue with it."
        echo ">> ============================================================"
        if [ ! -f "${LOCAL_SAVE}" ]; then
            echo ">> ERROR: no local copy of '${SAVE_NAME}' and the transfer failed."
            echo ">>        Fix the transfer (see above) and re-run."
            exit 1
        fi
    fi

else
    # ============================= HOST =====================================
    ROLE_NAME="host"
    echo ""
    echo "Host universe source:"
    echo "  1) NEW GAME  (choose a gamestart)"
    echo "  2) LOAD SAVE (continue an existing savegame)"
    read -r -p "Choice [1/2]: " HOST_SRC
    HOST_SRC="${HOST_SRC:-2}"

    if [ "$HOST_SRC" = "2" ]; then
        echo ""
        echo "Available savegames in ${SAVE_DIR}:"
        mapfile -t SAVES < <(ls -1t "${SAVE_DIR}"/*.xml.gz 2>/dev/null | xargs -n1 basename || true)
        if [ "${#SAVES[@]}" -eq 0 ]; then echo "  (no savegames found)"; exit 1; fi
        for i in "${!SAVES[@]}"; do printf "  %2d) %s\n" "$((i+1))" "${SAVES[$i]}"; done
        read -r -p "Select save [1-${#SAVES[@]}]: " SAVE_NUM
        SAVE_NUM="${SAVE_NUM:-1}"
        [[ "$SAVE_NUM" =~ ^[0-9]+$ ]] || SAVE_NUM=1
        { [ "$SAVE_NUM" -ge 1 ] && [ "$SAVE_NUM" -le "${#SAVES[@]}"; } || SAVE_NUM=1
        SAVE_FILE="${SAVES[$((SAVE_NUM-1))]}"
        export X4MP_SAVE="${SAVE_FILE%.xml.gz}"
    else
        echo ""
        echo "Available gamestarts:"
        ids=(); i=0
        for id in "${!STARTS[@]}"; do ids+=("$id"); i=$((i+1)); printf "  %2d) %s  (%s)\n" "$i" "${STARTS[$id]}" "$id"; done
        echo "  Custom) type any gamestart id"
        read -r -p "Select gamestart [1-${#ids[@]}] or custom id: " GS
        if [[ "$GS" =~ ^[0-9]+$ ]] && [ "$GS" -ge 1 ] && [ "$GS" -le "${#ids[@]}" ]; then
            MODULE="${ids[$((GS-1))]}"
        else
            MODULE="${GS}"
        fi
        export X4MP_MODULE="${MODULE}"
    fi

    LOCAL_IP="$(detect_local_ip)"
    echo ""
    echo ">> This host will listen on: ${LOCAL_IP:-<could not detect IP>}"
    echo ">> Tell each client to connect to that IP."
fi

# --- Start mode -------------------------------------------------------------
echo ""
echo "Start mode:"
echo "  1) IN-GAME MENU  — the game opens to the main menu; click"
echo "     'Host Multiplayer' (host) or 'Join Multiplayer' (client) to begin."
echo "  2) AUTO-START    — begin hosting/joining immediately on load."
read -r -p "Choice [1/2]: " START_MODE
START_MODE="${START_MODE:-1}"
if [ "$START_MODE" = "2" ]; then
    if [ "$ROLE_NAME" = "client" ]; then export X4MP_AUTO="client"; else export X4MP_AUTO="host"; fi
    START_MODE_DESC="auto-start (begins immediately on load)"
else
    unset X4MP_AUTO
    START_MODE_DESC="in-game menu (click Host/Join Multiplayer in the main menu)"
fi

# --- Simulation mode (client) ---------------------------------------------
# THIN-CLIENT: ships are inert + driven purely by the host stream (no local
#   AI). Smoothest sync — no local divergence, no flicker. Recommended.
# HYBRID: the local simulation keeps running for ships (they have local AI) and
#   is reconciled to the host. Ships can look natural, but the local sim
#   diverges from the host and can flicker.
# (The glide convergence below applies to BOTH, removing sector-entry teleports.)
if [ "$ROLE_NAME" = "client" ]; then
    echo ""
    echo "--- Simulation mode (client) ---"
    echo "  1) THIN-CLIENT  ships driven by the host (no local AI) - the STANDARD, smoothest"
    echo "  2) HYBRID       alternative: local simulation runs for ships, reconciled to the host"
    read -r -p "Simulation mode [1 = standard thin-client]: " SIM_INPUT
    case "$SIM_INPUT" in
        2|HYBRID|hybrid)  SIM_MODE="hybrid" ;;
        *)                SIM_MODE="thin-client" ;;   # thin-client is the standard default
    esac
    if [ "$SIM_MODE" = "hybrid" ]; then
        export X4MP_INERT=0
        echo "  -> HYBRID mode (X4MP_INERT=0): local sim runs, reconciled"
    else
        export X4MP_INERT=1
        echo "  -> THIN-CLIENT mode (X4MP_INERT=1): ships host-driven [standard]"
    fi
    # Glide convergence (both modes): smooths sector-entry into place instead of
    # teleporting visible ships; far/offscreen ships snap.
    export X4MP_GLIDE_SPEED="${X4MP_GLIDE_SPEED:-1500}"
    export X4MP_GLIDE_MAX="${X4MP_GLIDE_MAX:-20000}"
fi

# --- Common options ---------------------------------------------------------
echo ""
echo "--- Extra launch options (for this ${ROLE_NAME}) ---"
echo "Select X4 flags by NUMBER (comma or space separated), or type flags directly:"
echo "  1) -showfps         show the FPS counter"
echo "  2) -nocputhrottle   disable CPU throttle (more performance)"
echo "  e.g. '1,2' enables both · '-showfps -windowed' types flags directly"
read -r -p "Extra launch options [Enter = none]: " FLAG_INPUT
EXTRA_FLAGS=""
FLAG_INPUT="${FLAG_INPUT//,/ }"
for _tok in $FLAG_INPUT; do
    case "$_tok" in
        1|-showfps)        EXTRA_FLAGS="$EXTRA_FLAGS -showfps" ;;
        2|-nocputhrottle)  EXTRA_FLAGS="$EXTRA_FLAGS -nocputhrottle" ;;
        -*)                EXTRA_FLAGS="$EXTRA_FLAGS $_tok" ;;   # custom flag typed directly
        *)                 : ;;                                   # ignore unknown tokens
    esac
done
EXTRA_FLAGS="${EXTRA_FLAGS# }"   # trim leading space
read -r -p "Data-stream transport — tcp (reliable) or udp (no backpressure) [tcp]: " X4MP_TRANSPORT
X4MP_TRANSPORT="${X4MP_TRANSPORT:-tcp}"
case "${X4MP_TRANSPORT}" in udp|UDP) X4MP_TRANSPORT="udp" ;; *) X4MP_TRANSPORT="tcp" ;; esac
export X4MP_TRANSPORT
# Net mode: consolidated (DEFAULT) = one port per transport (TCP 7778 or UDP
# 7777) carrying control + data on a single connection. legacy = UDP 7777
# control + TCP/UDP 7778 data (old split-port setup; X4MP_LEGACY_NET=1).
echo "Net mode:"
echo "  1) consolidated — one port per transport (TCP 7778 / UDP 7777). Recommended."
echo "  2) legacy       — split ports (UDP 7777 control + 7778 data). Old setup."
read -r -p "Net mode [1/2]: " NETMODE
NETMODE="${NETMODE:-1}"
case "${NETMODE}" in
    2|legacy|old|l) X4MP_LEGACY_NET=1 ;;
    *) X4MP_LEGACY_NET=0 ;;
esac
export X4MP_LEGACY_NET
read -r -p "Enable verbose sync/debug logging (X4MP_DEBUG=1)? [y/N]: " DBG
case "${DBG:-n}" in [Yy]*) X4MP_DEBUG=1 ;; esac
export X4MP_DEBUG

ask_yesno "Write an on-disk log file?" "Y"
if [ "$REPLY_YN" = "1" ]; then
    read -r -p "Where to store log files [${DEFAULT_LOG_DIR}]: " LOG_DIR
    LOG_DIR="${LOG_DIR:-${DEFAULT_LOG_DIR}}"
    X4MP_LOG=1
else
    LOG_DIR="${DEFAULT_LOG_DIR}"
    X4MP_LOG=0
fi
export X4MP_LOG

# --- Safe defaults (simulation model; override via env if needed) -----------
# Every participant's rendering zone is fully simulated AND synced: the host
# streams each client the ships in that client's current sector; the client
# binds them to its own local ships (greedy convergence) and pins them to the
# host's truth. See STATE.md for details.
export X4MP_PORT="${X4MP_PORT:-7777}"
export X4MP_MODULE="${X4MP_MODULE:-x4ep1_gamestart_boron1}"
export X4MP_DIFFICULTY="${X4MP_DIFFICULTY:-easy}"
export X4MP_OBJMODE="${X4MP_OBJMODE:-cache}"
export X4MP_STREAMSHIPS="${X4MP_STREAMSHIPS:-0}"
export X4MP_CLEANUP="${X4MP_CLEANUP:-0}"
export X4MP_STREAMS="${X4MP_STREAMS:-0}"
export X4MP_PAUSE="${X4MP_PAUSE:-0}"
export X4MP_FULLSIM="${X4MP_FULLSIM:-0}"
export X4MP_TELEPORT="${X4MP_TELEPORT:-0}"
export X4MP_INERT="${X4MP_INERT:-1}"          # AI suppression (1=thin-client, 0=hybrid)
export X4MP_GLIDE_SPEED="${X4MP_GLIDE_SPEED:-1500}"  # glide-in speed (m/s) on sector entry
export X4MP_GLIDE_MAX="${X4MP_GLIDE_MAX:-20000}"     # divergence above this snaps (offscreen)
export X4MP_CONVERGE_GREEDY="${X4MP_CONVERGE_GREEDY:-1}"
export X4MP_BIND_RADIUS="${X4MP_BIND_RADIUS:-1000}"
export X4MP_CONVERGE_RADIUS="${X4MP_CONVERGE_RADIUS:-20000}"
export X4MP_MAX_LAG_M="${X4MP_MAX_LAG_M:-300}"
export X4MP_UPDATE_HZ="${X4MP_UPDATE_HZ:-15}"
export X4MP_DELTA_M="${X4MP_DELTA_M:-0.5}"
export X4MP_HOST_TIMEOUT="${X4MP_HOST_TIMEOUT:-30}"
export X4MP_CLIENT_TIMEOUT="${X4MP_CLIENT_TIMEOUT:-15}"
export X4MP_UNIVERSE_TIMEOUT="${X4MP_UNIVERSE_TIMEOUT:-180}"

# --- Summary ----------------------------------------------------------------
echo ""
echo "=================================================="
echo "  Launch summary"
echo "=================================================="
echo "  Role:        ${ROLE_NAME}"
echo "  Start mode:  ${START_MODE_DESC}"
if [ "$ROLE_NAME" = "client" ]; then
    echo "  Host IP:     ${SERVER_IP}"
    echo "  Save:        ${SAVE_BASE}  (transferred from ${REMOTE_SAVE_DIR})"
else
    if [ -n "${X4MP_SAVE:-}" ]; then echo "  Source:      LOAD save '${X4MP_SAVE}'"; else echo "  Source:      NEW game '${X4MP_MODULE}'"; fi
fi
echo "  Extra flags: ${EXTRA_FLAGS:-<none>}" 
if [ "$ROLE_NAME" = "client" ]; then
    echo "  Sim mode:    ${SIM_MODE:-hybrid (INERT=${X4MP_INERT})}"
fi
echo "  Transport:   ${X4MP_TRANSPORT}"
echo "  Net mode:    $([ "${X4MP_LEGACY_NET}" = "0" ] && echo "consolidated (one port: ${X4MP_TRANSPORT} $([ "${X4MP_TRANSPORT}" = "tcp" ] && echo 7778 || echo 7777))" || echo "legacy (UDP 7777 control + ${X4MP_TRANSPORT} 7778 data)")"
echo "  Debug log:   ${X4MP_DEBUG}"
if [ "$X4MP_LOG" = "1" ]; then echo "  Log file:    ${LOG_DIR}/x4mp_<timestamp>.log"; else echo "  Log file:    disabled"; fi
echo "=================================================="
read -r -p "Start X4 now? [Y/n]: " GO
case "${GO:-Y}" in [Nn]*) echo "Aborted."; exit 0 ;; esac

# --- Display ----------------------------------------------------------------
# Prefer the user's existing Xwayland display :0 (needs the mutter auth cookie).
XAUTH_FILE="$(find /run/user/$(id -u) -maxdepth 1 -name '.mutter-Xwaylandauth.*' 2>/dev/null | head -1)"
if [ -S "/tmp/.X11-unix/X0" ] && [ -n "${XAUTH_FILE:-}" ]; then
    export DISPLAY=":0"
    export XAUTHORITY="${XAUTH_FILE}"
    echo ">> Using existing Xwayland display :0 (auth=${XAUTH_FILE})"
fi

# --- Launch -----------------------------------------------------------------
export SteamAppId="294140"
export SteamGameId="294140"
export LD_LIBRARY_PATH="${GAME_DIR}/lib:${LD_LIBRARY_PATH:-}"
# Force the real GPU Vulkan driver (radv). On the VM the loader otherwise picks
# lavapipe, which crashes X4. Harmless on machines that already default to radv.
export VK_ICD_FILENAMES="/usr/share/vulkan/icd.d/radeon_icd.x86_64.json"

cd "${GAME_DIR}"
mkdir -p "${LOG_DIR}"
# Keep only the newest few logs so the dir does not grow unbounded.
ls -1t "${LOG_DIR}"/x4mp_*.log 2>/dev/null | tail -n +4 | tr '\n' '\0' | xargs -0 -r rm -f || true

echo ""
echo "Launching X4 ..."
# shellcheck disable=SC2086  # EXTRA_FLAGS is intentionally word-split
if [ "$X4MP_LOG" = "0" ]; then
    echo ">> Logging DISABLED — output not saved"
    stdbuf -oL -eL ./X4 -nologo ${EXTRA_FLAGS} 2>&1 > /dev/null
else
    LOG_FILE="${LOG_DIR}/x4mp_$(date +%Y%m%d_%H%M%S).log"
    echo ">> X4 output log: ${LOG_FILE}"
    echo ">> (watch live: tail -f '${LOG_FILE}')"
    stdbuf -oL -eL ./X4 -nologo ${EXTRA_FLAGS} 2>&1 | tee "${LOG_FILE}"
fi
