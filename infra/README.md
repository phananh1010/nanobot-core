# nanobot AWS Infrastructure

This directory contains the Terraform configuration and operational scripts to run nanobot on AWS EC2 — the cheapest viable option for a personal, long-running AI assistant.

---

## Why EC2 and not Lambda or ECS

nanobot `gateway` is a persistent process. It cannot run on Lambda or cheaply on ECS because:

| Requirement | Lambda | ECS Fargate | EC2 |
|---|---|---|---|
| Long-running process | No (15 min max) | Yes | Yes |
| Persistent WebSocket/polling channels | No | Yes | Yes |
| In-memory asyncio state across requests | No | Yes | Yes |
| Local filesystem (session JSONL, cron) | No (/tmp only) | Yes (needs EFS) | Yes |
| Node subprocess (WhatsApp bridge) | No | Sidecar only | Yes |
| Cost for personal use | ~$0 (but incompatible) | ~$25–35/mo | ~$0–6/mo |

EC2 t2.micro is **free tier eligible for 12 months**. After that, t4g.micro (ARM, 1 GB) costs ~$6/month on-demand or ~$4/month reserved.

---

## Architecture

```
Internet
    │
    ▼
Elastic IP (static, free while attached)
    │
    ▼
┌──────────────────────── EC2 instance ─────────────────────────┐
│                                                                │
│  nginx :80/:443  ──────────────────►  nanobot gateway :18790  │
│  (TLS termination,                    (uvicorn + agent loop   │
│   optional domain)                     + channel listeners    │
│                                         + cron + heartbeat)   │
│                                                │               │
│                                        ~/.nanobot/             │
│                                        (symlink → /data/…)    │
└──────────────────────────────── EBS root 20 GB ───────────────┘
                                                │
                                         EBS data volume 10 GB
                                         /data/nanobot/
                                         ├── .nanobot/
                                         │   ├── config.json
                                         │   ├── workspace/     (sessions, memory)
                                         │   ├── sessions/
                                         │   └── cron/
                                         └── ...

                 IAM Instance Profile
                        │
                        ▼
              SSM Parameter Store
              /nanobot/anthropic_api_key
              /nanobot/openai_api_key
              /nanobot/gateway_http_api_key
              /nanobot/telegram_bot_token
              ... (all secrets)
```

The instance never stores credentials on disk. On each service start, `ExecStartPre` calls `/usr/local/bin/nanobot-fetch-secrets` which pulls all `/nanobot/*` SSM parameters and writes them to `/etc/nanobot/secrets.env` (mode 600). The systemd unit reads that file via `EnvironmentFile=`.

---

## Directory layout

```
infra/
├── terraform/
│   ├── main.tf          # AWS provider + S3 remote state backend (commented until bucket exists)
│   ├── variables.tf     # All input variables with descriptions and defaults
│   ├── outputs.tf       # public_ip, ssh_command, gateway_url, health_check_url
│   ├── networking.tf    # VPC, public subnet, IGW, route table, security group, Elastic IP
│   ├── iam.tf           # IAM role + instance profile + SSM read policy + SSM Session Manager
│   ├── ec2.tf           # Ubuntu 22.04 AMI lookup, key pair, EC2 instance, EBS data volume
│   └── secrets.tf       # SSM Parameter Store placeholders for all provider + channel secrets
└── scripts/
    ├── user_data.sh     # EC2 first-boot bootstrap (rendered by Terraform templatefile)
    └── deploy.sh        # Iterative deploy: git pull → sync deps → refresh secrets → restart
```

```
systemd/
└── nanobot.service      # systemd unit installed by user_data.sh
```

```
Dockerfile               # Multi-stage python:3.11-slim build (local dev + future ECS path)
.dockerignore
```

---

## Terraform resources

### `networking.tf`

| Resource | Purpose |
|---|---|
| `aws_vpc.nanobot` | Dedicated VPC (`10.0.0.0/16`) with DNS enabled |
| `aws_internet_gateway.nanobot` | Route internet traffic into the VPC |
| `aws_subnet.public` | Single public subnet in the first available AZ |
| `aws_route_table.public` | Default route `0.0.0.0/0 → IGW` |
| `aws_security_group.nanobot` | Inbound: SSH (22), HTTP (80), HTTPS (443), gateway (18790). Outbound: all |
| `aws_eip.nanobot` | Elastic IP (free while attached). Gives the instance a stable public address |

