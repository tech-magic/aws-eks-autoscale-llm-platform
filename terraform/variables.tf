################################################################################
# TERRAFORM INPUT VARIABLES (The Control Panel for Your Infrastructure)
# ------------------------------------------------------------------------------
# Why do we need this file?
# Think of `variables.tf` as the settings menu for your entire cloud deployment.
# Instead of hunting through dozens of code files to change a region, server
# size, or password, you configure everything cleanly in one place.
#
# How values are supplied:
# - Variables WITH a `default = ...` use that preset value automatically unless
#   you override them.
# - Variables WITHOUT a `default` (like `grafana_password` and `demo_user_password`)
#   are REQUIRED—Terraform will ask for them or read them from your `.env` file
#   (via `TF_VAR_<variable_name>`) before building anything.
################################################################################


################################################################################
# 1. CLOUD LOCATION & CLUSTER IDENTITY
################################################################################

# Which AWS data center region to build the cluster in.
# Important: G-family GPU servers (like g4dn and g5) are high-demand hardware,
# so pick a major region like "us-east-1" (N. Virginia) where GPU availability
# and your AWS account's GPU vCPU quota are highest.
variable "aws_region" {
  description = "AWS region. Must have available capacity and quota for G-family GPU instances."
  type        = string
  default     = "us-east-1" # N. Virginia (largest GPU capacity pool in AWS)
}

# The base name prefix for your Kubernetes cluster and all its AWS tags.
# Note: Terraform automatically appends a 4-character random suffix (e.g., "-x9k2")
# in `providers.tf` so repeated deployments never collide.
variable "cluster_name" {
  description = "EKS cluster name used to tag and namespace all cluster-associated resources."
  type        = string
  default     = "eks-elastic-llm-aws-eks-vllm"
}

# Which version of Kubernetes AWS should install on the EKS control plane.
# Leaving this as `null` tells AWS to automatically pick its current recommended
# stable default version (so you don't accidentally request a deprecated version).
variable "kubernetes_version" {
  description = "EKS Kubernetes version (e.g., '1.30'). Set to null to use the EKS service default."
  type        = string
  default     = null
}


################################################################################
# 2. SERVER HARDWARE & PRIVATE NETWORKING
################################################################################

# The server size for your always-on CPU "system" nodes (which run Prometheus,
# Grafana, Karpenter, KEDA, and Kubernetes networking—NOT the AI models).
# - "m6i.large" (2 vCPUs, 8 GB RAM): Recommended steady performance for monitoring.
# - "t3.large" (2 vCPUs, 8 GB RAM): Slightly cheaper burstable option for testing.
variable "system_instance_type" {
  description = "EC2 instance type for system node group (CoreDNS, kube-proxy, CSI drivers). 2 vCPU, 8 GB RAM."
  type        = string
  default     = "m6i.large" # 2 vCPU / 8 GiB; alternative: "t3.large" for lower dev cost
}

# The private IP address range ("neighborhood block") reserved for your isolated
# AWS Virtual Private Cloud (VPC). "10.0.0.0/16" provides 65,536 private internal
# IP addresses—plenty of room for subnets, load balancers, and hundreds of pods.
variable "vpc_cidr" {
  description = "CIDR block for the dedicated EKS VPC."
  type        = string
  default     = "10.0.0.0/16"
}


################################################################################
# 3. API KEYS, PASSWORDS & DEMO USER CREDENTIALS (Sensitive Secrets)
# ------------------------------------------------------------------------------
# Notice `sensitive = true` on the secrets below:
# This tells Terraform to mask these passwords as `(sensitive value)` in your
# terminal logs so you don't accidentally leak credentials on screen or in CI logs.
################################################################################

# Your personal Hugging Face Read Token (starts with "hf_...").
# Required if you deploy gated open-weight models like Meta's Llama-3, where
# Hugging Face checks that you accepted the model license before downloading.
variable "huggingface_token" {
  description = "User Access Token from Hugging Face with read permissions for gated models"
  type        = string
  sensitive   = true
  default     = "" # Usually supplied via `export TF_VAR_huggingface_token="..."` in .env
}

# The administrator password you will use to log into the Grafana monitoring
# dashboard website (username is "admin"). Required—no default is set for safety.
variable "grafana_password" {
  description = "Grafana Password"
  type        = string
  sensitive   = true
}

# The email address (which also acts as the login username) for the test user
# account created automatically inside AWS Cognito.
variable "demo_user_email" {
  description = "Email/username for the sample Cognito OAuth user."
  type        = string
  default     = "demo-user@example.com"
}

# The login password for the sample Cognito user above.
# Must satisfy the Cognito password policy in `cognito.tf` (at least 8 characters,
# including uppercase, lowercase, a number, and a special symbol).
variable "demo_user_password" {
  description = "Permanent password for the sample Cognito OAuth user (min 8 chars, upper, lower, number, symbol)."
  type        = string
  sensitive   = true
}