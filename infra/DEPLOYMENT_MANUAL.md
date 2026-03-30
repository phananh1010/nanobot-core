# Deployment Manual — nanobot on AWS EC2

Step-by-step guide to deploy `nanobot gateway` on a single EC2 instance using Terraform. Estimated time: 20–30 minutes on first deploy.

---

## Prerequisites

Install these on your **Ubuntu** workstation before starting (commands assume Bash).

### 1. AWS CLI

```bash
sudo apt update
sudo apt install -y unzip curl git

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip
```

Configure with your AWS credentials:

```bash
aws configure
# AWS Access Key ID:     <your key>
# AWS Secret Access Key: <your secret>
# Default region name:   us-east-1
# Default output format: json
```

Verify:

```bash
aws sts get-caller-identity
```

### AWS IAM permissions (common middle ground)

The IAM user or role whose credentials you configure in `aws configure` must be allowed to run the AWS CLI steps in this guide (S3 bucket and DynamoDB table for remote state) and to run Terraform against EC2, IAM, and SSM. If `terraform plan` fails with `UnauthorizedOperation` on `ec2:DescribeImages` or similar, the principal is missing service permissions.

**Practical bundle (managed policies + a small custom policy):** attach these to that IAM principal:

| Policy | Purpose |
|--------|---------|
| `AmazonEC2FullAccess` | VPC, subnets, security groups, key pair, instance, EBS, Elastic IP, AMI and AZ lookups |
| `IAMFullAccess` | Instance role, inline policies, instance profile, and `PassRole` for EC2 |
| `AmazonSSMFullAccess` | SSM parameters created by Terraform (`SecureString` placeholders) |

**Remote Terraform state:** the backend in `infra/terraform/main.tf` uses S3 and DynamoDB. Add a **custom inline or customer-managed policy** that allows the state bucket and objects, for example `arn:aws:s3:::nanobot-tfstate-<ACCOUNT_ID>` and `arn:aws:s3:::nanobot-tfstate-<ACCOUNT_ID>/*`, plus `dynamodb:GetItem`, `PutItem`, `DeleteItem`, `DescribeTable` (and `ConditionCheckItem` if your org requires it) on `arn:aws:dynamodb:<region>:<ACCOUNT_ID>:table/nanobot-tfstate-lock`. Replace `<ACCOUNT_ID>` and `<region>` with your account and the region where you created those resources.

**Simpler alternative for a personal account:** `AdministratorAccess` on a dedicated IAM user avoids assembling the above, at the cost of a very broad grant.

An administrator in your AWS account must attach these policies; this guide does not create them for you.

### 2. Terraform

