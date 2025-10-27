terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
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

  # HTTPS
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # WireGuard
  egress {
    description = "WireGuard outbound"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # DNS management
  egress {
    description = "Allow HTTPS to DNS provider APIs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow HTTP outbound"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
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
data aws_caller_identity "who_am_i" {}
data aws_region "region" {}

resource "aws_iam_policy" "cloudwatch_policy" {
  name        = "jellyfin-cloudwatch-policy"
  description = "Allow EC2 to write to cloudwatch"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.region.id}:${data.aws_caller_identity.who_am_i.account_id}:log-group:/ec2/jellyfin:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "cloudwatch_group" {
  name = "/ec2/jellyfin"
  retention_in_days = 7
}

resource "aws_iam_policy" "route53_policy" {
  name        = "jellyfin-route53-policy"
  description = "Allow EC2 to update Route 53 records"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ChangeSpecificZone"
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets"
        ]
        Resource = "arn:aws:route53:::hostedzone/${var.zone_id}"
      },
      {
        Sid    = "ListHostedZonesAndChanges"
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:GetChange"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_route53" {
  role       = aws_iam_role.ec2_route53_role.name
  policy_arn = aws_iam_policy.route53_policy.arn
}

resource "aws_iam_role_policy_attachment" "attach_cloudwatch" {
  role       = aws_iam_role.ec2_route53_role.name
  policy_arn = aws_iam_policy.cloudwatch_policy.arn
}

resource "aws_iam_role_policy_attachment" "attach_ssm" {
  role       = aws_iam_role.ec2_route53_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# -------------------
# EC2 Instance
# -------------------
# IAM Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "jellyfin-ec2-profile"
  role = aws_iam_role.ec2_route53_role.name
}

resource "aws_instance" "caddy_ec2" {
  ami                         = "ami-0cfde0ea8edd312d4" # Ubuntu 24.04 LTS in us-east-2
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  monitoring                  = true

  user_data = file("${path.module}/user_data.sh")

  depends_on = [aws_internet_gateway.igw]
  tags = merge(
    local.tags_common,
    {
      Name = "jellyfin-caddy"
      SSM  = "enabled"
    }
  )
}

resource "aws_eip" "caddy_eip" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.igw]

  tags = merge(
    local.tags_common,
    {
      Name = "jellyfin-eip"
    }
  )
}

resource "aws_eip_association" "caddy_eip_assoc" {
  instance_id   = aws_instance.caddy_ec2.id
  allocation_id = aws_eip.caddy_eip.id

  depends_on = [aws_instance.caddy_ec2]
}

# -------------------
# Route 53 Record
# -------------------
resource "aws_route53_record" "jellyfin_dns" {
  zone_id = var.zone_id
  name    = "media"
  type    = "A"
  ttl     = 300
  records = [aws_eip.caddy_eip.public_ip]
}


output "ec2_public_ip" {
  value = aws_eip.caddy_eip.public_ip
}
