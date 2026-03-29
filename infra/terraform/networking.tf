locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "nanobot" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "nanobot" {
  vpc_id = aws_vpc.nanobot.id

  tags = { Name = "${local.name_prefix}-igw" }
}

# ── Public subnet ─────────────────────────────────────────────────────────────

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.nanobot.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = { Name = "${local.name_prefix}-public-subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.nanobot.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.nanobot.id
  }

  tags = { Name = "${local.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ── Security group ────────────────────────────────────────────────────────────

resource "aws_security_group" "nanobot" {
  name        = "${local.name_prefix}-sg"
  description = "nanobot gateway: SSH, HTTP, HTTPS, and gateway port"
  vpc_id      = aws_vpc.nanobot.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "HTTP (nginx redirects to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "nanobot gateway (direct, useful without a domain)"
    from_port   = var.gateway_port
    to_port     = var.gateway_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-sg" }
}

# ── Elastic IP ────────────────────────────────────────────────────────────────

resource "aws_eip" "nanobot" {
  domain   = "vpc"
  instance = aws_instance.nanobot.id

  tags = { Name = "${local.name_prefix}-eip" }

  depends_on = [aws_internet_gateway.nanobot]
}
