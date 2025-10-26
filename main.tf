terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.5.0"
}

provider "aws" {
  region = "us-east-2" # change as needed
}

locals {
  tags_common = {
    Project     = "jellyfin"
    Environment = "production"
    ManagedBy   = "OpenTofu"
  }
}


# -------------------
# VPC
# -------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(
    local.tags_common,
    {
      Name = "jellyfin-vpc"
    }
  )
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-2a"

  tags = merge(
    local.tags_common,
    {
      Name = "jellyfin-public-subnet"
    }
  )
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = merge(
    local.tags_common,
    {
      Name = "jellyfin-igw"
    }
  )
}

# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(
    local.tags_common,
    {
      Name = "jellyfin-public-rt"
    }
  )
}

# Associate Route Table
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# -------------------
# Security Group
# -------------------
resource "aws_security_group" "ec2_sg" {
  name        = "jellyfin-ec2-sg"
  description = "Allow HTTPS inbound and WireGuard outbound"
  vpc_id      = aws_vpc.main.id

  # Inbound: HTTPS
  ingress {
    description      = "HTTPS"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  # Outbound: All traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.tags_common,
    {
      Name = "jellyfin-ec2-sg"
    }
  )
}

# -------------------
# IAM Role for Route 53 updates
# -------------------
resource "aws_iam_role" "ec2_route53_role" {
  name = "jellyfin-ec2-route53-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "route53_policy" {
  name        = "jellyfin-route53-policy"
  description = "Allow EC2 to update Route 53 records"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "route53:ListHostedZones",
        "route53:GetChange",
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets",
      ]
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "attach_route53" {
  role       = aws_iam_role.ec2_route53_role.name
  policy_arn = aws_iam_policy.route53_policy.arn
}

resource "aws_iam_role_policy_attachment" "attach_ssm" {
  role       = aws_iam_role.ec2_route53_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# -------------------
# EC2 Instance
# -------------------

resource "aws_eip" "caddy_eip" {
  instance = aws_instance.caddy_ec2.id

  tags = merge(
    local.tags_common,
    {
      Name = "jellyfin-eip"
    }
  )
}


# IAM Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "jellyfin-ec2-profile"
  role = aws_iam_role.ec2_route53_role.name
}

resource "aws_instance" "caddy_ec2" {
  ami                         = "ami-0cfde0ea8edd312d4" # Ubuntu 24.04 LTS in us-east-2
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  key_name                    = aws_key_pair.ec2_key.key_name
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name

  tags = merge(
    local.tags_common,
    {
      Name = "jellyfin-caddy"
      SSM  = "enabled"
    }
  )

  user_data = <<-EOF
              #!/bin/bash
              set -eux
              apt update -y
              apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg

              # Install Caddy (modern and secure)
              curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-archive-keyring.gpg
              curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy.list
              apt update
              apt install -y caddy

              # Install WireGuard (optional)
              apt install -y wireguard

              systemctl enable caddy
              systemctl start caddy
              EOF
}

# -------------------
# Route 53 Record
# -------------------
resource "aws_route53_record" "jellyfin_dns" {
  zone_id = "YOUR_HOSTED_ZONE_ID" # replace with your Route 53 Hosted Zone ID
  name    = "media"               # subdomain: media.example.com
  type    = "A"
  ttl     = 300
  records = [aws_eip.caddy_eip.public_ip]
}
