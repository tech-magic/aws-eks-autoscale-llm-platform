################################################################################
# TERRAFORM OUTPUTS (Your Post-Deployment Cheat Sheet)
# ------------------------------------------------------------------------------
# Why do we need this?
# Once Terraform finishes building all your cloud servers, networks, storage,
# and security doors in AWS, you need the exact web addresses, IDs, and commands
# to actually connect to them and test your AI models.
#
# These `output` blocks print a clean summary in your terminal at the end of
# `terraform apply` (and can be viewed anytime via `terraform output`).
################################################################################


################################################################################
# 1. KUBERNETES CLUSTER ACCESS (Connecting Your Laptop to EKS)
################################################################################

# Prints the exact name of your newly created Kubernetes cluster
output "eks_cluster_name" {
  description = "Name of the provisioned EKS cluster"
  value       = aws_eks_cluster.this.name
}

# Prints the direct internet web address (URL) of your Kubernetes control plane
output "eks_cluster_endpoint" {
  description = "Endpoint for the EKS Kubernetes API server"
  value       = aws_eks_cluster.this.endpoint
}

# Prints a ready-to-copy terminal command. Running this command updates your
# local `~/.kube/config` file so `kubectl` commands on your laptop talk
# directly to this new AWS EKS cluster.
output "configure_kubectl" {
  description = "AWS CLI command to update your local kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name}"
}


################################################################################
# 2. SHARED MODEL STORAGE (Amazon EFS Network Drive Details)
################################################################################

# Prints the unique AWS resource ID (e.g., "fs-0123456789abcdef0") of the
# shared network hard drive holding your downloaded Hugging Face AI models
output "efs_file_system_id" {
  description = "ID of the Amazon EFS file system used for shared model weights"
  value       = aws_efs_file_system.this.id
}

# Prints the internal AWS network address used by servers to mount the EFS drive
output "efs_dns_name" {
  description = "Regional DNS name of the EFS file system"
  value       = aws_efs_file_system.this.dns_name
}

# Prints the Kubernetes StorageClass name ("efs-sc") that acts as the blueprint
# for provisioning shared storage folders
output "efs_storage_class_name" {
  description = "Kubernetes StorageClass name backed by EFS"
  value       = kubernetes_storage_class_v1.efs_sc.metadata[0].name
}

# Prints the name of the shared storage claim ("vllm-models-pvc") that all
# vLLM GPU pods attach to so they can share cached AI models without re-downloading
output "vllm_models_pvc_name" {
  description = "ReadWriteMany PersistentVolumeClaim name for vLLM worker pods"
  value       = kubernetes_persistent_volume_claim_v1.vllm_models.metadata[0].name
}


################################################################################
# 3. PUBLIC AI API & AUTHENTICATION (Calling Your vLLM Models Securely)
################################################################################

# Prints the public OpenAI-compatible base URL (ending in "/v1").
# You can plug this URL directly into the official Python OpenAI SDK, LangChain,
# or curl commands (along with a Cognito Bearer token) to generate AI responses.
output "openai_api_base_url" {
  description = "Public OpenAI-compatible base_url protected by Cognito OAuth"
  value       = "${aws_apigatewayv2_api.openai_gateway.api_endpoint}/v1"
}

# Prints the AWS Cognito web address where your apps or scripts send their
# Client ID and Secret to exchange them for a temporary JWT access pass
output "cognito_oauth_token_endpoint" {
  description = "Cognito OAuth 2.0 /oauth2/token endpoint URL"
  value       = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.aws_region}.amazoncognito.com/oauth2/token"
}

# Prints the ID of the Cognito User Pool (the directory storing user accounts)
output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.this.id
}

# Prints the public App Client ID used when human users log in with an email
# and password (the interactive user flow)
output "cognito_user_client_id" {
  description = "Cognito App Client ID for sample user authentication"
  value       = aws_cognito_user_pool_client.user_client.id
}

# Prints the App Client ID used by automated backend services or scripts
# authenticating via the OAuth 2.0 Machine-to-Machine (`client_credentials`) flow
output "cognito_m2m_client_id" {
  description = "Cognito App Client ID for OAuth2 client_credentials flow"
  value       = aws_cognito_user_pool_client.m2m_client.id
}

# Prints the secret password paired with the Machine-to-Machine Client ID above.
# Marked `sensitive = true` so Terraform hides it from plain-text logs on screen;
# retrieve it when needed by running: `terraform output -raw cognito_m2m_client_secret`
output "cognito_m2m_client_secret" {
  description = "Cognito App Client Secret for OAuth2 client_credentials flow"
  value       = aws_cognito_user_pool_client.m2m_client.client_secret
  sensitive   = true
}