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

# -------------------
# VPC
# -------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "jellyfin-vpc"
  }
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-2a"

  tags = {
    Name = "jellyfin-public-subnet"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "jellyfin-igw"
  }
}

# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "jellyfin-public-rt"
  }
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

  tags = {
    Name = "jellyfin-ec2-sg"
  }
}

# -------------------
# Key Pair
# -------------------
resource "aws_key_pair" "ec2_key" {
  key_name   = "jellyfin-ec2-key"
  public_key = file("~/.ssh/id_rsa.pub") # path to your local public key
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
      Action   = ["route53:ListHostedZones", "route53:GetChange", "route53:ChangeResourceRecordSets"]
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "attach_route53" {
  role       = aws_iam_role.ec2_route53_role.name
  policy_arn = aws_iam_policy.route53_policy.arn
}

# -------------------
# EC2 Instance
# -------------------
resource "aws_instance" "caddy_ec2" {
  # ami                         = "ami-0c02fb55956c7d316" # Ubuntu 22.04 LTS in us-east-1, change for your region
  ami                         = "ami-0360c520857e3138f" # Ubuntu 22.04 LTS in us-east-1, change for your region
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  key_name                    = aws_key_pair.ec2_key.key_name
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name

  tags = {
    Name = "jellyfin-caddy"
  }

  user_data = <<-EOF
              #!/bin/bash
              apt update -y
              apt install -y curl wget
              # Install Caddy (simplified)
              curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | apt-key add -
              curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
              apt update
              apt install -y caddy
              EOF
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "jellyfin-ec2-profile"
  role = aws_iam_role.ec2_route53_role.name
}

# -------------------
# Route 53 Record
# -------------------
resource "aws_route53_record" "jellyfin_dns" {
  zone_id = "YOUR_HOSTED_ZONE_ID"   # replace with your Route 53 Hosted Zone ID
  name    = "media"                 # subdomain: media.example.com
  type    = "A"
  ttl     = 300
  records = [aws_instance.caddy_ec2.public_ip]
}
