#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
LABEL_SELECTOR='vllm.ai/router-enabled=true'

# Define the run() helper so `run kubectl ...` works
run() {
  echo "\$ $*"
  "$@"
}

# Discover all matching deployments
DEPLOYMENTS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && DEPLOYMENTS+=("$line")
done < <(kubectl get deployments -n "${NAMESPACE}" \
  -l "${LABEL_SELECTOR}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

if [[ ${#DEPLOYMENTS[@]} -eq 0 ]]; then
  echo "Error: No deployments found in namespace '${NAMESPACE}' with label '${LABEL_SELECTOR}'." >&2
  exit 1
fi

echo "Found ${#DEPLOYMENTS[@]} deployment(s): ${DEPLOYMENTS[*]}"

for DEPLOY_NAME in "${DEPLOYMENTS[@]}"; do
  echo; echo "=================================================="
  echo "==> Deployment: ${DEPLOY_NAME}"
  echo "=================================================="

  echo; echo "==> [1/2] GPU memory inside the pod (nvidia-smi)"
  run kubectl exec -n "${NAMESPACE}" "deploy/${DEPLOY_NAME}" -- nvidia-smi

  echo; echo "==> [2/2] KV-cache evidence from startup logs"
  echo "\$ kubectl logs -n ${NAMESPACE} deploy/${DEPLOY_NAME} | grep -iE 'Available KV cache memory|GPU KV cache size|Maximum concurrency'"
  kubectl logs -n "${NAMESPACE}" "deploy/${DEPLOY_NAME}" 2>&1 \
    | grep -iE "Available KV cache memory|GPU KV cache size|Maximum concurrency" \
    | tail -3 || echo "No KV-cache log lines matched."
done