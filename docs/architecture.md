# Secure AWS Cloud Infrastructure
## Architecture Design & Implementation Document

**Project:** Governance, Networking, Hybrid Connectivity & Application Hosting  
**Version:** 1.0  
**Status:** Approved baseline for team implementation  
**Cloud Provider:** Amazon Web Services (AWS)  
**IaC Tool:** Terraform  
**AWS Region:** `us-east-1`  
**Account Model:** Single AWS Account

---

# 1. Project Overview

The project combines two tracks:

1. **Secure AWS Landing Zone & Multi-Account Governance**
2. **Secure AWS Network Architecture & Hybrid Connectivity**

The objective is to build a secure, scalable, and cost-conscious AWS infrastructure using Terraform.

The infrastructure will provide:

- Secure account and identity management.
- Network isolation and segmentation.
- Web application hosting.
- Private database connectivity.
- Edge protection and traffic management.
- Centralized logging, monitoring, and threat detection.
- Hybrid networking demonstrations.

The infrastructure will be designed to support a real Web Application connected to a database, even if a simple demo application is used during testing.

## 1.1 Scope Decision

The implementation will use **one AWS account**, according to the current instructor direction.

The Multi-Account Governance concepts will be covered through architecture diagrams, documentation, and theoretical explanations where they cannot be implemented in a single standalone account.

---

# 2. High-Level Architecture

The main application will follow a Three-Tier Architecture with an additional Edge Security layer.

## 2.1 Application Request Flow

```text
                 Internet Users
                       |
                       v
               Amazon Route 53
                  (Optional)
                       |
                       v
              Amazon CloudFront
                       |
                  AWS WAF
                       |
             +---------+---------+
             |                   |
             v                   v
        Private S3          Application
        Bucket              Load Balancer
        (Static Files)      (ALB)
                                |
                                v
                         Target Group
                                |
                                v
                      EC2 Auto Scaling Group
                      (Private App Subnets)
                                |
                                v
                         Amazon RDS
                            MySQL
                      (Private DB Subnets)
```

**Important:** CloudFront will serve static content from S3 and can forward dynamic application requests to the ALB.

For the initial application deployment, the ALB and EC2 layer can be tested independently. The CloudFront-to-ALB HTTPS integration will be completed when the required domain and ACM certificates are available.

## 2.2 What Each Component Does

| Component | Responsibility |
|---|---|
| Route 53 | DNS resolution and domain routing |
| CloudFront | Content delivery and edge caching |
| AWS WAF | Protection against common web attacks |
| S3 | Static files and application assets |
| ALB | Receives HTTP/HTTPS requests and distributes traffic |
| EC2 | Runs the Web Application |
| Auto Scaling | Adjusts EC2 capacity based on demand |
| RDS MySQL | Stores application data |

---

# 3. Network Architecture

## 3.1 VPC Configuration

We will create one main VPC.

| Setting | Value |
|---|---|
| VPC Name | `main-vpc` |
| CIDR | `10.0.0.0/16` |
| Region | `us-east-1` |
| Availability Zones | 2 |
| DNS Support | Enabled |
| DNS Hostnames | Enabled |

## 3.2 Subnet Design

We will divide the VPC into six subnets.

| Subnet | CIDR | Availability Zone | Purpose |
|---|---|---|---|
| Public A | `10.0.1.0/24` | AZ-A | ALB / NAT Gateway |
| Public B | `10.0.2.0/24` | AZ-B | ALB |
| Private App A | `10.0.11.0/24` | AZ-A | EC2 Application |
| Private App B | `10.0.12.0/24` | AZ-B | EC2 Application |
| Private DB A | `10.0.21.0/24` | AZ-A | RDS |
| Private DB B | `10.0.22.0/24` | AZ-B | RDS |

AZ-A and AZ-B represent two different Availability Zones. The actual AZ names will be selected dynamically in Terraform rather than hardcoded.

## 3.3 Network Components

### Internet Gateway (IGW)

- Attached to the main VPC.
- Provides internet connectivity to public subnets through their route tables.

### Public Route Table

- Associated with Public A and Public B.
- Default route: `0.0.0.0/0` through the Internet Gateway.

### Private Application Route Table

- Associated with Private App A and Private App B.
- Uses NAT Gateway for outbound internet access if required.
- No direct inbound internet access.

### Private Database Route Table

- Associated with Private DB A and Private DB B.
- No direct route to the public internet.
- Database instances must not be publicly accessible.

### NAT Gateway

A single NAT Gateway may be used initially to reduce costs.

It allows private application instances to access external services for updates or downloads without receiving public IP addresses.

