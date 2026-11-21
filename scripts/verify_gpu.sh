#!/usr/bin/env bash
################################################################################
# GPU HARDWARE & KV-CACHE VERIFICATION SCRIPT (verify_gpu.sh)
# ------------------------------------------------------------------------------
# Why do we need this script?
# After deploying an AI model on Kubernetes, it's important to prove that the
# vLLM engine actually claimed the physical NVIDIA GPU card and allocated its
# high-speed memory (VRAM) properly—rather than falling back to slow CPU mode
# or crashing quietly.
#
# What this script does automatically:
#   1. Searches your Kubernetes cluster for EVERY vLLM AI deployment carrying
#      the tag `vllm.ai/router-enabled=true` (so you never have to hardcode
#      model deployment names).
#   2. Loops through each discovered AI deployment and runs `nvidia-smi`
#      directly inside the running container to show live GPU model, driver,
#      and VRAM memory usage.
#   3. Scans the container's startup logs to confirm how much GPU memory vLLM
#      reserved for its "KV-cache" (the short-term conversation memory that
#      makes AI replies fast) and how many simultaneous users it can serve.
################################################################################

# Strict Bash Safety Flags ("Fail Fast"):
# - `set -e`: Stop immediately if any critical command fails.
# - `set -u`: Treat unset/missing variables as an immediate error.
# - `set -o pipefail`: Catch failures occurring inside piped (`|`) commands.
set -euo pipefail

# ------------------------------------------------------------------------------
# Step 1: Configuration Settings (Overridable via Environment Variables)
# ------------------------------------------------------------------------------
# Look in the "default" Kubernetes namespace unless another is specified
NAMESPACE="${NAMESPACE:-default}"

# The exact Kubernetes label used to identify all router-enabled vLLM models
LABEL_SELECTOR='vllm.ai/router-enabled=true'

# Helper Function (`run`):
# Prints the exact `kubectl` command to your terminal (prefixed with `$`) before
# executing it, making the output easy to read, copy, or share in documentation.
run() {
  echo "\$ $*"
  "$@"
}

# ------------------------------------------------------------------------------
# Step 2: Dynamically Discover All vLLM Deployments in the Cluster
# ------------------------------------------------------------------------------
# Query Kubernetes for all Deployments matching `vllm.ai/router-enabled=true`,
# extract just their names using `jsonpath`, and store them safely in a bash
# array (`DEPLOYMENTS`). This `while read` loop works reliably on both macOS
# and Linux systems.
DEPLOYMENTS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && DEPLOYMENTS+=("$line")
done < <(kubectl get deployments -n "${NAMESPACE}" \
  -l "${LABEL_SELECTOR}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

# Safety Guardrail: If no matching vLLM deployments exist yet, print a clear
# error message and exit cleanly.
if [[ ${#DEPLOYMENTS[@]} -eq 0 ]]; then
  echo "Error: No deployments found in namespace '${NAMESPACE}' with label '${LABEL_SELECTOR}'." >&2
  exit 1
fi

echo "Found ${#DEPLOYMENTS[@]} deployment(s): ${DEPLOYMENTS[*]}"

# ------------------------------------------------------------------------------
# Step 3: Inspect GPU Memory & KV-Cache Allocation for Each Model
# ------------------------------------------------------------------------------
# Loop through every discovered vLLM deployment one by one
for DEPLOY_NAME in "${DEPLOYMENTS[@]}"; do
  echo; echo "=================================================="
  echo "==> Deployment: ${DEPLOY_NAME}"
  echo "=================================================="

  # Check 1 — Live GPU Hardware & VRAM Table (`nvidia-smi`):
  # Steps inside the running vLLM container (`kubectl exec`) and runs NVIDIA's
  # official system management tool. Look for:
  #   - GPU Name (e.g., Tesla T4 or NVIDIA A10G)
  #   - Memory-Usage (e.g., ~14,000MiB / 15,360MiB — vLLM pre-allocates ~88%
  #     of VRAM upfront for model weights + KV-cache)
  #   - Running python3/vllm process at the bottom of the table
  echo; echo "==> [1/2] GPU memory inside the pod (nvidia-smi)"
  run kubectl exec -n "${NAMESPACE}" "deploy/${DEPLOY_NAME}" -- nvidia-smi

  # Check 2 — KV-Cache & Concurrency Capacity from Startup Logs:
  # Searches the vLLM engine's boot logs (`kubectl logs`) for the exact lines
  # where vLLM calculates how many gigabytes of free VRAM are available for
  # conversation history ("KV cache size") and the maximum parallel user
  # sessions ("Maximum concurrency") the GPU can handle simultaneously.
  # Note: `|| echo "..."` prevents `set -e` from aborting the script if `grep`
  # finds zero matches (for instance, while a pod is still booting up).
  echo; echo "==> [2/2] KV-cache evidence from startup logs"
  echo "\$ kubectl logs -n ${NAMESPACE} deploy/${DEPLOY_NAME} | grep -iE 'Available KV cache memory|GPU KV cache size|Maximum concurrency'"
  kubectl logs -n "${NAMESPACE}" "deploy/${DEPLOY_NAME}" 2>&1 \
    | grep -iE "Available KV cache memory|GPU KV cache size|Maximum concurrency" \
    | tail -3 || echo "No KV-cache log lines matched."
done