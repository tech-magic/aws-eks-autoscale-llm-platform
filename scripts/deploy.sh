#!/usr/bin/env bash
################################################################################
# AUTOMATED END-TO-END DEPLOYMENT SCRIPT (deploy.sh)
# ------------------------------------------------------------------------------
# Why do we need this script?
# Building a complete AI inference platform on AWS involves several moving parts
# that must be created in a strict order:
#   1. Download Terraform plugins (`terraform init`).
#   2. Generate a unique 4-character deployment ID (`random_string.suffix`).
#   3. Create the core Kubernetes control plane (`aws_eks_cluster.this`) FIRST so
#      Terraform's Kubernetes & Helm plugins have a live cluster to connect to.
#   4. Provision the remaining cloud stack (VPC, EFS shared model storage,
#      Karpenter GPU autoscaler, Prometheus/KEDA, Cognito login, API Gateway).
#   5. Point your local `kubectl` CLI at the brand-new EKS cluster.
#   6. Deploy the Llama-3.1-8B vLLM GPU worker and KEDA autoscaling rules.
################################################################################

# Strict Bash Safety Flags ("Fail Fast"):
# - `set -e`: Stop the script immediately if ANY command fails (prevents cascading errors).
# - `set -u`: Treat unset/missing variables as an immediate error instead of silent blanks.
# - `set -o pipefail`: Catch errors even if they happen inside a piped (`|`) command.
set -euo pipefail

# ------------------------------------------------------------------------------
# Step 0A: Resolve Project Folder Paths Reliably
# ------------------------------------------------------------------------------
# Finds the exact directory where this script lives (`.../scripts`) and its parent
# project root directory (`.../`), so the script works no matter which folder
# you run it from in your terminal.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# ------------------------------------------------------------------------------
# Step 0B: Pre-Flight Credential Check (Verify `.env` Was Loaded)
# ------------------------------------------------------------------------------
# Checks that your AWS Access Key and Hugging Face token are loaded into your
# terminal session before spending time or money creating cloud resources.
if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${TF_VAR_huggingface_token:-}" ]]; then
  echo "Error: Environment variables not loaded. Run 'set -a && source .env && set +a' first."
  exit 1
fi

# ------------------------------------------------------------------------------
# Step 1: Initialize Terraform (Download Cloud & Kubernetes Plugins)
# ------------------------------------------------------------------------------
# Moves into the `terraform/` directory and downloads the required AWS,
# Kubernetes, Helm, and Kubectl provider plugins defined in `versions.tf`.
echo "==> Step 1: Initializing Terraform..."
cd "$ROOT_DIR/terraform"
terraform init

# ------------------------------------------------------------------------------
# Step 2: Generate the Unique 4-Character Deployment Suffix
# ------------------------------------------------------------------------------
# Creates the random 4-character ID (e.g., "x9k2") first so every AWS resource
# (cluster name, Cognito domain, IAM roles) shares a consistent, conflict-free name.
echo "==> Step 2: Initialize/Validate Random String Suffix for this Run..."
terraform apply -target=random_string.suffix -auto-approve

# ------------------------------------------------------------------------------
# Step 3: Build the EKS Kubernetes Control Plane First
# ------------------------------------------------------------------------------
# Why target `aws_eks_cluster.this` separately?
# Terraform's `kubernetes`, `kubectl`, and `helm` providers need the EKS cluster's
# API endpoint URL and security certificate to exist before they can plan or
# install in-cluster apps. Building EKS first guarantees clean provider authentication.
echo "==> Step 3: Provisioning EKS Control Plane..."
terraform apply -target=aws_eks_cluster.this -auto-approve

# ------------------------------------------------------------------------------
# Step 4: Provision the Full Cloud & Kubernetes Infrastructure Stack
# ------------------------------------------------------------------------------
# Now that the EKS cluster is alive, Terraform builds everything else in parallel:
# - Shared Amazon EFS network drive for caching Hugging Face AI models
# - Karpenter & NVIDIA GPU Operator for elastic on-demand/spot GPU servers
# - kube-prometheus-stack & KEDA for real-time queue metrics & scale-to-zero
# - vLLM Production Stack Router + Internal NLB
# - AWS Cognito OAuth user pool + Public API Gateway (`/v1/*`)
echo "==> Step 4: Provisioning Remaining Infrastructure (Cognito, EFS, Karpenter, API Gateway)..."
terraform apply -auto-approve

# ------------------------------------------------------------------------------
# Step 5: Connect Your Local `kubectl` CLI to the New Cluster
# ------------------------------------------------------------------------------
# Reads the generated cluster name from Terraform outputs and updates your local
# `~/.kube/config` file so `kubectl` commands talk directly to this new cluster.
echo "==> Step 5: Configuring kubectl..."
CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

# ------------------------------------------------------------------------------
# Step 6: Deploy the vLLM Llama-3.1-8B Worker & KEDA Autoscaler
# ------------------------------------------------------------------------------
# Applies `vllm-llama3.yaml` to create the vLLM GPU Deployment and KEDA
# ScaledObject. KEDA immediately detects `minReplicaCount` (or incoming queue
# depth) and triggers Karpenter to boot a `g4dn.xlarge` NVIDIA T4 GPU server.
echo "==> Step 6: Deploying vLLM Llama-3.1 Workload..."
cd "$ROOT_DIR"
kubectl apply -f vllm-llama3.yaml

echo "==> Deployment triggered! Monitor pod startup with:"
echo "    kubectl get pods -l app=vllm-llama3 -w"