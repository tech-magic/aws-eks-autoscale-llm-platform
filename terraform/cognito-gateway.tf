###############################
# AWS Cognito OAuth 2.0 Setup
###############################

resource "aws_cognito_user_pool" "this" {
  name = "${local.eks_cluster_name}-users"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
  }
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = "llm-gateway-${local.naming_suffix}-auth"
  user_pool_id = aws_cognito_user_pool.this.id
}

resource "aws_cognito_resource_server" "llm_api" {
  identifier   = "https://llm-api.${local.eks_cluster_name}.local"
  name         = "vLLM OpenAI API"
  user_pool_id = aws_cognito_user_pool.this.id

  scope {
    scope_name        = "inference"
    scope_description = "Invoke OpenAI-compatible vLLM inference endpoints"
  }
}

# 1. Interactive / User OAuth App Client (for sample user login & OpenAI SDK)
resource "aws_cognito_user_pool_client" "user_client" {
  name         = "${local.eks_cluster_name}-user-client"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile", "${aws_cognito_resource_server.llm_api.identifier}/inference"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = ["http://localhost:8080/callback"]

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH"
  ]
}

# 2. Machine-to-Machine OAuth App Client (client_credentials grant -> /oauth2/token)
resource "aws_cognito_user_pool_client" "m2m_client" {
  name         = "${local.eks_cluster_name}-m2m-client"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["${aws_cognito_resource_server.llm_api.identifier}/inference"]
  supported_identity_providers         = ["COGNITO"]
}

# Sample Cognito User
resource "aws_cognito_user" "demo_user" {
  user_pool_id = aws_cognito_user_pool.this.id
  username     = var.demo_user_email

  attributes = {
    email          = var.demo_user_email
    email_verified = "true"
  }

  password = var.demo_user_password
}

###############################
# Public API Gateway + VPC Link
###############################

resource "aws_security_group" "vpc_link" {
  name        = "${local.eks_cluster_name}-vpclink-sg"
  description = "Security group for API Gateway VPC Link to internal vLLM Router NLB"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${local.eks_cluster_name}-vpclink"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = aws_subnet.public[*].id
}

resource "aws_apigatewayv2_api" "openai_gateway" {
  name          = "${local.eks_cluster_name}-openai-gateway"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Authorization", "Content-Type", "x-session-id"]
  }
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.openai_gateway.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito-oauth-authorizer"

  jwt_configuration {
    audience = [
      aws_cognito_user_pool_client.user_client.id,
      aws_cognito_user_pool_client.m2m_client.id
    ]
    issuer = "https://${aws_cognito_user_pool.this.endpoint}"
  }
}

resource "aws_apigatewayv2_integration" "vllm_router" {
  api_id             = aws_apigatewayv2_api.openai_gateway.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = data.aws_lb_listener.vllm_router_nlb_http.arn
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.this.id
}

# Authenticated OpenAI-compatible routes (/v1/chat/completions, /v1/models, /v1/completions)
resource "aws_apigatewayv2_route" "v1_proxy" {
  api_id             = aws_apigatewayv2_api.openai_gateway.id
  route_key          = "ANY /v1/{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.vllm_router.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.openai_gateway.id
  name        = "$default"
  auto_deploy = true
}