# Elastic LLM Gateway on AWS EKS (vLLM + Cognito)

Deploy an auto-scaling, OpenAI-compatible LLM inference gateway on AWS EKS using **vLLM**, **Karpenter**, **Amazon EFS**, and **Amazon Cognito** authentication.

---

## Prerequisites

Ensure the following CLI tools are installed before starting:

| Tool | Purpose | Verification Command |
| :--- | :--- | :--- |
| **AWS CLI (v2)** | Interact with AWS services & EKS | `aws --version` |
| **Terraform (>= 1.5)** | Provision cloud infrastructure | `terraform -version` |
| **kubectl** | Manage Kubernetes deployments | `kubectl version --client` |
| **jq** & **curl** | Parse JSON tokens & test APIs | `jq --version` |
| **Python 3.9+** *(Optional)* | Run the OpenAI SDK example | `python3 --version` |

---

## Quickstart (Command-Line)

### 1. Configure Credentials
Copy the environment template and fill in your personal AWS keys, Hugging Face token, and desired passwords:

```bash
cp .env.example .env
# Open .env in your editor and replace all <YOUR_...> placeholders
set -a && source .env && set +a
```

> **Security Note:** Never commit your `.env` file to version control. Ensure `.env` is listed in your `.gitignore`.

### 2. Provision Infrastructure & Deploy LLM
Run the automated deployment script to create the EKS cluster, configure `kubectl`, and deploy the Llama-3.1 model:

```bash
chmod +x scripts/*.sh
./scripts/deploy.sh
```

Wait until the vLLM pod status reaches `Running` (this may take several minutes while Karpenter provisions GPU nodes and downloads model weights):

```bash
kubectl get pods -l app=vllm-llama3 -w
```

### 3. Authenticate & Generate an API Token
This gateway uses Amazon Cognito to issue short-lived JWT tokens in place of static OpenAI API keys. Load your `OPENAI_API_BASE` and `OPENAI_API_KEY` automatically into your shell:

```bash
# Option A: Authenticate as an End User (Default)
eval "$(./scripts/get_token.sh user)"

# Option B: Authenticate via Machine-to-Machine (M2M) OAuth2
eval "$(./scripts/get_token.sh m2m)"
```

### 4. Test the Endpoint

**List available models:**
```bash
curl -s "${OPENAI_API_BASE}/models" \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" | jq .
```

**Send a chat completion request:**
```bash
curl -s -X POST "${OPENAI_API_BASE}/chat/completions" \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  -H "Content-Type: application/json" \
  -H "x-session-id: llama-test-01" \
  -d '{
    "model": "llama-3.1-8b",
    "messages": [
      {"role": "system", "content": "You are a concise cloud architecture assistant."},
      {"role": "user", "content": "Explain how paged KV caching reduces GPU memory fragmentation in vLLM."}
    ],
    "temperature": 0.2,
    "max_tokens": 200
  }' | jq .
```

**Run the Python OpenAI SDK streaming test:**
```bash
pip install openai boto3
python3 scripts/test_inference.py
```

**Verify NVidia GPU Stats:**
```bash
./scripts/verify_gpu.sh
```

### 5. Cleanup

**Cleanup the entire EKS Cluster with vLLM Router (and any deployed LLMs) plus other external dependencies:**
```bash
./scripts/destroy.sh
```

---

## Troubleshooting

* **Check GPU Node Provisioning (Karpenter):** If pods stay in `Pending` state, inspect Karpenter logs:
  ```bash
  kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=100
  ```
* **Check Router Pods:**
  ```bash
  kubectl get pods,rs -l app=vllm-router -n default
  ```
* **Fix Terraform State Drift on `vllm_router`:** If Terraform fails to reconcile the router deployment:
  ```bash
  cd terraform
  terraform state rm kubernetes_deployment_v1.vllm_router
  terraform import kubernetes_deployment_v1.vllm_router default/vllm-router
  terraform apply
  ```