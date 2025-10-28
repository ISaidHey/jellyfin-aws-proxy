variable "aws_region" {
  description = "The aws region (us-east-1, us-east-2, etc.) this is being hosted in."
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

variable "zone_id" {
  description = "The Route53 ZoneID."
}
