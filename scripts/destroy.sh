#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TF_DIR="$ROOT_DIR/terraform"

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo "Error: AWS credentials are not loaded. Run 'set -a && source .env && set +a' first."
  exit 1
fi

echo "==> Step 1: Deleting Kubernetes vLLM workloads to trigger Karpenter GPU node scale-down..."
if kubectl cluster-info >/dev/null 2>&1; then
  kubectl delete -f "$ROOT_DIR/vllm-llama3.yaml" --ignore-not-found=true --wait=true
  kubectl delete deployment,service,scaledobject -l app=vllm-router -n default --ignore-not-found=true

  echo "==> Step 2: Waiting for Karpenter-provisioned GPU nodes (NodeClaims) to terminate..."
  kubectl delete nodeclaims --all --ignore-not-found=true --wait=true || true

  # Poll until no GPU nodes remain in the cluster (timeout after 3 minutes)
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

echo "==> Step 3: Destroying AWS infrastructure via Terraform..."
cd "$TF_DIR"

# Remove potential Kubernetes state drift that blocks terraform destroy
terraform state rm kubernetes_deployment_v1.vllm_router >/dev/null 2>&1 || true

terraform destroy -auto-approve

echo "==> Teardown complete! Verify in the AWS EC2 console that no g4dn/g5 instances remain running."