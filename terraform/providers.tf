################################################################################
# 1. UNIQUE NAMING & GLOBAL VARIABLES (Preventing Name Collisions in AWS)
# ------------------------------------------------------------------------------
# Why do we need this?
# Many AWS resources (like Cognito domains, S3 buckets, and IAM roles) require
# globally unique names, or fail if an old resource with the same name is still
# cleaning up. Generating a 4-character random suffix (e.g., "a8f2") ensures
# every deployment gets a clean, conflict-free name automatically.
################################################################################

# Generates a 4-character lowercase alphanumeric string (e.g., "x9k2") once
# when the project is first created, and remembers it in Terraform state.
resource "random_string" "suffix" {
  length  = 4     # 4 characters long
  special = false # No symbols like !@#$ (safe for URLs and AWS names)
  upper   = false # Lowercase only (required by DNS/Cognito domain rules)
}

# Local variables act like reusable constants inside this Terraform project
locals {
  poc_tag_name      = "eks-elastic-llm"                       # High-level project label
  workload_tag_name = "llm-inference-gateway"                 # Specific system function label
  naming_suffix     = random_string.suffix.result             # The 4-char random ID above
  eks_cluster_name  = "${var.cluster_name}-${local.naming_suffix}" # e.g., "my-llm-x9k2"
}


################################################################################
# 2. AWS PROVIDER & AUTOMATIC RESOURCE TAGGING (Your Cloud Account Connection)
# ------------------------------------------------------------------------------
# Why do we need this?
# A "Provider" is Terraform's plugin for talking to a specific cloud or tool.
# Here, we configure Terraform to build infrastructure in your chosen AWS region
# and automatically stamp every single AWS resource with cost-tracking and
# ownership tags—so you never lose track of what belongs to this project.
################################################################################

provider "aws" {
  region = var.aws_region # AWS data center region (e.g., "us-east-1")

  # Automatically attach these 5 labels ("tags") to EVERY AWS resource created
  # by Terraform (servers, networks, disks, firewalls, IAM roles, etc.)
  default_tags {
    tags = {
      managed_by       = "Terraform"             # Marks resource as IaC-managed (don't edit manually!)
      eks_cluster_name = local.eks_cluster_name  # Links resource to this specific cluster
      poc              = local.poc_tag_name      # Proof-of-Concept identifier
      workload         = local.workload_tag_name # Workload category for cost reporting
      naming_suffix    = local.naming_suffix     # Unique deployment ID
    }
  }
}


################################################################################
# 3. AWS RESOURCE GROUP (A Single Dashboard Folder for Everything You Built)
# ------------------------------------------------------------------------------
# Why do we need this?
# Because an EKS AI platform creates dozens of separate items across EC2, VPC,
# EFS, Cognito, and API Gateway, finding them all in the AWS Console can feel
# overwhelming. An AWS Resource Group acts like a smart search folder that
# automatically gathers all resources matching your project tags into one view.
################################################################################

resource "aws_resourcegroups_group" "cluster_resources" {
  name        = "${local.poc_tag_name}-${local.workload_tag_name}-resource-group"
  description = "Resource group tracking all AWS resources"

  resource_query {
    query = jsonencode({
      # Include all supported AWS service types (EC2, EFS, VPC, EKS, etc.)
      ResourceTypeFilters = ["AWS::AllSupported"]

      # Collect any resource carrying both of these tags
      # (Note: Ensure resources also carry the `function` tag, or update this key
      # to `workload` to match `default_tags` above!)
      TagFilters = [
        {
          Key    = "poc"
          Values = [local.poc_tag_name]
        },
        {
          Key    = "function"
          Values = [local.workload_tag_name]
        }
      ]
    })
  }
}


################################################################################
# 4. KUBERNETES, KUBECTL & HELM PROVIDERS (Talking to the Cluster Inside AWS)
# ------------------------------------------------------------------------------
# Why do we need three separate Kubernetes providers?
# Once AWS finishes building the EKS cluster, Terraform also needs to install
# software and configs INSIDE Kubernetes:
#   1. `kubernetes`: Manages native objects (Secrets, StorageClasses, PVCs).
#   2. `kubectl`: Applies custom Kubernetes YAML manifests (Karpenter NodePools,
#      Prometheus PodMonitors) without rigid schema validation delays.
#   3. `helm`: Installs packaged Kubernetes apps (Karpenter, GPU Operator,
#      Prometheus, KEDA, Cluster Autoscaler).
#
# How authentication works (`exec` block):
# EKS login tokens expire every ~15 minutes for security. Instead of storing
# static passwords, all three providers run `aws eks get-token` on the fly
# using your local AWS CLI credentials to fetch a fresh, short-lived pass.
#
# Why `try(..., null)`?
# On a brand-new `terraform apply`, the EKS cluster doesn't exist yet when
# Terraform first reads this file. `try()` prevents an error during startup and
# smoothly fills in the cluster URL and security certificate once EKS is ready.
################################################################################

# ------------------------------------------------------------------------------
# Provider 4A: Official Kubernetes Provider (Core Objects like Secrets & PVCs)
# ------------------------------------------------------------------------------
provider "kubernetes" {
  host                   = try(aws_eks_cluster.this.endpoint, null)
  cluster_ca_certificate = try(base64decode(aws_eks_cluster.this.certificate_authority[0].data), null)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      local.eks_cluster_name,
      "--region",
      var.aws_region
    ]
  }
}

# ------------------------------------------------------------------------------
# Provider 4B: Kubectl Provider (Custom CRDs like Karpenter & PodMonitors)
# ------------------------------------------------------------------------------
provider "kubectl" {
  host                   = try(aws_eks_cluster.this.endpoint, null)
  cluster_ca_certificate = try(base64decode(aws_eks_cluster.this.certificate_authority[0].data), null)
  load_config_file       = false # Ignore local ~/.kube/config; connect strictly to this Terraform cluster
  lazy_load              = true  # Wait until EKS is actually created before attempting to connect

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      local.eks_cluster_name,
      "--region",
      var.aws_region
    ]
  }
}

# ------------------------------------------------------------------------------
# Provider 4C: Helm Provider (App Installer for Prometheus, Karpenter, KEDA, etc.)
# ------------------------------------------------------------------------------
provider "helm" {
  kubernetes {
    host                   = try(aws_eks_cluster.this.endpoint, "")
    cluster_ca_certificate = try(base64decode(aws_eks_cluster.this.certificate_authority[0].data), "")

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks",
        "get-token",
        "--cluster-name",
        local.eks_cluster_name,
        "--region",
        var.aws_region
      ]
    }
  }
}