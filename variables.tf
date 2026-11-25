# Network inputs (used by network.tf). Paid parts default to off.

variable "enable_nat_gateway" {
  description = "Create one NAT gateway and its Elastic IP for a test session. Billed per hour while they exist (a partial hour counts as a full hour), plus per GB through the NAT. Session Manager needs this or enable_interface_endpoints: with both off, private instances cannot use it."
  type        = bool
  default     = false
}

variable "enable_interface_endpoints" {
  description = "Create the SSM interface endpoints (ssm, ssmmessages, ec2messages), billed per hour in each AZ plus per GB. An alternative to enable_nat_gateway for Session Manager, off unless the team confirms; the two cannot be on together."
  type        = bool
  default     = false

  validation {
    condition     = !(var.enable_interface_endpoints && var.enable_nat_gateway)
    error_message = "Turn on enable_nat_gateway or enable_interface_endpoints, not both. Either one gives Session Manager its path."
  }
}

variable "enable_flow_logs" {
  description = "Send VPC Flow Logs to S3 (billed per GB). Keep false until the bucket in flow_logs_bucket_arn exists with its bucket policy, agreed with Kareem and Haitham."
  type        = bool
  default     = false
}

variable "flow_logs_bucket_arn" {
  description = "ARN of the team logging bucket for VPC Flow Logs. Its bucket policy must already let delivery.logs.amazonaws.com do s3:PutObject and s3:GetBucketAcl (see network.tf)."
  type        = string
  default     = null
}

variable "allowed_ingress_cidrs" {
  description = "Approved test public IPs allowed to reach the ALB on port 80, as IPv4 CIDRs from /24 to /32 (for one IP: x.x.x.x/32)."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for c in var.allowed_ingress_cidrs :
      can(cidrnetmask(c)) && try(tonumber(split("/", c)[1]) >= 24 && cidrsubnet(c, 0, 0) == c, false)
    ])
    error_message = "allowed_ingress_cidrs takes approved test IPs only: IPv4 network CIDRs from /24 to /32 (for one IP use x.x.x.x/32)."
  }
}