### `iam.tf`

| Resource | Purpose |
|---|---|
| `aws_iam_role.nanobot_instance` | EC2 instance role with EC2 trust policy |
| `aws_iam_role_policy.ssm_read` | Allows `ssm:GetParameter*` on `arn:…:parameter/nanobot/*` and `kms:Decrypt` via SSM |
| `aws_iam_role_policy_attachment.ssm_managed` | Attaches `AmazonSSMManagedInstanceCore` — enables SSM Session Manager shell access (no SSH required) |
| `aws_iam_instance_profile.nanobot` | Wraps the role so EC2 can assume it |

### `ec2.tf`

| Resource | Purpose |
|---|---|
| `data.aws_ami.ubuntu` | Looks up the latest Ubuntu 22.04 LTS AMI (amd64 or arm64, controlled by `var.ami_architecture`) |
| `aws_key_pair.nanobot` | EC2 key pair from your SSH public key |
| `aws_instance.nanobot` | t2.micro (default) with 20 GB encrypted root volume, IAM profile, and `user_data` bootstrap |
| `aws_ebs_volume.data` | Separate 10 GB gp3 encrypted data volume for `~/.nanobot` |
| `aws_volume_attachment.data` | Attaches the data volume as `/dev/xvdf` |

The instance has `ignore_changes = [user_data]` — re-provisioning is done via `deploy.sh`, not by replacing the instance.

### `secrets.tf`

Creates `SecureString` SSM parameters under `/nanobot/` as placeholders (`REPLACE_ME`). All have `lifecycle { ignore_changes = [value] }` so Terraform never overwrites a value you've set manually.

| SSM parameter | Maps to env var |
|---|---|
| `/nanobot/anthropic_api_key` | `NANOBOT_PROVIDERS__ANTHROPIC__API_KEY` |
| `/nanobot/openai_api_key` | `NANOBOT_PROVIDERS__OPENAI__API_KEY` |
| `/nanobot/openrouter_api_key` | `NANOBOT_PROVIDERS__OPENROUTER__API_KEY` |
| `/nanobot/deepseek_api_key` | `NANOBOT_PROVIDERS__DEEPSEEK__API_KEY` |
| `/nanobot/gemini_api_key` | `NANOBOT_PROVIDERS__GEMINI__API_KEY` |
| `/nanobot/gateway_http_api_key` | `NANOBOT_GATEWAY__HTTP_API_KEY` |
| `/nanobot/brave_search_api_key` | `NANOBOT_TOOLS__WEB__SEARCH__API_KEY` |
| `/nanobot/telegram_bot_token` | written to `config.json` via `nanobot onboard` |
| `/nanobot/slack_bot_token` | written to `config.json` via `nanobot onboard` |
| `/nanobot/discord_bot_token` | written to `config.json` via `nanobot onboard` |

---

## Scripts

### `infra/scripts/user_data.sh`

Runs once as root on first boot. Terraform injects variables via `templatefile()`.

Sequence:

1. **System packages** — `apt-get upgrade`, install `nginx`, `certbot`, `nodejs`, `npm`, `awscli`, `jq`
2. **uv** — install the uv Python package manager from `astral.sh`
3. **EBS data volume** — detect `/dev/xvdf` or `/dev/nvme1n1`, format with ext4 on first boot, mount at `/data/nanobot`, add to `/etc/fstab`, symlink `~/.nanobot → /data/nanobot/.nanobot`
4. **Clone repository** — `git clone` into `/opt/nanobot` (or `git pull` if already present)
5. **Python deps** — `uv sync` inside `/opt/nanobot`
6. **Fetch secrets** — write `/usr/local/bin/nanobot-fetch-secrets` (the helper script) and run it to create `/etc/nanobot/secrets.env`
7. **nanobot onboard** — create `~/.nanobot/config.json` and workspace if not already present
8. **systemd service** — copy `systemd/nanobot.service`, patch user/path placeholders, `systemctl enable` and `start`
9. **nginx** — write `/etc/nginx/sites-available/nanobot` (reverse proxy to `:18790`), reload nginx
10. **TLS** — if `domain_name` and `certbot_email` are set, run `certbot --nginx`