Install a compatible version with [tfenv](https://github.com/tfutils/tfenv):

```bash
git clone https://github.com/tfutils/tfenv.git ~/.tfenv
echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
tfenv install 1.8.5 && tfenv use 1.8.5
```

Verify:

```bash
terraform version   # must be >= 1.6.0
```

### 3. SSH key pair

If you don't already have one:

```bash
ssh-keygen -t ed25519 -C "nanobot-deploy" -f ~/.ssh/id_ed25519
```

### Optional — other workstation setups

The steps above target **Ubuntu x86_64**. If your environment differs, adapt as follows.

| Situation | Notes |
|-----------|--------|
| **macOS** | Install AWS CLI and Terraform with Homebrew: `brew install awscli terraform`. Use Terraform ≥ 1.6.0 (match `terraform version` to this guide’s requirement). |
| **Ubuntu on ARM64 (aarch64)** | Use the ARM AWS CLI bundle instead of `linux-x86_64`: `curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip`, then the same `unzip` / `aws/install` steps. tfenv works on ARM. |
| **Terraform without tfenv** | On Ubuntu you can use HashiCorp’s [APT repository](https://developer.hashicorp.com/terraform/install) to install `terraform`, or download a release binary from GitHub. Ensure `terraform version` is ≥ 1.6.0. |
| **Windows** | Use [WSL2 with Ubuntu](https://learn.microsoft.com/windows/wsl/install) and follow this manual inside that environment, or install AWS CLI and Terraform natively and run the same shell commands in a POSIX shell (Git Bash may work for some steps; WSL is more reliable). |

---

## Step 1 — Create the Terraform S3 backend (one time only)

Terraform state is stored remotely in S3 with DynamoDB locking. Create these resources once:

```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# State bucket
aws s3 mb s3://nanobot-tfstate-${ACCOUNT_ID} --region $AWS_REGION

# Enable versioning (allows state recovery)
aws s3api put-bucket-versioning \
  --bucket nanobot-tfstate-${ACCOUNT_ID} \
  --versioning-configuration Status=Enabled

# Lock table
aws dynamodb create-table \
  --table-name nanobot-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region $AWS_REGION
```

Now enable the backend in `infra/terraform/main.tf` (this is the **only** file you change for the backend; the snippet below matches what you uncomment there):

1. Open `infra/terraform/main.tf` and locate the `terraform { ... }` block at the top of the file.
2. Uncomment the `backend "s3" { ... }` block (remove the `#` at the start of each line inside that block, and remove the `#` on the lines that contain `backend "s3"` and the closing `}`). Leave the surrounding `terraform {` / `required_*` lines as they are.
3. Replace `<YOUR_ACCOUNT_ID>` in `bucket` with the same 12-digit account ID you used above (`echo $ACCOUNT_ID` after the Step 1 commands, or copy from `aws sts get-caller-identity`). The bucket name must be exactly `nanobot-tfstate-<that-id>`, matching the bucket you created.
4. Set `region` to the **same** AWS region where that S3 bucket exists (the `$AWS_REGION` you used in Step 1, e.g. `us-east-1`). The backend `region` is where the state file lives; it does not have to match `aws_region` in `terraform.tfvars`, but using the same region avoids confusion.

```hcl
  backend "s3" {
    bucket         = "nanobot-tfstate-<YOUR_ACCOUNT_ID>"
    key            = "nanobot/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "nanobot-tfstate-lock"
    encrypt        = true
  }
```

Indentation should match the existing `terraform` block (two spaces before `backend`).

**If you have never run `terraform init` in `infra/terraform`**, there is no local state yet — **skip** the next subsection and go to Step 2; you will run plain `terraform init` in Step 3.

If you **previously** ran `terraform init` in this directory **without** the S3 backend (local `terraform.tfstate` on disk), the first init after uncommenting must migrate state:

```bash
cd infra/terraform
terraform init -migrate-state
```

Answer `yes` when Terraform asks to copy existing state to S3. If this is a **fresh** clone and you have never run `terraform init` here, use plain `terraform init` in Step 3.

---

## Step 2 — Configure Terraform variables

Create `infra/terraform/terraform.tfvars`. **This file is git-ignored — never commit it.**

```bash
cd infra/terraform

cat > terraform.tfvars << EOF
# Required
ssh_public_key = "$(cat ~/.ssh/id_ed25519.pub)"
repo_url       = "https://github.com/YOUR_ORG/nanobot-core.git"

# Optional — change region or instance type
# aws_region     = "us-east-1"
# instance_type  = "t2.micro"   # free-tier default

# Optional — restrict SSH to your IP only (recommended)
# allowed_ssh_cidr = "$(curl -s https://checkip.amazonaws.com)/32"

# Optional — enable HTTPS with a custom domain
# domain_name    = "bot.example.com"
# certbot_email  = "you@example.com"
EOF
```

---

## Step 3 — Deploy infrastructure

```bash
cd infra/terraform

terraform init
terraform plan     # review what will be created
terraform apply    # type "yes" when prompted
```

This creates (~3 minutes):
- VPC, subnet, internet gateway, route table
- Security group (ports 22, 80, 443, 18790)
- IAM role + instance profile (SSM access)
- EC2 t2.micro instance (Ubuntu 22.04)
- 10 GB EBS data volume (attached to the instance)
- Elastic IP
- SSM Parameter Store parameters (all set to `REPLACE_ME`)

**Save the outputs:**

```
Outputs:

public_ip       = "1.2.3.4"
ssh_command     = "ssh ubuntu@1.2.3.4"
gateway_url     = "http://1.2.3.4:18790"
health_check_url = "http://1.2.3.4:18790/health"
ssm_prefix      = "/nanobot"
```

---

## Step 4 — Populate secrets in SSM

After `terraform apply`, all SSM parameters contain `REPLACE_ME`. Fill in the ones you need. **You only need to set the providers you actually use.**

```bash
export AWS_REGION=us-east-1

# ── LLM providers (set the ones you use) ─────────────────────────────────────

aws ssm put-parameter --name /nanobot/anthropic_api_key \
  --value "sk-ant-api03-..." \
  --type SecureString --overwrite --region $AWS_REGION

aws ssm put-parameter --name /nanobot/openai_api_key \
  --value "sk-proj-..." \
  --type SecureString --overwrite --region $AWS_REGION

aws ssm put-parameter --name /nanobot/openrouter_api_key \
  --value "sk-or-v1-..." \
  --type SecureString --overwrite --region $AWS_REGION

aws ssm put-parameter --name /nanobot/deepseek_api_key \
  --value "sk-..." \
  --type SecureString --overwrite --region $AWS_REGION

aws ssm put-parameter --name /nanobot/gemini_api_key \
  --value "AIza..." \
  --type SecureString --overwrite --region $AWS_REGION

# ── HTTP gateway protection ────────────────────────────────────────────────────
# Generate a random key — use this in Authorization: Bearer <key> when calling /v1/chat

aws ssm put-parameter --name /nanobot/gateway_http_api_key \
  --value "$(openssl rand -hex 32)" \
  --type SecureString --overwrite --region $AWS_REGION

# ── Web search (optional) ─────────────────────────────────────────────────────

aws ssm put-parameter --name /nanobot/brave_search_api_key \
  --value "BSA..." \
  --type SecureString --overwrite --region $AWS_REGION
```

---

## Step 5 — Wait for bootstrap to complete

The instance runs `user_data.sh` on first boot (~5–8 minutes). Watch it:

```bash
# SSH in
ssh ubuntu@$(terraform output -raw public_ip)

# Follow the bootstrap log
sudo tail -f /var/log/nanobot-init.log
```

The last lines should read:

```
=== nanobot EC2 bootstrap complete at <timestamp> ===
```

If it stalls, check for errors in the log.

---

## Step 6 — Reload secrets and start the service

**Prerequisite:** [Step 5](#step-5--wait-for-bootstrap-to-complete) must have finished successfully (`=== nanobot EC2 bootstrap complete ===` in `/var/log/nanobot-init.log`). That run installs `/etc/systemd/system/nanobot.service`. If you try the commands below before bootstrap completes, or if bootstrap failed, you will see `Unit nanobot.service not found` — fix bootstrap first (see troubleshooting below).

The bootstrap fetches secrets at startup, but the SSM values were `REPLACE_ME` at that point (you filled them in Step 4 after the instance booted). Refresh them now:

```bash
ssh ubuntu@$(terraform output -raw public_ip)

# Optional: confirm the unit exists (skip if you already know bootstrap succeeded)
test -f /etc/systemd/system/nanobot.service && echo "unit OK" || echo "MISSING — bootstrap did not install the unit; see Step 5 and troubleshooting below"

sudo /usr/local/bin/nanobot-fetch-secrets
sudo systemctl restart nanobot
sudo systemctl status nanobot    # should show: active (running)
```

If the unit file is missing but `/opt/nanobot` is a full git checkout (bootstrap partially succeeded), install it and reload:

```bash
sudo bash /opt/nanobot/infra/scripts/install_nanobot_systemd_unit.sh
sudo systemctl enable nanobot.service
sudo systemctl start nanobot
```

Check the gateway is up:

```bash
curl -s http://localhost:18790/health
# {"status":"ok"}
```

From your local machine:

```bash
PUBLIC_IP=$(terraform output -raw public_ip)
curl -s http://$PUBLIC_IP:18790/health
```

**Troubleshooting — service fails to start**

If `systemctl status nanobot` shows `ExecStartPre` exiting with status 1, check the journal for details:

```bash
sudo journalctl -u nanobot.service --no-pager -n 50
```

Common causes:

| Symptom | Cause | Fix |
|---|---|---|
| `Failed to restart nanobot.service: Unit nanobot.service not found` | Bootstrap not finished, bootstrap failed before the systemd step, or `/opt/nanobot` missing | Finish [Step 5](#step-5--wait-for-bootstrap-to-complete); read `/var/log/nanobot-init.log` for errors. If the repo exists under `/opt/nanobot`, run `sudo bash /opt/nanobot/infra/scripts/install_nanobot_systemd_unit.sh` then `sudo systemctl enable --now nanobot` |
| `Permission denied` on `/etc/nanobot/secrets.env` | `ExecStartPre` ran as `ubuntu` instead of root | Ensure the service uses `ExecStartPre=+/usr/local/bin/nanobot-fetch-secrets` (note the `+` prefix) |
| `Start request repeated too quickly` | systemd hit its restart burst limit after repeated failures | Fix the underlying error, then `sudo systemctl reset-failed nanobot` before restarting |
| nginx: `invalid number of arguments in "server_name"` | `domain_name` was left empty in Terraform | The bootstrap should default to `server_name _;` — re-run `user_data.sh` or manually fix `/etc/nginx/sites-available/nanobot` |

---

## Step 7 — Configure channels (optional)

SSH into the instance and run the interactive onboarding wizard to configure channels (Telegram, Slack, Discord, etc.):

```bash
ssh ubuntu@$(terraform output -raw public_ip)

cd /opt/nanobot
python -m nanobot onboard

sudo systemctl restart nanobot
```

---

## Step 8 — Verify end-to-end

Send a test message from your local machine:

```bash
PUBLIC_IP=$(terraform output -raw public_ip)

# Read the gateway API key you set in Step 4
API_KEY=$(aws ssm get-parameter \
  --name /nanobot/gateway_http_api_key \
  --with-decryption \
  --query Parameter.Value \
  --output text \
  --region us-east-1)

curl -s http://$PUBLIC_IP:18790/v1/chat \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"message": "Hello, are you there?"}'
```

Expected response:

```json
{"response": "Yes, I'm here! How can I help you?"}
```

---

## Ongoing operations

### Deploy a code update

After pushing commits to your repo:

```bash
bash infra/scripts/deploy.sh ubuntu@$(terraform output -raw public_ip)
```

The script pulls the repo, syncs dependencies, **reinstalls `systemd/nanobot.service` from the checkout** (so the live unit stays aligned with git, including `ExecStartPre=+`), refreshes secrets, and restarts the service.

### Rotate an API key

```bash
aws ssm put-parameter --name /nanobot/anthropic_api_key \
  --value "sk-ant-NEW-..." --type SecureString --overwrite --region us-east-1

ssh ubuntu@$(terraform output -raw public_ip) \
  "sudo /usr/local/bin/nanobot-fetch-secrets && sudo systemctl restart nanobot"
```

### View live logs

```bash
ssh ubuntu@$(terraform output -raw public_ip) "journalctl -u nanobot -f"
```

### SSH via SSM Session Manager (no open port 22 needed)

```bash
INSTANCE_ID=$(terraform output -raw instance_id)
aws ssm start-session --target $INSTANCE_ID --region us-east-1
```

---

## Switch to t4g.micro after free tier

Once 12 months pass, t4g.micro (ARM, 1 GB) costs ~$6/month instead of ~$8.50:

1. Edit `infra/terraform/terraform.tfvars`:

```hcl
instance_type    = "t4g.micro"
ami_architecture = "arm64"
```

2. Apply:

```bash
cd infra/terraform
terraform apply
```

Terraform replaces the EC2 instance. The EBS data volume (`~/.nanobot`) is **preserved** — sessions, workspace, and cron state are not lost.

---

## Rebuild from scratch (`terraform destroy` + `terraform apply`)

Use this when you already completed this manual once and want a **full teardown and fresh deploy** of the Terraform-managed stack (new EC2, new first-boot bootstrap, same `terraform.tfvars` pattern).

1. From your workstation:

   ```bash
   cd infra/terraform
   terraform destroy   # confirm with "yes"
   terraform apply     # confirm with "yes"
   ```

2. **What changes:** Terraform destroys and recreates everything it manages (VPC, instance, Elastic IP, SSM parameters Terraform owns, etc.). The **S3 + DynamoDB backend** from Step 1 is **not** part of this project’s destroy unless you delete those resources yourself — state stays in the bucket for the next `apply`.

3. **After apply:** Note the new outputs (`public_ip`, `ssh_command`, etc.). **SSM parameters** are recreated by Terraform with placeholder values; **run Step 4 again** to put real secrets, then **Step 5** (wait for bootstrap) and **Step 6** (fetch secrets + restart service) as on first deploy.

4. **Optional:** If you only need a new EC2 and bootstrap without destroying the whole VPC, prefer `terraform apply -replace=aws_instance.nanobot` instead of a full destroy — less churn, same fresh `user_data` on a replacement instance.

---

## Tear down

To destroy all AWS resources and stop billing:

```bash
cd infra/terraform
terraform destroy   # type "yes" when prompted
```

Note: the S3 bucket and DynamoDB table created in Step 1 are **not** managed by Terraform and must be deleted manually if desired:

```bash
aws s3 rb s3://nanobot-tfstate-${ACCOUNT_ID} --force
aws dynamodb delete-table --table-name nanobot-tfstate-lock --region $AWS_REGION
```

# Usage
## Get API secret for HTTP request
```
export AWS_REGION=us-east-1   # same region as the instance / SSM

API_KEY=$(aws ssm get-parameter \
  --name /nanobot/gateway_http_api_key \
  --with-decryption \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")

echo "$API_KEY"   # optional; avoid logging this in shared terminals
```

