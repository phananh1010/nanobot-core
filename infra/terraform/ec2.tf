# ── AMI (Ubuntu 22.04 LTS) ────────────────────────────────────────────────────

locals {
  ami_arch_map = {
    amd64 = "amd64"
    arm64 = "arm64"
  }
  ami_name_pattern = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-${local.ami_arch_map[var.ami_architecture]}-server-*"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = [local.ami_name_pattern]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Key pair ──────────────────────────────────────────────────────────────────

resource "aws_key_pair" "nanobot" {
  key_name   = "${local.name_prefix}-key"
  public_key = var.ssh_public_key
}

# ── EC2 instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "nanobot" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.nanobot.id]
  key_name               = aws_key_pair.nanobot.key_name
  iam_instance_profile   = aws_iam_instance_profile.nanobot.name

  # Root volume (OS + app code). Stays at free-tier eligible 8 GB.
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
    encrypted             = true
  }

  user_data = templatefile("${path.module}/../../infra/scripts/user_data.sh", {
    repo_url      = var.repo_url
    repo_branch   = var.repo_branch
    ssm_prefix    = "/${var.project}"
    gateway_port  = var.gateway_port
    domain_name   = var.domain_name
    certbot_email = var.certbot_email
    project       = var.project
  })

  tags = { Name = "${local.name_prefix}-instance" }

  lifecycle {
    # EC2 only runs user_data on first boot; changing this template does not
    # re-bootstrap existing instances. We ignore user_data drift so a template
    # update does not force instance replacement on every apply. To bake a new
    # user_data into a fresh instance: terraform apply -replace=aws_instance.nanobot
    # For running VMs, pull and run infra/scripts/deploy.sh (it reinstalls the
    # systemd unit from the repo on every deploy).
    ignore_changes = [user_data]
  }
}

# ── Separate data volume for ~/.nanobot (sessions, workspace, cron) ───────────
# Stored on a dedicated EBS volume so it survives root-volume replacement.

resource "aws_ebs_volume" "data" {
  availability_zone = aws_instance.nanobot.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${local.name_prefix}-data" }
}

resource "aws_volume_attachment" "data" {
  device_name  = "/dev/xvdf"
  volume_id    = aws_ebs_volume.data.id
  instance_id  = aws_instance.nanobot.id
  force_detach = false
}
