#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${TF_VAR_huggingface_token:-}" ]]; then
  echo "Error: Environment variables not loaded. Run 'set -a && source .env && set +a' first."
  exit 1
fi

echo "==> Step 1: Initializing Terraform..."
cd "$ROOT_DIR/terraform"
terraform init

echo "==> Step 2: Initialize/Validate Random String Suffix for this Run..."
terraform apply -target=random_string.suffix -auto-approve

echo "==> Step 3: Provisioning EKS Control Plane..."
terraform apply -target=aws_eks_cluster.this -auto-approve

echo "==> Step 4: Provisioning Remaining Infrastructure (Cognito, EFS, Karpenter, API Gateway)..."
terraform apply -auto-approve

echo "==> Step 5: Configuring kubectl..."
CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

echo "==> Step 6: Deploying vLLM Llama-3.1 Workload..."
cd "$ROOT_DIR"
kubectl apply -f vllm-llama3.yaml

echo "==> Deployment triggered! Monitor pod startup with:"
echo "    kubectl get pods -l app=vllm-llama3 -w"