A single NAT Gateway is not highly available across both AZs. This limitation will be documented.

If NAT is not required, we can consider VPC Endpoints and preconfigured application images as alternatives.

---

# 4. Load Balancer & Compute Architecture

## 4.1 Application Load Balancer (ALB)

**Decision:** Use an internet-facing Application Load Balancer.

The ALB will be deployed in both public subnets.

Its responsibilities:

- Receive incoming application traffic.
- Perform health checks.
- Forward requests to healthy EC2 instances.
- Distribute traffic across instances in different Availability Zones.

### Traffic Flow

```text
Internet / CloudFront
         |
         v
      ALB
         |
         v
   Target Group
         |
         v
   EC2 Instance 1
   EC2 Instance 2
```

The ALB is in front of the EC2 instances. It is not placed between EC2 and RDS.

### Listener Configuration

| Listener | Action |
|---|---|
| HTTP 80 | Redirect to HTTPS 443 |
| HTTPS 443 | Forward requests to the application Target Group |

HTTPS requires an appropriate ACM certificate and domain configuration.

For early testing, HTTP can be used temporarily, but it must not be treated as the final production security configuration.

### Target Group

- Target type: Instances.
- Protocol: HTTP.
- Application port: 80 or 8080, depending on the application.
- Health check path: `/health` or the application's configured health endpoint.

## 4.2 Amazon EC2

EC2 instances will run inside Private Application Subnets.

They will:

- Host the Web Application.
- Receive requests only from the ALB Security Group.
- Connect to RDS through the database port.
- Use an IAM Instance Role.
- Use Systems Manager Session Manager for administrative access.

EC2 instances will not receive public IP addresses.

## 4.3 Auto Scaling Group

The application will use an Auto Scaling Group.

Initial cost-conscious configuration:

| Setting | Initial Value |
|---|---|
| Minimum Capacity | 1 |
| Desired Capacity | 1 |
| Maximum Capacity | 2 |
| Subnets | Private App A and B |

This configuration allows scaling up to two instances, but does not guarantee continuous multi-instance high availability while desired capacity remains one.

---

# 5. Database Architecture

## 5.1 Database Decision

**Selected Database: Amazon RDS for MySQL**

MySQL is selected because it is widely used for Web Applications, straightforward to integrate with EC2, and suitable for a demonstration application.

| Setting | Decision |
|---|---|
| Service | Amazon RDS |
| Engine | MySQL |
| Deployment | Single-AZ initially |
| Public Access | Disabled |
| Database Subnets | Private DB A and B |
| Port | 3306 |
| Storage Encryption | Enabled |
| Automated Backups | Enabled |

The DB Subnet Group will include private database subnets in two Availability Zones, even though the initial database deployment will use Single-AZ to reduce cost.

## 5.2 Database Security

- RDS must not be publicly accessible.
- Port 3306 is allowed only from the Application Security Group.
- Database credentials must not be stored in GitHub.
- Credentials should be managed using AWS Secrets Manager.
- Encryption at rest must be enabled.
- Automated backups must be configured.

### Database Connection

```text
EC2 Application
      |
      | TCP 3306
      v
RDS MySQL
```

Only the application servers should be allowed to connect to the database.

---

# 6. Security Architecture

## 6.1 Security Groups

The following rules define the initial security baseline.

| Source | Destination | Port | Purpose |
|---|---|---|---|
| Internet | CloudFront | HTTPS 443 | Public application access |
| CloudFront | ALB | HTTPS 443 | Origin traffic |
| ALB Security Group | App Security Group | 80 or 8080 | Application requests |
| App Security Group | DB Security Group | 3306 | Database connectivity |
| Administrator | EC2 | SSM | Secure management |

After CloudFront integration, the ALB should accept traffic only from the CloudFront origin-facing managed prefix list, with additional origin verification where appropriate.

During initial testing, access may be temporarily restricted to approved test IP addresses. Do not leave the ALB publicly open in the final configuration.

## 6.2 Network ACLs

NACLs will provide subnet-level traffic filtering.

They will complement Security Groups rather than replace them.

The rules must account for return traffic and ephemeral ports.

## 6.3 IAM

IAM will follow the Least Privilege principle.

The implementation will include:

- IAM Users and Groups for team access.
- IAM Roles for AWS services.
- Policies with only the required permissions.
- MFA for human users.
- Permission Boundary demonstration.
- Access Analyzer where applicable.
- No embedded access keys in application instances.

## 6.4 AWS WAF

AWS WAF will protect the CloudFront distribution.

Initial rules may include:

