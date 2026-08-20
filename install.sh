#!/bin/bash
# ============================================================================
# install.sh — copy the X4MP extensions into your X4 game's extensions folder.
#
# Usage:
#   X4MP_GAME_DIR="/path/to/X4 Foundations" ./install.sh
#   ./install.sh "/path/to/X4 Foundations"
#   ./install.sh            (prompts for the path)
#
# It copies x4native/, x4mp/, x4mp_stream/ into "<game dir>/extensions/".
# Existing files of the same name are overwritten; other extensions are left
# untouched.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${HERE}/extensions"

# --- resolve the game dir ---------------------------------------------------
GAME_DIR="${X4MP_GAME_DIR:-${1:-}}"
if [ -z "${GAME_DIR}" ]; then
    # Guess: look for a sibling "X4 Foundations" next to this package.
    if [ -d "${HERE}/X4 Foundations/extensions" ]; then
        GAME_DIR="${HERE}/X4 Foundations"
    fi
fi
if [ -z "${GAME_DIR}" ]; then
    read -r -p "Path to your X4 game folder (the one containing 'X4' and 'extensions/'): " GAME_DIR
fi

if [ ! -d "${GAME_DIR}" ]; then
    echo "ERROR: game folder not found: ${GAME_DIR}" >&2
    exit 1
fi
if [ ! -d "${GAME_DIR}/extensions" ]; then
    echo "ERROR: '${GAME_DIR}/extensions' does not exist — is that the X4 game folder?" >&2
    exit 1
fi
if [ ! -f "${GAME_DIR}/X4" ]; then
    echo "WARNING: no 'X4' executable found in '${GAME_DIR}' — proceeding anyway." >&2
fi

echo ">> Installing X4MP extensions into: ${GAME_DIR}/extensions"
for ext in x4native x4mp x4mp_stream; do
    if [ ! -d "${SRC}/${ext}" ]; then
        echo "ERROR: missing ${SRC}/${ext} in this package" >&2
        exit 1
    fi
    # Copy the whole extension folder (overwriting same-named files).
    cp -r "${SRC}/${ext}/." "${GAME_DIR}/extensions/${ext}/"
    echo "   installed: ${ext}"
done

echo ""
echo ">> Done. Next steps:"
echo ">>   1. Make sure x4native, x4mp and x4mp_stream are ENABLED in the game."
echo ">>   2. Start the host:  X4MP_GAME_DIR=\"${GAME_DIR}\" ${HERE}/scripts/x4mp_launcher.sh"
echo ">>   3. Start a client:  X4MP_GAME_DIR=\"${GAME_DIR}\" <other machine> .../scripts/x4mp_launcher.sh"
echo ">>   (See README.md for the full guide.)"
