################################################################################
# TERRAFORM ENGINE & PLUGIN REQUIREMENTS (versions.tf)
# ------------------------------------------------------------------------------
# Why do we need this file?
# Before Terraform can build any servers, networks, or AI clusters in the cloud,
# it needs two things:
#   1. The right version of the Terraform CLI engine itself.
#   2. A set of "Providers" (plugins) that teach Terraform how to speak the
#      API language of AWS, Kubernetes, Helm, and security certificate tools.
#
# When you run `terraform init`, Terraform reads this file and automatically
# downloads and locks these exact plugin versions so everyone on your team (and
# your future self) gets the exact same, predictable behavior.
################################################################################

terraform {
  # Require Terraform CLI version 1.15.x (e.g., 1.15.0, 1.15.2, etc.).
  # The "~>" symbol ("pessimistic constraint") allows safe bug-fix patches
  # within 1.15 while blocking major 2.0 updates that might break syntax.
  required_version = "~> 1.15"

  # ----------------------------------------------------------------------------
  # Required Cloud & Kubernetes Plugins ("Providers")
  # ----------------------------------------------------------------------------
  required_providers {
    # 1. TLS Provider (Security Certificates)
    # Used to inspect our EKS cluster's cryptographic TLS certificate thumbprint
    # so AWS IAM can securely trust Kubernetes service accounts (OIDC / IRSA).
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0" # Any 4.x release (4.0, 4.1, etc.)
    }

    # 2. Random Provider (Unique Name Generator)
    # Generates the 4-character random suffix (e.g., "x9k2") appended to cluster
    # and domain names so repeated deployments never collide in AWS.
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0" # Version 3.6.0 or newer
    }

    # 3. AWS Provider (Core Amazon Web Services Plugin)
    # The primary plugin that builds your VPC network, EKS cluster, EC2 GPU
    # servers, EFS shared model storage, Cognito login pool, and API Gateway.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0" # Any 5.x release (blocks breaking 6.x changes)
    }

    # 4. Kubernetes Provider (Native Kubernetes Objects)
    # Connects inside your EKS cluster to create core Kubernetes resources like
    # Secrets (for your Hugging Face token), StorageClasses, and shared PVCs.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35" # Any 2.35.x patch release
    }

    # 5. Kubectl Provider (Raw YAML & Custom Resource Plugin)
    # Allows Terraform to apply raw Kubernetes YAML manifests directly—essential
    # for Custom Resource Definitions (CRDs) like Karpenter GPU NodePools and
    # Prometheus PodMonitors that aren't built into standard Kubernetes.
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.4.0" # Version 2.4.0 or newer
    }

    # 6. Helm Provider (Kubernetes App Package Manager)
    # Installs complex pre-packaged Kubernetes applications in one step,
    # including Karpenter, NVIDIA GPU Operator, Prometheus/Grafana, KEDA, and
    # Cluster Autoscaler.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17" # Any 2.17.x patch release
    }
  }
}