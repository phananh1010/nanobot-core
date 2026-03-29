This project contain the core only logic of nanobot framework.
The project aims to provide a universal, flexible agentic logic where tools and mcp can be defined,

The agentic loop core logic should be tool agnostic, but maintain these properties:
+ Tool flexibility: any tools or mcp can be defined, the model
+ Context engineering with context agnostic: even thought perming context engineer, the framwork should adapt to different system of context.
+ input flexibility: Should not relied on a fixed number of channels, but the input query should be in raw text based format, so that it can be used in any system.

## HTTP API (curl and scripts)

Start the gateway so the agent listens for HTTP requests:

```bash
python -m nanobot gateway
# optional: --port 18790 --workspace /path/to/workspace --config /path/to/config.json
```

Default bind is `0.0.0.0` and port **18790** (see `gateway.host`, `gateway.port`, and optional `gateway.http_api_key` in your config).

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/health` | Liveness: returns `{"status":"ok"}` |
| `POST` | `/v1/chat` | Send a user message; returns `{"response":"..."}` when the run finishes |
| `POST` | `/v1/chat/stream` | Same JSON body as `/v1/chat`; response is **NDJSON** (`application/x-ndjson`): optional `progress` / `tool_hint` lines, then a final `done` or `error` line |

### Request body (`POST /v1/chat` and `POST /v1/chat/stream`)

JSON object:

- **`message`** or **`content`** (string, required): the user text sent to the agent.
- **`session`** (string, optional): session key for conversation continuity. If omitted or empty, the server uses `http:default`. If the value has no `:` (e.g. `my-chat`), it is normalized to `http:my-chat`. Keys with a colon (e.g. `cli:direct`) are used as-is.

### Authentication (optional)

If `gateway.http_api_key` is set in config, every `POST /v1/chat` must include the same secret in either header:

- `Authorization: Bearer <your-key>`, or
- `X-API-Key: <your-key>`

### Examples

Health check:

```bash
curl -s http://127.0.0.1:18790/health
```

Chat (minimal):

```bash
curl -s http://127.0.0.1:18790/v1/chat \
  -H 'Content-Type: application/json' \
  -d '{"message":"Hello"}'
```

Chat with a named session:

```bash
curl -s http://127.0.0.1:18790/v1/chat \
  -H 'Content-Type: application/json' \
  -d '{"message":"Remember my name is Ada","session":"http:ada"}'
```

With API key:

```bash
curl -s http://127.0.0.1:18790/v1/chat \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_KEY' \
  -d '{"message":"Hi"}'
```

Any HTTP client that can send `POST` with `Content-Type: application/json` and read JSON (e.g. `fetch`, `httpx`, `requests`) can use the same URL, headers, and body shape as above.

---

## AWS Deployment (personal, cheapest)

The `infra/` directory contains everything needed to deploy nanobot on AWS EC2 using Terraform.

### Why EC2 (not Lambda or ECS)

nanobot `gateway` is a **long-running process** — it holds persistent channel connections (Telegram polling, Slack WebSocket, etc.), maintains in-memory state, and writes sessions to disk. Lambda is fundamentally incompatible. ECS Fargate works but costs ~$25–35/month for personal use. EC2 costs **$0/month** under the AWS free tier (t2.micro, 12 months) and ~$6/month after.

### Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.6
- AWS CLI configured (`aws configure`)
- An SSH public key

### One-time S3 backend setup

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1

aws s3 mb s3://nanobot-tfstate-$ACCOUNT_ID --region $REGION
aws dynamodb create-table \
  --table-name nanobot-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region $REGION
```

Then uncomment the `backend "s3"` block in `infra/terraform/main.tf` and fill in the bucket name and region.

### Deploy

```bash
cd infra/terraform

# Create a tfvars file (never commit this — it contains your SSH key)
cat > terraform.tfvars <<EOF
ssh_public_key = "$(cat ~/.ssh/id_ed25519.pub)"
repo_url       = "https://github.com/your-org/nanobot-core.git"
# Optional: set a domain for HTTPS
# domain_name    = "bot.example.com"
# certbot_email  = "you@example.com"
EOF

terraform init
terraform plan
terraform apply
```

