# Secure AWS Cloud Infrastructure with Terraform

## Project Overview

A secure and cost-aware AWS cloud infrastructure deployed within a single AWS account using Terraform.

The project focuses on network segmentation, compute resources, secure storage, IAM access control, logging, and monitoring.

## Main Objectives

- Design a secure AWS VPC architecture.
- Configure public and private subnets.
- Deploy and secure EC2 instances.
- Implement secure S3 storage.
- Apply IAM least-privilege principles.
- Enable CloudTrail logging and monitoring.
- Automate infrastructure deployment using Terraform.
- Follow GitHub collaboration and code review practices.
- Monitor AWS costs and avoid unnecessary paid resources.

## Project Scope

The core implementation will use a single AWS account.

Hybrid networking and additional security services will be considered optional extensions depending on permissions, time, and budget.

## Tools

- Amazon Web Services (AWS)
- Terraform
- AWS CLI
- Git and GitHub
- Visual Studio Code

## Team Workflow

Team members work on separate feature branches and submit Pull Requests.

The Team Leader reviews and merges changes and is responsible for Terraform apply, following the instructor's project rules.

## Important Notes

- Never commit AWS credentials or secrets.
- Never commit Terraform state files.
- Review Terraform plans before applying changes.
- Monitor AWS costs throughout the project.