- AWS Managed Common Rule Set.
- SQL Injection protection.
- Known Bad Inputs protection.
- Rate-based rules.

CloudFront-scoped Web ACLs must be created in `us-east-1`.

If a separate regional Web ACL is later associated with the ALB, that will be treated as an additional configuration and cost decision.

## 6.5 Amazon S3 Security

The application assets bucket will have:

- Block Public Access enabled.
- Encryption enabled.
- Bucket policies restricting access.
- CloudFront Origin Access Control (OAC) for CloudFront delivery.

The S3 bucket must not be made publicly accessible just to serve static files.

---

# 7. Monitoring, Logging & Threat Detection

The project will include the following services:

| Service | Purpose |
|---|---|
| CloudTrail | Records AWS account API activity |
| AWS Config | Tracks resource configuration and compliance |
| GuardDuty | Detects suspicious activity and threats |
| Security Hub | Centralizes security findings |
| CloudWatch | Metrics, logs, alarms |
| VPC Flow Logs | Records network traffic metadata |
| Athena | Queries supported log data |

Services will be enabled in stages after reviewing their pricing and account permissions.

## Incident Response Demonstration

The team will document a simulated compromised-instance scenario:

1. Identify suspicious activity.
2. Review monitoring and detection findings.
3. Isolate the affected EC2 instance using Security Group changes.
4. Preserve relevant logs and evidence.
5. Create a snapshot when appropriate.
6. Document the response and recovery steps.

---

# 8. Hybrid Connectivity

Hybrid networking will be covered as a separate lab or extension of the main architecture.

The main application VPC does not need a Transit Gateway simply to host the application.

The following topics will be covered:

| Technology | Implementation Plan |
|---|---|
| VPC Peering | Practical lab |
| VPC Endpoints | Implement where useful |
| Transit Gateway | Architecture design / optional lab |
| Site-to-Site VPN | Lab if a suitable Customer Gateway endpoint is available |
| Client VPN | Concepts or optional lab |
| AWS PrivateLink | Concepts and architecture |
| Direct Connect | Concepts and comparison |
| Route 53 | DNS and health-check design |

A second lab VPC can be created for connectivity demonstrations.

VPC Peering is not transitive. Transit Gateway is more appropriate for hub-and-spoke connectivity between multiple VPCs.

A Site-to-Site VPN requires a suitable Customer Gateway endpoint with a reachable public IP address.

---

# 9. Governance & Landing Zone

Since the project uses a single AWS account, the following capabilities will be implemented directly:

- IAM baseline.
- MFA.
- Least Privilege.
- IAM Roles and Policies.
- Permission Boundary example.
- AWS Budgets.
- Cost allocation tags.
- CloudTrail.
- AWS Config where applicable.
- Security monitoring.

The following Multi-Account features will be covered conceptually or through diagrams:

- AWS Organizations.
- Organizational Units.
- Member Accounts.
- Consolidated Billing.
- Service Control Policies.
- Organization-wide CloudTrail.
- Cross-account governance.

These features will not be reported as deployed unless the environment is later changed to support them.

---

# 10. Terraform Project Structure

The project files will be organized as follows:

| File | Responsibility |
|---|---|
| `provider.tf` | AWS Provider configuration |
| `versions.tf` | Terraform and provider versions, S3 backend |
| `variables.tf` | Shared input variables |
| `outputs.tf` | Project outputs |
| `governance.tf` | IAM and account governance |
| `network.tf` | VPC, subnets, routes, gateways, Security Groups |
| `compute.tf` | EC2, ALB, Target Groups, Auto Scaling |
| `data.tf` | RDS, S3, database subnet group |
| `security.tf` | WAF and security configurations |
| `monitoring.tf` | CloudTrail, Config, GuardDuty, CloudWatch |

## 10.1 Agreed Terraform Resource Labels

The team should use consistent resource labels.

### Network

```hcl
aws_vpc.main

aws_subnet.public_a
aws_subnet.public_b

aws_subnet.private_app_a
aws_subnet.private_app_b

aws_subnet.private_db_a
aws_subnet.private_db_b

aws_internet_gateway.main

aws_security_group.alb
aws_security_group.app
aws_security_group.db
```

### Compute

```hcl
aws_lb.app
aws_lb_target_group.app
aws_lb_listener.http
aws_lb_listener.https

aws_launch_template.app
aws_autoscaling_group.app
```

### Data

```hcl
aws_db_subnet_group.main
aws_db_instance.main

aws_s3_bucket.app_assets
```

These labels are the agreed naming baseline. Changes must be coordinated before implementation.

---