Outputs include the Elastic IP, SSH command, and gateway URL.

### Populate secrets

After `terraform apply` creates the SSM parameters (all set to `REPLACE_ME`), fill in the values you actually use:

```bash
REGION=us-east-1

# LLM providers — set the ones you use, skip the rest
aws ssm put-parameter --name /nanobot/anthropic_api_key \
  --value "sk-ant-..." --type SecureString --overwrite --region $REGION

aws ssm put-parameter --name /nanobot/openai_api_key \
  --value "sk-..." --type SecureString --overwrite --region $REGION

aws ssm put-parameter --name /nanobot/openrouter_api_key \
  --value "sk-or-..." --type SecureString --overwrite --region $REGION

# Protect the HTTP API
aws ssm put-parameter --name /nanobot/gateway_http_api_key \
  --value "$(openssl rand -hex 32)" --type SecureString --overwrite --region $REGION

# Channels (set the ones you want enabled)
aws ssm put-parameter --name /nanobot/telegram_bot_token \
  --value "123456:ABC..." --type SecureString --overwrite --region $REGION
```

The SSM parameters map to these `NANOBOT_*` env vars (loaded by the systemd service via `/etc/nanobot/secrets.env`):

| SSM parameter | Environment variable |
|---|---|
| `/nanobot/anthropic_api_key` | `NANOBOT_PROVIDERS__ANTHROPIC__API_KEY` |
| `/nanobot/openai_api_key` | `NANOBOT_PROVIDERS__OPENAI__API_KEY` |
| `/nanobot/openrouter_api_key` | `NANOBOT_PROVIDERS__OPENROUTER__API_KEY` |
| `/nanobot/deepseek_api_key` | `NANOBOT_PROVIDERS__DEEPSEEK__API_KEY` |
| `/nanobot/gemini_api_key` | `NANOBOT_PROVIDERS__GEMINI__API_KEY` |
| `/nanobot/gateway_http_api_key` | `NANOBOT_GATEWAY__HTTP_API_KEY` |
| `/nanobot/brave_search_api_key` | `NANOBOT_TOOLS__WEB__SEARCH__API_KEY` |

Channel tokens (`telegram_bot_token`, `slack_bot_token`, `discord_bot_token`) are written into `~/.nanobot/config.json` during bootstrap; configure them manually via `nanobot onboard` after SSH-ing into the instance.

### Configure channels and onboard

```bash
ssh ubuntu@<ELASTIC_IP>
cd /opt/nanobot
python -m nanobot onboard      # interactive wizard
sudo systemctl restart nanobot # pick up new config
```

### Deploy updates

After pushing new commits to your repo:

```bash
bash infra/scripts/deploy.sh ubuntu@<ELASTIC_IP>
```

Or on the instance directly:

```bash
sudo bash /opt/nanobot/infra/scripts/deploy.sh --remote
```

### Useful commands on the instance

```bash
# Live logs
journalctl -u nanobot -f

# Service status
systemctl status nanobot

# Manual restart
sudo systemctl restart nanobot

# Re-fetch secrets from SSM (e.g. after rotating an API key)
sudo /usr/local/bin/nanobot-fetch-secrets && sudo systemctl restart nanobot
```

### Switching to t4g.micro after free tier

Once your 12-month free tier expires, switch to the cheaper ARM instance:

```bash
# In infra/terraform/terraform.tfvars
instance_type    = "t4g.micro"
ami_architecture = "arm64"
```

```bash
terraform apply   # replaces the instance; data EBS volume is preserved
```

### Docker (local dev or future ECS migration)

A `Dockerfile` is included for local development and as a migration path to ECS:

```bash
docker build -t nanobot .
docker run -p 18790:18790 \
  -v ~/.nanobot:/data/nanobot \
  -e NANOBOT_PROVIDERS__ANTHROPIC__API_KEY=sk-ant-... \
  nanobot
```
