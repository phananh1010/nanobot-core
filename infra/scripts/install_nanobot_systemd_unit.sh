#!/usr/bin/env bash
# Install or refresh /etc/systemd/system/nanobot.service from the repo template.
# Used by user_data.sh (first boot) and deploy.sh (every deploy) so the live unit
# always matches systemd/nanobot.service — including ExecStartPre=+ for root.
#
# Must run as root. Environment:
#   REPO_DIR      — default /opt/nanobot
#   NANOBOT_USER  — default ubuntu
#   NANOBOT_HOME  — default /home/$NANOBOT_USER
#   PYTHON_BIN    — optional; if unset, uses .venv/bin/python or python3.11/python3

set -euo pipefail

NANOBOT_USER="${NANOBOT_USER:-ubuntu}"
NANOBOT_HOME="${NANOBOT_HOME:-/home/$NANOBOT_USER}"
REPO_DIR="${REPO_DIR:-/opt/nanobot}"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "ERROR: run as root (sudo)." >&2
    exit 1
fi

if [ -z "${PYTHON_BIN:-}" ]; then
    PYTHON_BIN="$REPO_DIR/.venv/bin/python"
    if [ ! -f "$PYTHON_BIN" ]; then
        PYTHON_BIN="$(command -v python3.11 2>/dev/null || command -v python3)"
    fi
fi

UNIT_SRC="$REPO_DIR/systemd/nanobot.service"
UNIT_DST="/etc/systemd/system/nanobot.service"

if [ ! -f "$UNIT_SRC" ]; then
    echo "ERROR: unit template missing: $UNIT_SRC" >&2
    exit 1
fi

cp "$UNIT_SRC" "$UNIT_DST"
sed -i "s|__NANOBOT_USER__|$NANOBOT_USER|g" "$UNIT_DST"
sed -i "s|__NANOBOT_HOME__|$NANOBOT_HOME|g" "$UNIT_DST"
sed -i "s|__REPO_DIR__|$REPO_DIR|g" "$UNIT_DST"
sed -i "s|__PYTHON_BIN__|$PYTHON_BIN|g" "$UNIT_DST"

systemctl daemon-reload
