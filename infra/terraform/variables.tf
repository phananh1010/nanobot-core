variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name; used in resource names and tags."
  type        = string
  default     = "nanobot"
}

variable "environment" {
  description = "Environment label (e.g. production, staging)."
  type        = string
  default     = "production"
}

# ── Instance ──────────────────────────────────────────────────────────────────

variable "instance_type" {
  description = <<-EOT
    EC2 instance type.
    Free-tier eligible (first 12 months): t2.micro (1 vCPU, 1 GB).
    Post free-tier cheapest with 1 GB RAM: t4g.micro (ARM, ~$6/mo on-demand).
  EOT
  type        = string
  default     = "t2.micro"
}

variable "ami_architecture" {
  description = "CPU architecture for the Ubuntu AMI: 'amd64' (x86_64) or 'arm64'. Use 'amd64' for t2/t3; 'arm64' for t4g."
  type        = string
  default     = "amd64"

  validation {
    condition     = contains(["amd64", "arm64"], var.ami_architecture)
    error_message = "ami_architecture must be 'amd64' or 'arm64'."
  }
}

variable "data_volume_size_gb" {
  description = "Size (GB) of the separate EBS data volume for ~/.nanobot (sessions, workspace, cron). Free tier: 30 GB total EBS."
  type        = number
  default     = 10
}

variable "ssh_public_key" {
  description = "Contents of your SSH public key (e.g. contents of ~/.ssh/id_ed25519.pub). Used to create the EC2 key pair."
  type        = string
  sensitive   = true
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH into the instance. Restrict to your IP for security (e.g. '203.0.113.5/32'). Use '0.0.0.0/0' to allow any."
  type        = string
  default     = "0.0.0.0/0"
}

variable "gateway_port" {
  description = "Port that nanobot gateway listens on. Keep in sync with gateway.port in config."
  type        = number
  default     = 18790
}

# ── Repository ────────────────────────────────────────────────────────────────

variable "repo_url" {
  description = "Git repository URL to clone onto the EC2 instance. Use HTTPS for public repos."
  type        = string
  default     = "https://github.com/your-org/nanobot-core.git"
}

variable "repo_branch" {
  description = "Git branch to check out."
  type        = string
  default     = "main"
}

# ── Domain / TLS (optional) ───────────────────────────────────────────────────

variable "domain_name" {
  description = "Optional domain name for nginx + Let's Encrypt TLS (e.g. 'bot.example.com'). Leave empty to skip TLS setup."
  type        = string
  default     = ""
}

variable "certbot_email" {
  description = "Email address for Let's Encrypt certificate registration. Required when domain_name is set."
  type        = string
  default     = ""
}

# ── Route 53 (existing hosted zone) ────────────────────────────────────────────

variable "route53_zone_name" {
  description = <<-EOT
    Existing Route 53 public hosted zone name (e.g. mintanalytic.com), without a trailing dot.
    Set to "" to skip creating DNS records in Terraform (you manage DNS elsewhere).
  EOT
  type        = string
  default     = "mintanalytic.com"
}

variable "route53_a_records" {
  description = <<-EOT
    Fully qualified names for A records pointing at the deployment Elastic IP.
    Include the same hostname as domain_name if you use nginx/Let's Encrypt on that name
    (e.g. ["mintanalytic.com"] or ["bot.mintanalytic.com", "www.mintanalytic.com"]).
  EOT
  type        = list(string)
  default     = ["mintanalytic.com"]
}
