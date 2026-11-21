#!/usr/bin/env bash
################################################################################
# AUTOMATED INFRASTRUCTURE TEARDOWN SCRIPT (destroy.sh)
# ------------------------------------------------------------------------------
# Why do we need a special teardown script instead of just `terraform destroy`?
# In AWS, dynamically created GPU servers (launched by Karpenter) and Kubernetes
# load balancers attach network cards (ENIs) and security groups to your VPC.
# If you run `terraform destroy` directly without first shutting down the AI
# workloads and waiting for Karpenter to terminate its GPU EC2 servers, AWS
# will block VPC deletion with "DependencyViolation" errors—leaving behind
# orphaned GPU servers that continue billing your account!
#
# This script safely tears down the stack in the exact reverse order:
#   1. Deletes the AI model pods and router inside Kubernetes so nothing demands GPUs.
#   2. Forces Karpenter to terminate all dynamic GPU EC2 servers and waits until
#      zero GPU nodes remain in the cluster.
#   3. Cleans up any minor Terraform state drift and runs `terraform destroy` to
#      delete the EKS cluster, EFS drive, Cognito pool, API Gateway, and VPC.
################################################################################

# Strict Bash Safety Flags ("Fail Fast"):
# - `set -e`: Stop the script immediately if an unexpected command fails.
# - `set -u`: Error out if any required environment variable is unset.
# - `set -o pipefail`: Catch failures occurring inside piped (`|`) commands.
set -euo pipefail

# ------------------------------------------------------------------------------
# Step 0A: Resolve Project Folder Paths Reliably
# ------------------------------------------------------------------------------
# Automatically locates the `scripts/` folder, the project root folder, and the
# `terraform/` folder regardless of which directory you run this script from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TF_DIR="$ROOT_DIR/terraform"

# ------------------------------------------------------------------------------
# Step 0B: Pre-Flight Credential Check (Verify AWS Keys Are Loaded)
# ------------------------------------------------------------------------------
# Ensures your AWS credentials are active in your shell session before starting
# the teardown process.
if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo "Error: AWS credentials are not loaded. Run 'set -a && source .env && set +a' first."
  exit 1
fi

# ------------------------------------------------------------------------------
# Step 1: Delete Kubernetes AI Workloads (Remove GPU Demand First)
# ------------------------------------------------------------------------------
# First, check if the Kubernetes cluster is still reachable (`kubectl cluster-info`).
# (If a previous teardown already deleted the EKS cluster, this safely skips
# straight to Step 3 so the script remains idempotent and safe to re-run.)
echo "==> Step 1: Deleting Kubernetes vLLM workloads to trigger Karpenter GPU node scale-down..."
if kubectl cluster-info >/dev/null 2>&1; then
  # Remove the vLLM Llama-3.1 deployment and KEDA ScaledObject so KEDA stops
  # requesting GPU replicas. `--ignore-not-found=true` prevents errors if
  # already deleted; `--wait=true` waits for pods to finish shutting down.
  kubectl delete -f "$ROOT_DIR/vllm-llama3.yaml" --ignore-not-found=true --wait=true

  # Remove any router deployments, services, or scalers labeled `app=vllm-router`
  # so AWS cleans up the internal Network Load Balancer (NLB) cleanly.
  kubectl delete deployment,service,scaledobject -l app=vllm-router -n default --ignore-not-found=true

  # ----------------------------------------------------------------------------
  # Step 2: Terminate All Dynamic Karpenter GPU Servers & Wait for Confirmation
  # ----------------------------------------------------------------------------
  # Explicitly delete all Karpenter `NodeClaims` (the custom objects representing
  # dynamic EC2 GPU instances) so Karpenter immediately terminates the underlying
  # AWS EC2 servers and detaches their network interfaces from the VPC.
  echo "==> Step 2: Waiting for Karpenter-provisioned GPU nodes (NodeClaims) to terminate..."
  kubectl delete nodeclaims --all --ignore-not-found=true --wait=true || true

  # Poll the cluster every 5 seconds for up to 3 minutes (36 checks x 5s = 180s)
  # to verify that every single Karpenter-managed GPU server has completely
  # vanished before Terraform attempts to delete the VPC network beneath them.
  for i in {1..36}; do
    GPU_NODES=$(kubectl get nodes -l karpenter.sh/nodepool --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$GPU_NODES" -eq 0 ]]; then
      echo "    All Karpenter worker nodes terminated."
      break
    fi
    echo "    Waiting for $GPU_NODES Karpenter node(s) to terminate... (${i}/36)"
    sleep 5
  done
else
  echo "    Cluster unreachable or kubeconfig not active; proceeding directly to Terraform destroy."
fi

# ------------------------------------------------------------------------------
# Step 3: Destroy All Remaining AWS Infrastructure via Terraform
# ------------------------------------------------------------------------------
echo "==> Step 3: Destroying AWS infrastructure via Terraform..."
cd "$TF_DIR"

# State Drift Guardrail:
# Because Step 1 already deleted `vllm-router` via `kubectl` (and its internal NLB),
# removing it from Terraform's state tracking prevents Terraform from hanging or
# complaining if that resource was already cleaned up out-of-band.
terraform state rm kubernetes_deployment_v1.vllm_router >/dev/null 2>&1 || true

# Permanently delete all remaining Terraform-managed resources (EKS cluster,
# CPU system nodes, EFS storage drive, Cognito user pool, API Gateway, and VPC).
terraform destroy -auto-approve

echo "==> Teardown complete! Verify in the AWS EC2 console that no g4dn/g5 instances remain running."