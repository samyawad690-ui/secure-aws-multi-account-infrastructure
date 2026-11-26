# Compute layer (owner: Moaaz Ehab): internet-facing ALB, target group,
# launch template, and a small Auto Scaling Group in the private app subnets.
#
# This file only consumes the network layer in network.tf. It does not create or
# modify a VPC, subnet, route table, NAT gateway, VPC endpoint, or Security Group.
#
# Network resources reused (all defined in network.tf):
#   aws_vpc.main
#   aws_subnet.public_a / aws_subnet.public_b
#   aws_subnet.private_app_a / aws_subnet.private_app_b
#   aws_security_group.alb / aws_security_group.app
#   local.public_subnet_ids / local.app_subnet_ids / local.app_port / local.name_prefix

# --- Compute inputs -----------------------------------------------------------
# Kept in compute.tf (instead of the shared variables.tf) so this branch changes
# only its own file. Override with -var or a local tfvars file for demos.

variable "compute_instance_type" {
  description = "EC2 instance type for the app instances. t3.micro is the cost-conscious default."
  type        = string
  default     = "t3.micro"
}

variable "compute_desired_capacity" {
  description = "Desired number of app instances. Keep at 1 during development."
  type        = number
  default     = 1
}

variable "compute_min_size" {
  description = "Minimum number of app instances."
  type        = number
  default     = 1
}

variable "compute_max_size" {
  description = "Maximum number of app instances. 2 is enough to demonstrate scaling."
  type        = number
  default     = 2
}

variable "compute_instance_profile_name" {
  description = "Optional existing IAM instance profile name from the Security layer (Haitham). Null means no instance profile is attached. An instance profile alone does not enable SSM while NAT and interface endpoints are off."
  type        = string
  default     = null
}

# --- AMI ----------------------------------------------------------------------
# Amazon Linux 2023 (x86_64), the current standard AMI in the region.
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# --- Application Load Balancer ------------------------------------------------
# Public subnets, ALB security group from the Network layer. The Network layer
# already allows inbound HTTP 80 from allowed_ingress_cidrs and outbound 8080 to
# the app security group.

resource "aws_lb" "app" {
  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false

  security_groups = [aws_security_group.alb.id]
  subnets         = values(local.public_subnet_ids)

  drop_invalid_header_fields = true
  enable_deletion_protection = false

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

# --- Target group -------------------------------------------------------------
# HTTP on the application port agreed in network.tf (local.app_port = 8080).
# Health check: GET / on port 8080 must return HTTP 200. The User Data below
# starts a Python standard-library HTTP server on that port and serves
# index.html. Runtime verification (target registered and healthy) requires a
# deployment; terraform plan cannot prove it.

resource "aws_lb_target_group" "app" {
  name        = "${local.name_prefix}-app-tg"
  port        = local.app_port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  # Short drain time for the demo; production would keep the default 300s.
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${local.name_prefix}-app-tg"
  }
}

# --- HTTP listener (demo) -----------------------------------------------------
# Port 80 forwards straight to the target group. HTTPS/ACM is intentionally not
# created; the architecture document marks it as a later stage.

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = {
    Name = "${local.name_prefix}-http"
  }
}

# --- Launch template ----------------------------------------------------------
# No key pair and no public IP: administration is meant to go through SSM once
# the Security layer supplies an instance profile. The app security group already
# allows 8080 only from the ALB security group.
#
# SSM dependency: an instance profile alone is not enough. With
# enable_nat_gateway = false and enable_interface_endpoints = false (the
# defaults), the private app subnets have no path to the SSM service, so SSM and
# Session Manager remain unavailable until the team approves and enables one of
# those network options in network.tf. This file creates neither.

resource "aws_launch_template" "app" {
  name        = "${local.name_prefix}-app-lt"
  description = "App instances behind the ALB (no SSH, IMDSv2 required)"

  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = var.compute_instance_type

  vpc_security_group_ids = [aws_security_group.app.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = data.aws_ami.amazon_linux_2023.root_device_name

    ebs {
      volume_size           = 8
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # Attach Haitham's instance profile only when it is provided.
  dynamic "iam_instance_profile" {
    for_each = var.compute_instance_profile_name == null ? [] : [var.compute_instance_profile_name]

    content {
      name = iam_instance_profile.value
    }
  }

  user_data = base64encode(<<EOT
#!/bin/bash
set -euo pipefail

# No package installation: the app subnets have no internet path while the NAT
# gateway and SSM interface endpoints are off. Python 3 ships with Amazon Linux
# 2023, so the demo app uses only the standard library.

install -d -m 0755 /opt/app

cat > /opt/app/index.html <<'HTML'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <title>Secure AWS demo app</title>
  </head>
  <body>
    <h1>Secure AWS demo app</h1>
    <p>Served by an EC2 instance in a private application subnet.</p>
  </body>
</html>
HTML

cat > /etc/systemd/system/demo-app.service <<'UNIT'
[Unit]
Description=Demo web app for the ALB target group
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server ${local.app_port} --bind 0.0.0.0 --directory /opt/app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now demo-app.service
EOT
  )

  tags = {
    Name = "${local.name_prefix}-app-lt"
  }
}

# --- Auto Scaling Group -------------------------------------------------------
# Cost defaults: one t3.micro instance across both private app subnets,
# registered with the target group by the ASG itself. No NAT gateway, Elastic
# IP, interface endpoint, ACM/HTTPS listener, CloudWatch alarm, or scaling policy
# is created here. Raise compute_desired_capacity only for an approved scaling
# demo; nothing else needs to change.

resource "aws_autoscaling_group" "app" {
  name                = "${local.name_prefix}-app-asg"
  vpc_zone_identifier = values(local.app_subnet_ids)

  desired_capacity = var.compute_desired_capacity
  min_size         = var.compute_min_size
  max_size         = var.compute_max_size

  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120

  # Demo convenience: destroy does not hang if an instance is stuck unhealthy.
  force_delete = true

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-app"
    propagate_at_launch = true
  }

  lifecycle {
    precondition {
      condition     = var.compute_min_size <= var.compute_desired_capacity && var.compute_desired_capacity <= var.compute_max_size
      error_message = "Capacity must satisfy compute_min_size <= compute_desired_capacity <= compute_max_size."
    }
  }
}
