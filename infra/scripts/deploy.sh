#!/usr/bin/env bash
# deploy.sh — Pull latest code and restart nanobot on the EC2 instance.
#
# Run this from your local machine after pushing new commits:
#   bash infra/scripts/deploy.sh ubuntu@<ELASTIC_IP>
#
# Or run it directly on the instance:
#   bash /opt/nanobot/infra/scripts/deploy.sh

set -euo pipefail

REPO_DIR="/opt/nanobot"
SERVICE="nanobot"

# ── When called with a remote host argument, SSH and re-invoke remotely ───────

if [ "${1:-}" != "--remote" ] && [ -n "${1:-}" ]; then
    REMOTE_HOST="$1"
    echo "Deploying to $REMOTE_HOST..."
    ssh -o StrictHostKeyChecking=no "$REMOTE_HOST" \
        "bash $REPO_DIR/infra/scripts/deploy.sh --remote"
    exit 0
fi

# ── Running on the instance ───────────────────────────────────────────────────

echo "=== nanobot deploy started at $(date) ==="

# 1. Pull latest code
echo "→ Pulling latest code..."
git -C "$REPO_DIR" fetch origin
git -C "$REPO_DIR" pull origin "$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
echo "   HEAD is now: $(git -C "$REPO_DIR" rev-parse --short HEAD)"

# 2. Sync Python dependencies
echo "→ Syncing Python dependencies..."
if command -v uv &>/dev/null; then
    cd "$REPO_DIR" && uv sync --python 3.11 --no-dev 2>/dev/null || uv pip install -e .
else
    PYTHON_BIN="$(find "$REPO_DIR/.venv/bin" -name "python*" | head -1 || which python3)"
    "$PYTHON_BIN" -m pip install -e "$REPO_DIR" --quiet
fi

# 3. Reinstall systemd unit from repo (keeps ExecStartPre=+ and other unit changes in sync)
echo "→ Installing systemd unit from repo..."
sudo env REPO_DIR="$REPO_DIR" NANOBOT_USER="ubuntu" NANOBOT_HOME="/home/ubuntu" \
    bash "$REPO_DIR/infra/scripts/install_nanobot_systemd_unit.sh"

# 4. Refresh secrets from SSM
echo "→ Refreshing secrets..."
sudo /usr/local/bin/nanobot-fetch-secrets || echo "   WARNING: secret refresh failed"

# 5. Restart service
echo "→ Restarting $SERVICE service..."
sudo systemctl restart "$SERVICE"
sleep 3
sudo systemctl is-active --quiet "$SERVICE" \
    && echo "   Service is running." \
    || { echo "   ERROR: Service failed to start. Check: journalctl -u $SERVICE -n 50"; exit 1; }

echo "=== nanobot deploy complete at $(date) ==="
