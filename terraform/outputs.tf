output "eks_cluster_name" {
  description = "Name of the provisioned EKS cluster"
  value       = aws_eks_cluster.this.name
}

output "eks_cluster_endpoint" {
  description = "Endpoint for the EKS Kubernetes API server"
  value       = aws_eks_cluster.this.endpoint
}

output "configure_kubectl" {
  description = "AWS CLI command to update your local kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name}"
}

output "efs_file_system_id" {
  description = "ID of the Amazon EFS file system used for shared model weights"
  value       = aws_efs_file_system.this.id
}

output "efs_dns_name" {
  description = "Regional DNS name of the EFS file system"
  value       = aws_efs_file_system.this.dns_name
}

output "efs_storage_class_name" {
  description = "Kubernetes StorageClass name backed by EFS"
  value       = kubernetes_storage_class_v1.efs_sc.metadata[0].name
}

output "vllm_models_pvc_name" {
  description = "ReadWriteMany PersistentVolumeClaim name for vLLM worker pods"
  value       = kubernetes_persistent_volume_claim_v1.vllm_models.metadata[0].name
}

output "openai_api_base_url" {
  description = "Public OpenAI-compatible base_url protected by Cognito OAuth"
  value       = "${aws_apigatewayv2_api.openai_gateway.api_endpoint}/v1"
}

output "cognito_oauth_token_endpoint" {
  description = "Cognito OAuth 2.0 /oauth2/token endpoint URL"
  value       = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.aws_region}.amazoncognito.com/oauth2/token"
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.this.id
}

output "cognito_user_client_id" {
  description = "Cognito App Client ID for sample user authentication"
  value       = aws_cognito_user_pool_client.user_client.id
}

output "cognito_m2m_client_id" {
  description = "Cognito App Client ID for OAuth2 client_credentials flow"
  value       = aws_cognito_user_pool_client.m2m_client.id
}

output "cognito_m2m_client_secret" {
  description = "Cognito App Client Secret for OAuth2 client_credentials flow"
  value       = aws_cognito_user_pool_client.m2m_client.client_secret
  sensitive   = true
}