Log output: `/var/log/nanobot-init.log`

### `infra/scripts/deploy.sh`

Iterative update script. When called with a host argument it SSHes in and re-invokes itself with `--remote`:

```bash
bash infra/scripts/deploy.sh ubuntu@<IP>   # from your laptop
```

Steps on the instance:

1. `git pull` the current branch
2. `uv sync` to pick up any new dependencies
3. `/usr/local/bin/nanobot-fetch-secrets` to refresh `/etc/nanobot/secrets.env`
4. `systemctl restart nanobot` and verify it is active

---

## Systemd unit (`systemd/nanobot.service`)

```
ExecStartPre=/usr/local/bin/nanobot-fetch-secrets
EnvironmentFile=-/etc/nanobot/secrets.env
ExecStart=<python> -m nanobot gateway
Restart=on-failure
RestartSec=10s
StartLimitBurst=5 / 120s
```

The `ExecStartPre` ensures secrets are always fresh before each start (important after an API key rotation). The `-` prefix on `EnvironmentFile` means the service still starts even if the file is temporarily absent.

---

## Secrets flow

```
terraform apply
    └─► aws_ssm_parameter created (value = "REPLACE_ME")

aws ssm put-parameter --name /nanobot/anthropic_api_key --value "sk-ant-..."
    └─► value stored encrypted in SSM (KMS)

EC2 instance boot / service start
    └─► IAM instance role → GetParametersByPath(/nanobot/)
    └─► /usr/local/bin/nanobot-fetch-secrets writes /etc/nanobot/secrets.env
    └─► systemd loads EnvironmentFile
    └─► python -m nanobot gateway reads NANOBOT_PROVIDERS__ANTHROPIC__API_KEY
```

Rotating a key:

```bash
aws ssm put-parameter --name /nanobot/anthropic_api_key \
  --value "sk-ant-NEW..." --type SecureString --overwrite
ssh ubuntu@<IP> "sudo /usr/local/bin/nanobot-fetch-secrets && sudo systemctl restart nanobot"
```

---

## Cost breakdown (us-east-1, 2025)

| Resource | Free tier | After free tier |
|---|---|---|
| EC2 t2.micro (750 h/mo) | $0 for 12 months | ~$8.50/mo on-demand |
| EC2 t4g.micro (swap after year 1) | — | ~$6.10/mo on-demand, ~$3.70 reserved |
| EBS root 20 GB gp3 | 30 GB free | ~$1.60/mo |
| EBS data 10 GB gp3 | (within 30 GB) | ~$0.80/mo |
| Elastic IP (attached) | Free | Free |
| SSM Parameter Store (standard) | 10,000 params free | Free |
| S3 state bucket (~1 MB) | 5 GB free | < $0.01/mo |
| DynamoDB lock table | 25 GB free | Free |
| **Total year 1** | **~$0/mo** | |
| **Total year 2+ (t4g.micro)** | | **~$8–9/mo** |

---

## Variables reference

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | AWS region |
| `instance_type` | `t2.micro` | EC2 instance type |
| `ami_architecture` | `amd64` | `amd64` or `arm64` (use `arm64` for t4g) |
| `data_volume_size_gb` | `10` | Size of the separate data EBS volume |
| `ssh_public_key` | required | Contents of your SSH public key |
| `allowed_ssh_cidr` | `0.0.0.0/0` | Restrict SSH to your IP for better security |
| `gateway_port` | `18790` | Must match `gateway.port` in nanobot config |
| `repo_url` | — | Git HTTPS URL for `git clone` on EC2 |
| `repo_branch` | `main` | Branch to check out |
| `domain_name` | `""` | Optional domain for nginx + Let's Encrypt TLS |
| `certbot_email` | `""` | Required with `domain_name` |
