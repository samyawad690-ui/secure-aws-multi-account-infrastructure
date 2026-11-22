# Network inputs (used by network.tf). Paid parts default to off.

variable "enable_nat_gateway" {
  description = "Create one NAT gateway and its Elastic IP for a test session. Billed per hour while they exist (a partial hour counts as a full hour), plus per GB through the NAT."
  type        = bool
  default     = false
}

variable "enable_interface_endpoints" {
  description = "Create the SSM interface endpoints (billed per hour in each AZ, plus per GB). Not used: Session Manager goes through the NAT when enable_nat_gateway = true."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Send VPC Flow Logs to S3 (billed per GB). Needs flow_logs_bucket_arn."
  type        = bool
  default     = false
}

variable "flow_logs_bucket_arn" {
  description = "ARN of the team logging bucket for VPC Flow Logs."
  type        = string
  default     = null
}

variable "allowed_ingress_cidrs" {
  description = "Approved test public IPs allowed to reach the ALB on port 80, as IPv4 CIDRs of /24 or smaller (for one IP: x.x.x.x/32)."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for c in var.allowed_ingress_cidrs :
      can(cidrnetmask(c)) && try(tonumber(split("/", c)[1]) >= 24 && cidrsubnet(c, 0, 0) == c, false)
    ])
    error_message = "allowed_ingress_cidrs takes approved test IPs only: IPv4 network CIDRs of /24 or smaller (for one IP use x.x.x.x/32)."
  }
}
