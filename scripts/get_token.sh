#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-user}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")/terraform"

API_BASE=$(terraform -chdir="$TF_DIR" output -raw openai_api_base_url)
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

if [[ "$MODE" == "user" ]]; then
  if [[ -z "${TF_VAR_demo_user_email:-}" || -z "${TF_VAR_demo_user_password:-}" ]]; then
    echo "echo 'Error: TF_VAR_demo_user_email and TF_VAR_demo_user_password must be set in .env' >&2; exit 1"
    exit 1
  fi

  USER_CLIENT_ID=$(terraform -chdir="$TF_DIR" output -raw cognito_user_client_id)

  TOKEN=$(curl -s -X POST "https://cognito-idp.${AWS_REGION}.amazonaws.com/" \
    -H "Content-Type: application/x-amz-json-1.1" \
    -H "X-Amz-Target: AWSCognitoIdentityProviderService.InitiateAuth" \
    -d "{
      \"AuthFlow\": \"USER_PASSWORD_AUTH\",
      \"ClientId\": \"${USER_CLIENT_ID}\",
      \"AuthParameters\": {
        \"USERNAME\": \"${TF_VAR_demo_user_email}\",
        \"PASSWORD\": \"${TF_VAR_demo_user_password}\"
      }
    }" | jq -r '.AuthenticationResult.IdToken')

elif [[ "$MODE" == "m2m" ]]; then
  M2M_CLIENT_ID=$(terraform -chdir="$TF_DIR" output -raw cognito_m2m_client_id)
  M2M_SECRET=$(terraform -chdir="$TF_DIR" output -raw cognito_m2m_client_secret)
  TOKEN_ENDPOINT=$(terraform -chdir="$TF_DIR" output -raw cognito_oauth_token_endpoint)

  TOKEN=$(curl -s -X POST "${TOKEN_ENDPOINT}" \
    -u "${M2M_CLIENT_ID}:${M2M_SECRET}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials" | jq -r '.access_token')
else
  echo "echo 'Usage: eval \"\$(./scripts/get_token.sh [user|m2m])\"' >&2; exit 1"
  exit 1
fi

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "echo 'Failed to retrieve authentication token from Cognito.' >&2; exit 1"
  exit 1
fi

echo "export OPENAI_API_BASE=\"${API_BASE}\""
echo "export OPENAI_API_KEY=\"${TOKEN}\""
echo "echo 'Authenticated (${MODE} mode). Token prefix: ${TOKEN:0:20}...'"