# 11. Team Ownership

| Team Member | Responsibility | Files |
|---|---|---|
| Samy – Team Lead | Architecture, IAM, Governance, Integration | `governance.tf`, `variables.tf`, `outputs.tf` |
| Mohamed Ayad | Network Foundation and Hybrid Networking | `network.tf` |
| Moaaz Ehab | Compute and Application Hosting | `compute.tf` |
| Kareem Hamdi | Database and Storage | `data.tf` |
| Haitham Mohamed | Security and Monitoring | `security.tf`, `monitoring.tf` |

Security Group requirements must be agreed between Mohamed and the relevant service owner.

For example:
- ALB-to-EC2 rules must be coordinated with Moaaz.
- EC2-to-RDS rules must be coordinated with Kareem.
- WAF and edge security requirements must be coordinated with Haitham.

---

# 12. Implementation Dependencies & Order

The implementation must follow this sequence:

**Phase 1 – Network Foundation**
- VPC.
- Subnets.
- Internet Gateway.
- Route Tables.
- Security Groups.
- NAT or VPC Endpoints, after cost review.

**Phase 2 – Compute**
- ALB.
- Target Group.
- Launch Template.
- EC2.
- Auto Scaling Group.
- Systems Manager.

**Phase 3 – Data**
- DB Subnet Group.
- RDS MySQL.
- S3 Bucket.
- Encryption and backups.

**Phase 4 – Security & Edge**
- WAF.
- CloudFront.
- S3 Origin Access Control.
- Security baseline.

**Phase 5 – Monitoring**
- CloudTrail.
- Config.
- GuardDuty.
- Security Hub.
- CloudWatch.
- Flow Logs.

**Phase 6 – Hybrid Networking**
- VPC Peering.
- VPN lab.
- Transit Gateway design.
- Connectivity testing.

**Phase 7 – Integration & Final Testing**
- Terraform integration.
- Connectivity tests.
- Security tests.
- Documentation.
- Final architecture diagram.

Terraform will automatically manage dependencies when resources reference one another. The phase order is for team coordination and review, not a replacement for Terraform dependency management.

---

# 13. Cost Management

The project is educational and must remain cost-conscious.

Potential chargeable services include:

- NAT Gateway.
- Application Load Balancer.
- EC2.
- RDS.
- CloudFront data transfer.
- AWS WAF.
- GuardDuty.
- Security Hub.
- AWS Config.
- Interface VPC Endpoints.

Cost controls:

1. Use AWS Budgets and billing alerts.
2. Start RDS with Single-AZ.
3. Start Auto Scaling with desired capacity of one.
4. Use one NAT Gateway only if required.
5. Enable optional security services in stages.
6. Review estimated costs before applying changes.
7. Stop or delete temporary lab resources when no longer needed.

No paid infrastructure resource should be deployed without Team Lead review.

---

# 14. Security & Acceptance Tests

The final infrastructure should pass the following checks:

- Application is reachable through the intended entry point.
- ALB health checks report healthy targets.
- EC2 instances have no public IP addresses.
- EC2 accepts application traffic only from the ALB Security Group.
- RDS has Public Access disabled.
- RDS accepts connections only from the App Security Group.
- S3 Block Public Access is enabled.
- SSM can manage EC2 without public SSH access.
- WAF rules are tested.
- CloudTrail records account activity.
- VPC Flow Logs are available.
- Security findings can be reviewed.
- Terraform plan and validation complete successfully.

---

# 15. Team Workflow

Every member must:

1. Work only on their assigned Terraform files.
2. Create a separate Git branch.
3. Run `terraform fmt -recursive`.
4. Run `terraform validate`.
5. Review the Terraform plan when appropriate.
6. Commit and push changes.
7. Open a Pull Request to `main`.

The Team Lead reviews and merges Pull Requests.

Only the Team Lead performs the final `terraform apply`, after checking the full plan, dependencies, permissions, and estimated costs.

Never commit:
- AWS access keys.
- Passwords.
- Database credentials.
- Terraform state files.
- Terraform plan files.
- Secret configuration files.

---

# 16. Final Design Principles

The project will follow these principles:

- Least Privilege.
- Defense in Depth.
- Network Segmentation.
- Private Database Access.
- No Public EC2 Management Access.
- Encryption at Rest and in Transit.
- Infrastructure as Code.
- Monitoring and Auditability.
- Cost Optimization.
- Clear separation between implemented services, practical labs, and conceptual designs.

**This document is the team's baseline architecture. Any change to the database engine, network CIDR plan, resource ownership, or major service selection must be agreed upon before implementation.**
