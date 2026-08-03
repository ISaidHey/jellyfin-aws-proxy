# One-time import mapping for the already-running pigs-in-space infrastructure.
# wireguard_asymmetric_key / local_file resources are local-only (not AWS
# resources) - nothing to import for those, they'll generate fresh on first
# apply unless the real keys are recovered from the instance separately.

import {
  to = aws_vpc.main
  id = "vpc-040183d26bd9271a8"
}

import {
  to = aws_subnet.public
  id = "subnet-01c2a43ca5210de54"
}

import {
  to = aws_internet_gateway.igw
  id = "igw-0942192e8e54f1ced"
}

import {
  to = aws_route_table.public
  id = "rtb-029e73d46c843652e"
}

import {
  to = aws_route_table_association.public
  id = "subnet-01c2a43ca5210de54/rtb-029e73d46c843652e"
}

import {
  to = aws_security_group.ec2_sg
  id = "sg-099a50540cf8feae3"
}

import {
  to = aws_iam_role.ec2_role
  id = "pigs-in-space-ec2-role"
}

import {
  to = aws_iam_policy.route53_policy
  id = "arn:aws:iam::175662081910:policy/pigs-in-space-route53-policy"
}

import {
  to = aws_iam_policy.cloudwatch_policy
  id = "arn:aws:iam::175662081910:policy/pigs-in-space-cloudwatch-policy"
}

import {
  to = aws_iam_role_policy_attachment.attach_route53
  id = "pigs-in-space-ec2-role/arn:aws:iam::175662081910:policy/pigs-in-space-route53-policy"
}

import {
  to = aws_iam_role_policy_attachment.attach_cloudwatch
  id = "pigs-in-space-ec2-role/arn:aws:iam::175662081910:policy/pigs-in-space-cloudwatch-policy"
}

import {
  to = aws_iam_role_policy_attachment.attach_ssm
  id = "pigs-in-space-ec2-role/arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

import {
  to = aws_cloudwatch_log_group.cloudwatch_group
  id = "/pigs-in-space/ec2"
}

import {
  to = aws_iam_instance_profile.ec2_profile
  id = "pigs-in-space-ec2-profile"
}

import {
  to = aws_instance.caddy_ec2
  id = "i-05d6b332db311081b"
}

import {
  to = aws_eip.caddy_eip
  id = "eipalloc-01fcc272ecc531481"
}

import {
  to = aws_eip_association.caddy_eip_assoc
  id = "eipassoc-014b9057a3907877a"
}
