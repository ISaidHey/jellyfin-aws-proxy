terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    wireguard = {
      source  = "OJFord/wireguard"
      version = "0.4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.5.3"
    }
  }
  required_version = ">= 1.5.0"
}

provider "aws" {
  region = var.aws_region # change as needed
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "production"
      ManagedBy   = "OpenTofu"
    }
  }
}

data "aws_route53_zone" "r53_zone" {
  zone_id = var.zone_id
}

# -------------------
# VPC
# -------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-2a"

  tags = {
    Name = "${var.project_name}-public-subnet"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
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
    Name = "${var.project_name}-public-rt"
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
  name        = "${var.project_name}-ec2-sg"
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
  ingress {
    description = "WireGuard inbound"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
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

  egress {
    description = "Allow UDP outbound for DNS"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow TCP outbound for DNS"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-ec2-sg"
  }
}

# -------------------
# IAM Role for Route 53 updates
# -------------------
resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Condition = {
        StringEquals = {
          "aws:ResourceTag/Project" = var.project_name
        }
      }
    }]
  })
}

resource "aws_iam_policy" "cloudwatch_policy" {
  name        = "${var.project_name}-cloudwatch-policy"
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
        Resource = "${aws_cloudwatch_log_group.cloudwatch_group.arn}:*"
      }
    ]
  })
  depends_on = [aws_cloudwatch_log_group.cloudwatch_group]
}

resource "aws_cloudwatch_log_group" "cloudwatch_group" {
  name              = "/${var.project_name}/ec2"
  retention_in_days = 7
}

resource "aws_iam_policy" "route53_policy" {
  name        = "${var.project_name}-route53-policy"
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
        Resource = "arn:aws:route53:::hostedzone/${data.aws_route53_zone.r53_zone.zone_id}"
      },
      {
        Sid    = "ListHostedZonesAndChanges"
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:GetChange",
          "route53:ListHostedZonesByName",
          "route53:GetHostedZone"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_route53" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.route53_policy.arn
}

resource "aws_iam_role_policy_attachment" "attach_cloudwatch" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.cloudwatch_policy.arn
}

resource "aws_iam_role_policy_attachment" "attach_ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ------------------
# WireGuard
# ------------------
resource "wireguard_asymmetric_key" "peer1" {
}

resource "wireguard_asymmetric_key" "peer2" {
}


data "wireguard_config_document" "peer1" {
  addresses   = ["${var.wg_ec2_ip}/24"]
  listen_port = 51820
  private_key = wireguard_asymmetric_key.peer1.private_key

  peer {
    public_key = wireguard_asymmetric_key.peer2.public_key
    allowed_ips = [
      var.wg_media_sever_ip,
    ]
  }
}

data "wireguard_config_document" "peer2" {
  private_key = wireguard_asymmetric_key.peer2.private_key
  addresses   = ["${var.wg_media_sever_ip}/24"]

  peer {
    public_key = wireguard_asymmetric_key.peer1.public_key
    endpoint   = "${aws_eip.caddy_eip.public_ip}:51820"
    allowed_ips = [
      "${var.wg_ec2_ip}/32",
    ]
    persistent_keepalive = 25
  }
}

resource "local_file" "client-dot-conf" {
  filename = "wg-client.conf"
  content  = data.wireguard_config_document.peer2.conf
}

# -------------------
# EC2 Instance
# -------------------
# IAM Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

resource "aws_instance" "caddy_ec2" {
  ami                         = var.ubuntu_ami_id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  monitoring                  = true

  user_data = templatefile("${path.module}/user_data.sh", {
    ec2_public_ip = aws_eip.caddy_eip.public_ip
    cw_agent_json = templatefile("${path.module}/amazon-cloudwatch-agent.tftpl", {
      ec2_log_group_name = aws_cloudwatch_log_group.cloudwatch_group.name
    })
    caddyfile = templatefile("${path.module}/Caddyfile.tftpl", {
      domain            = var.domain
      media_server_port = var.media_server_port
      media_server_ip   = var.wg_media_sever_ip
      subdomain         = var.subdomain
    })
    region  = var.aws_region
    wg0conf = data.wireguard_config_document.peer1.conf
  })

  depends_on = [
    aws_internet_gateway.igw,
    aws_eip.caddy_eip
  ]
  tags = {
    Name = "${var.project_name}-caddy"
    SSM  = "enabled"
  }
}

resource "aws_eip" "caddy_eip" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.igw]

  tags = {
    Name = "${var.project_name}-eip"
  }
}

resource "aws_eip_association" "caddy_eip_assoc" {
  instance_id   = aws_instance.caddy_ec2.id
  allocation_id = aws_eip.caddy_eip.id

  depends_on = [aws_instance.caddy_ec2]
}

# -------------------
# Route 53 Record
# -------------------
resource "aws_route53_record" "subdomain_dns" {
  zone_id = data.aws_route53_zone.r53_zone.zone_id
  name    = var.subdomain
  type    = "A"
  ttl     = 300
  records = [aws_eip.caddy_eip.public_ip]
}

output "ec2_public_ip" {
  value = aws_eip.caddy_eip.public_ip
}
