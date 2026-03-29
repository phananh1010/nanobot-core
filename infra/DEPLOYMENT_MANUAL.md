# Deployment Manual — nanobot on AWS EC2

Step-by-step guide to deploy `nanobot gateway` on a single EC2 instance using Terraform. Estimated time: 20–30 minutes on first deploy.

---

## Prerequisites

Install these on your local machine before starting.

### 1. AWS CLI

```bash
# macOS
brew install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install
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

### 2. Terraform

```bash
# macOS
brew install terraform

# Linux (via tfenv)
git clone https://github.com/tfutils/tfenv.git ~/.tfenv
echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
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

Now enable the backend in `infra/terraform/main.tf`. Uncomment and fill in the `backend "s3"` block:

```hcl
backend "s3" {
  bucket         = "nanobot-tfstate-<YOUR_ACCOUNT_ID>"
  key            = "nanobot/terraform.tfstate"
  region         = "us-east-1"
  dynamodb_table = "nanobot-tfstate-lock"
  encrypt        = true
}
```

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

The bootstrap fetches secrets at startup, but the SSM values were `REPLACE_ME` at that point (you filled them in Step 4 after the instance booted). Refresh them now:

```bash
ssh ubuntu@$(terraform output -raw public_ip)

sudo /usr/local/bin/nanobot-fetch-secrets
sudo systemctl restart nanobot
sudo systemctl status nanobot    # should show: active (running)
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
