#!/usr/bin/env bash
# user_data.sh — EC2 bootstrap script for nanobot-core
#
# Rendered by Terraform templatefile(); variables injected at plan time:
#   repo_url, repo_branch, ssm_prefix, gateway_port,
#   domain_name, certbot_email, project
#
# Runs once as root on first boot. Progress is logged to /var/log/nanobot-init.log.
# To re-run manually: sudo bash /opt/nanobot/infra/scripts/user_data.sh

set -euo pipefail
exec > >(tee /var/log/nanobot-init.log | logger -t nanobot-init) 2>&1

NANOBOT_USER="ubuntu"
NANOBOT_HOME="/home/$NANOBOT_USER"
REPO_DIR="/opt/nanobot"
DATA_DIR="/data/nanobot"
SECRETS_ENV="/etc/nanobot/secrets.env"
NGINX_CONF="/etc/nginx/sites-available/nanobot"
SSM_PREFIX="${ssm_prefix}"
REPO_URL="${repo_url}"
REPO_BRANCH="${repo_branch}"
GATEWAY_PORT="${gateway_port}"
DOMAIN="${domain_name}"
CERTBOT_EMAIL="${certbot_email}"
PROJECT="${project}"

echo "=== nanobot EC2 bootstrap started at $(date) ==="

# ── 1. System packages ────────────────────────────────────────────────────────

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get upgrade -yq
apt-get install -yq \
    ca-certificates curl git jq awscli \
    nginx certbot python3-certbot-nginx \
    nodejs npm build-essential

# ── 2. Python 3.11 + uv ──────────────────────────────────────────────────────

# Install Python 3.11 via deadsnakes PPA (Ubuntu 22.04 ships 3.10 by default)
add-apt-repository -y ppa:deadsnakes/ppa
apt-get update -q
apt-get install -yq python3.11 python3.11-venv python3.11-dev

# Install uv system-wide so both root and ubuntu can use it
curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh
export PATH="/usr/local/bin:$PATH"

# Grant ubuntu passwordless sudo for systemctl nanobot only (safer than full sudo)
echo "ubuntu ALL=(ALL) NOPASSWD: /bin/systemctl start nanobot, /bin/systemctl stop nanobot, /bin/systemctl restart nanobot, /bin/systemctl status nanobot, /usr/local/bin/nanobot-fetch-secrets" \
    > /etc/sudoers.d/nanobot
chmod 440 /etc/sudoers.d/nanobot

# ── 3. Mount data EBS volume ──────────────────────────────────────────────────
# The volume is attached as /dev/xvdf (or /dev/nvme1n1 on Nitro instances).
# Terraform attaches the volume concurrently with first boot — wait up to 90 s.

echo "Waiting for data EBS volume to be attached..."
DATA_DEVICE=""
for _i in $(seq 1 18); do
    if [ -b /dev/xvdf ]; then
        DATA_DEVICE="/dev/xvdf"; break
    elif [ -b /dev/nvme1n1 ]; then
        DATA_DEVICE="/dev/nvme1n1"; break
    fi
    sleep 5
done

if [ -n "$DATA_DEVICE" ]; then
    if ! blkid "$DATA_DEVICE" &>/dev/null; then
        echo "Formatting data volume $DATA_DEVICE..."
        mkfs.ext4 -L nanobot-data "$DATA_DEVICE"
    fi
    mkdir -p "$DATA_DIR"
    if ! grep -q "LABEL=nanobot-data" /etc/fstab; then
        echo "LABEL=nanobot-data  $DATA_DIR  ext4  defaults,nofail  0  2" >> /etc/fstab
    fi
    mount -a || true
    chown "$NANOBOT_USER:$NANOBOT_USER" "$DATA_DIR"
else
    echo "WARNING: No data EBS device found. Using root volume for data."
    mkdir -p "$DATA_DIR"
    chown "$NANOBOT_USER:$NANOBOT_USER" "$DATA_DIR"
fi

# Symlink ~/.nanobot to the data volume so all default paths resolve correctly.
NANOBOT_DATA_SUBDIR="$DATA_DIR/.nanobot"
mkdir -p "$NANOBOT_DATA_SUBDIR"
chown -R "$NANOBOT_USER:$NANOBOT_USER" "$NANOBOT_DATA_SUBDIR"

NANOBOT_DOTDIR="$NANOBOT_HOME/.nanobot"
if [ ! -L "$NANOBOT_DOTDIR" ] && [ ! -d "$NANOBOT_DOTDIR" ]; then
    ln -s "$NANOBOT_DATA_SUBDIR" "$NANOBOT_DOTDIR"
    chown -h "$NANOBOT_USER:$NANOBOT_USER" "$NANOBOT_DOTDIR"
fi

# ── 4. Clone / update repository ─────────────────────────────────────────────

if [ -d "$REPO_DIR/.git" ]; then
    echo "Repository already exists, pulling latest..."
    git -C "$REPO_DIR" fetch origin
    git -C "$REPO_DIR" checkout "$REPO_BRANCH"
    git -C "$REPO_DIR" pull origin "$REPO_BRANCH"
else
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
fi

chown -R "$NANOBOT_USER:$NANOBOT_USER" "$REPO_DIR"

# ── 5. Install Python dependencies ────────────────────────────────────────────

