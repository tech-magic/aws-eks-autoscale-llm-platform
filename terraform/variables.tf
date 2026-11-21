variable "aws_region" {
  description = "AWS region. Must have available capacity and quota for G-family GPU instances."
  type        = string
  default     = "us-east-1" # Virginia
}

variable "cluster_name" {
  description = "EKS cluster name used to tag and namespace all cluster-associated resources."
  type        = string
  default     = "eks-elastic-llm-aws-eks-vllm"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version (e.g., '1.30'). Set to null to use the EKS service default."
  type        = string
  default     = null
}

variable "system_instance_type" {
  description = "EC2 instance type for system node group (CoreDNS, kube-proxy, CSI drivers). 2 vCPU, 8 GB RAM."
  type        = string
  default     = "m6i.large" # 2 vCPU / 8 GiB, Alternative: "t3.large" for cost savings in development
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated EKS VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "huggingface_token" {
  description = "User Access Token from Hugging Face with read permissions for gated models"
  type        = string
  sensitive   = true
  default     = "" # Can be passed via TF_VAR_huggingface_token or -var
}

variable "grafana_password" {
  description = "Grafana Password"
  type        = string
  sensitive   = true
}

variable "demo_user_email" {
  description = "Email/username for the sample Cognito OAuth user."
  type        = string
  default     = "demo-user@example.com"
}

variable "demo_user_password" {
  description = "Permanent password for the sample Cognito OAuth user (min 8 chars, upper, lower, number, symbol)."
  type        = string
  sensitive   = true
}
