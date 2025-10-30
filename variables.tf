variable "aws_region" {
  description = "The aws region (us-east-1, us-east-2, etc.) this is being hosted in."
}

variable "domain" {
  description = "The top level domain name."
  default     = "example.com"
}

variable "media_server_port" {
  description = "The port the media server is listening to on home server. Used in Caddyfile."
  default     = 8096
  type        = number
}

variable "project_name" {
  description = "The name of the project, gets passed in to naming and tagging a lot of the resources."
}

variable "subdomain" {
  description = "The subdomain that the project will be accessed from."
}

variable "ubuntu_ami_id" {
  description = "The Ubuntu AMI ID to be used. Should be latest Ubuntu in the designated region."
}

variable "wg_ec2_ip" {
  description = "The WireGuard Interface Address on the EC2 instance."
  default     = "10.10.0.1"
}

variable "wg_media_sever_ip" {
  description = "The WireGuard Interface Address on the media server."
  default     = "10.10.0.2"
}

variable "zone_id" {
  description = "The Route53 ZoneID."
}