cd "$REPO_DIR"
if ! sudo -u "$NANOBOT_USER" HOME="$NANOBOT_HOME" uv sync --python 3.11 --no-dev 2>/dev/null; then
    sudo -u "$NANOBOT_USER" HOME="$NANOBOT_HOME" python3.11 -m venv .venv
    .venv/bin/pip install -e . -q
fi

PYTHON_BIN="$REPO_DIR/.venv/bin/python"
if [ ! -f "$PYTHON_BIN" ]; then
    PYTHON_BIN="$(which python3.11)"
fi

# ── 6. Fetch secrets from SSM and write environment file ─────────────────────

mkdir -p /etc/nanobot
chmod 700 /etc/nanobot

# This helper script also runs on every service restart via ExecStartPre.
cat > /usr/local/bin/nanobot-fetch-secrets << 'FETCH_EOF'
#!/usr/bin/env bash
set -euo pipefail

SSM_PREFIX="__SSM_PREFIX__"
REGION="$(curl -sf http://169.254.169.254/latest/meta-data/placement/region || echo us-east-1)"
SECRETS_ENV="/etc/nanobot/secrets.env"

fetch() {
    local name="$1"
    aws ssm get-parameter \
        --name "$SSM_PREFIX/$name" \
        --with-decryption \
        --query "Parameter.Value" \
        --output text \
        --region "$REGION" 2>/dev/null || echo ""
}

echo "# Auto-generated by nanobot-fetch-secrets — do not edit manually" > "$SECRETS_ENV"
echo "# Regenerated at $(date)" >> "$SECRETS_ENV"

add_env() {
    local env_var="$1"
    local ssm_name="$2"
    local value
    value="$(fetch "$ssm_name")"
    if [ -n "$value" ] && [ "$value" != "REPLACE_ME" ]; then
        echo "$${env_var}=$${value}" >> "$SECRETS_ENV"
    fi
}

add_env "NANOBOT_PROVIDERS__ANTHROPIC__API_KEY"   "anthropic_api_key"
add_env "NANOBOT_PROVIDERS__OPENAI__API_KEY"       "openai_api_key"
add_env "NANOBOT_PROVIDERS__OPENROUTER__API_KEY"   "openrouter_api_key"
add_env "NANOBOT_PROVIDERS__DEEPSEEK__API_KEY"     "deepseek_api_key"
add_env "NANOBOT_PROVIDERS__GEMINI__API_KEY"       "gemini_api_key"
add_env "NANOBOT_GATEWAY__HTTP_API_KEY"            "gateway_http_api_key"
add_env "NANOBOT_TOOLS__WEB__SEARCH__API_KEY"      "brave_search_api_key"

chmod 600 "$SECRETS_ENV"
echo "Secrets written to $SECRETS_ENV"
FETCH_EOF

# Inject the actual SSM prefix into the helper
sed -i "s|__SSM_PREFIX__|$SSM_PREFIX|g" /usr/local/bin/nanobot-fetch-secrets
chmod +x /usr/local/bin/nanobot-fetch-secrets

# Run it now for the initial setup
/usr/local/bin/nanobot-fetch-secrets || echo "WARNING: secret fetch failed (may not have SSM access yet)"

# ── 7. Run nanobot onboard (creates workspace + default config) ───────────────

if [ ! -f "$NANOBOT_DOTDIR/config.json" ]; then
    echo "Running nanobot onboard..."
    sudo -u "$NANOBOT_USER" \
        HOME="$NANOBOT_HOME" \
        "$PYTHON_BIN" -m nanobot onboard --non-interactive 2>/dev/null || \
    sudo -u "$NANOBOT_USER" \
        HOME="$NANOBOT_HOME" \
        "$PYTHON_BIN" -m nanobot onboard || true
fi

# ── 8. Install systemd service ────────────────────────────────────────────────

export PYTHON_BIN
NANOBOT_USER="$NANOBOT_USER" NANOBOT_HOME="$NANOBOT_HOME" REPO_DIR="$REPO_DIR" \
    bash "$REPO_DIR/infra/scripts/install_nanobot_systemd_unit.sh"

systemctl enable nanobot.service
systemctl start  nanobot.service || true   # first-start may fail if secrets not yet set; that is expected

# ── 9. nginx reverse proxy ────────────────────────────────────────────────────

# nginx requires at least one server_name token; "_" is the usual catch-all when no domain is set
NGINX_SERVER_NAME="$${DOMAIN:-_}"

cat > "$NGINX_CONF" << NGINX_EOF
server {
    listen 80;
    server_name $NGINX_SERVER_NAME;

    location /health {
        proxy_pass         http://127.0.0.1:$GATEWAY_PORT/health;
        proxy_set_header   Host \$host;
        proxy_read_timeout 10s;
    }

    location / {
        proxy_pass         http://127.0.0.1:$GATEWAY_PORT;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_buffering    off;
    }
}
NGINX_EOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/nanobot
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# ── 10. Let's Encrypt TLS (only when domain is configured) ───────────────────

if [ -n "$DOMAIN" ] && [ -n "$CERTBOT_EMAIL" ]; then
    echo "Requesting TLS certificate for $DOMAIN..."
    certbot --nginx \
        -d "$DOMAIN" \
        --email "$CERTBOT_EMAIL" \
        --agree-tos \
        --non-interactive \
        --redirect || echo "WARNING: certbot failed — check DNS propagation and try manually"
fi

echo "=== nanobot EC2 bootstrap complete at $(date) ==="
echo "Service status:"
systemctl status nanobot.service --no-pager || true
