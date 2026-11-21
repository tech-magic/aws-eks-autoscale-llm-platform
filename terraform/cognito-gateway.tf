################################################################################
# 1. AWS COGNITO OAUTH 2.0 SETUP (Authentication & User Directory)
# ------------------------------------------------------------------------------
# Why do we need this?
# Our AI models (vLLM) are expensive to run on GPUs, so we cannot leave our
# public internet endpoint wide open for anyone to use for free.
#
# AWS Cognito acts as our "Bouncer" or "ID Check System":
# - It stores user accounts and passwords.
# - It issues temporary digital passes (JWT access tokens) to verified users
#   and automated backend apps.
# - Only requests carrying a valid Cognito pass can reach our AI models.
################################################################################

# ------------------------------------------------------------------------------
# Step 1A: Create the User Pool (The "Member Directory")
# ------------------------------------------------------------------------------
resource "aws_cognito_user_pool" "this" {
  # Name of the directory holding all authorized users for this cluster
  name = "${local.eks_cluster_name}-users"

  # Users will log in using their email address as their username
  username_attributes = ["email"]

  # Automatically verify email addresses when accounts are created
  auto_verified_attributes = ["email"]

  # Enforce strong password rules so accounts cannot be easily guessed
  password_policy {
    minimum_length    = 8    # At least 8 characters long
    require_lowercase = true # Must contain a-z
    require_numbers   = true # Must contain 0-9
    require_symbols   = true # Must contain !@#$%, etc.
    require_uppercase = true # Must contain A-Z
  }
}

# ------------------------------------------------------------------------------
# Step 1B: Create the Hosted Login & Token Web Address (Cognito Domain)
# ------------------------------------------------------------------------------
# Creates a dedicated AWS URL (https://llm-gateway-...auth.us-east-1.amazoncognito.com)
# where users and apps send their credentials to exchange them for access tokens.
resource "aws_cognito_user_pool_domain" "this" {
  domain       = "llm-gateway-${local.naming_suffix}-auth"
  user_pool_id = aws_cognito_user_pool.this.id
}

# ------------------------------------------------------------------------------
# Step 1C: Define the Protected Resource & Permission Scope
# ------------------------------------------------------------------------------
# Registers our vLLM API as a protected service inside Cognito and defines a
# custom permission badge ("scope") called "inference". Without this specific
# permission in their token, a user cannot generate text from the LLM.
resource "aws_cognito_resource_server" "llm_api" {
  identifier   = "https://llm-api.${local.eks_cluster_name}.local"
  name         = "vLLM OpenAI API"
  user_pool_id = aws_cognito_user_pool.this.id

  scope {
    scope_name        = "inference"
    scope_description = "Invoke OpenAI-compatible vLLM inference endpoints"
  }
}

# ------------------------------------------------------------------------------
# Step 1D: App Client #1 — Interactive Human User Login
# ------------------------------------------------------------------------------
# Configures how human users (via a web browser, CLI, or Python OpenAI SDK)
# log in with an email and password to get a temporary token.
resource "aws_cognito_user_pool_client" "user_client" {
  name         = "${local.eks_cluster_name}-user-client"
  user_pool_id = aws_cognito_user_pool.this.id

  # Public apps (like browser frontends or local scripts) cannot safely hide a
  # secret key, so we disable client secrets here and rely on user passwords.
  generate_secret = false

  # Enable standard OAuth 2.0 browser login flows
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]

  # Grant access to basic user profile info + our custom vLLM "inference" permission
  allowed_oauth_scopes = [
    "openid",
    "email",
    "profile",
    "${aws_cognito_resource_server.llm_api.identifier}/inference"
  ]

  supported_identity_providers = ["COGNITO"]

  # Where Cognito redirects the browser after a user finishes logging in locally
  callback_urls = ["http://localhost:8080/callback"]

  # Allow direct username/password logins from CLI scripts and token refresh
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH", # Direct email + password login
    "ALLOW_REFRESH_TOKEN_AUTH", # Renew expired tokens without re-typing password
    "ALLOW_USER_SRP_AUTH"       # Secure Remote Password (encrypted password check)
  ]
}

# ------------------------------------------------------------------------------
# Step 1E: App Client #2 — Machine-to-Machine (Automated Backend Services)
# ------------------------------------------------------------------------------
# Configures how automated scripts, microservices, or API backends authenticate
# WITHOUT a human typing an email/password. They use a Client ID + Client Secret
# (the "client_credentials" flow) against the /oauth2/token endpoint.
resource "aws_cognito_user_pool_client" "m2m_client" {
  name         = "${local.eks_cluster_name}-m2m-client"
  user_pool_id = aws_cognito_user_pool.this.id

  # Generate a high-security Client Secret password for backend services
  generate_secret = true

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]

  # Grant permission strictly to call the vLLM inference API
  allowed_oauth_scopes         = ["${aws_cognito_resource_server.llm_api.identifier}/inference"]
  supported_identity_providers = ["COGNITO"]
}

# ------------------------------------------------------------------------------
# Step 1F: Create a Ready-to-Use Demo User Account
# ------------------------------------------------------------------------------
# Automatically provisions a test user account so you can immediately test
# logging in and calling the LLM API without manual setup in the AWS Console.
resource "aws_cognito_user" "demo_user" {
  user_pool_id = aws_cognito_user_pool.this.id
  username     = var.demo_user_email

  attributes = {
    email          = var.demo_user_email
    email_verified = "true" # Skip email verification code step for immediate use
  }

  password = var.demo_user_password
}


################################################################################
# 2. PUBLIC API GATEWAY + PRIVATE VPC LINK (The Front Door & Secure Tunnel)
# ------------------------------------------------------------------------------
# Why do we need this?
# Our Kubernetes GPU servers sit inside a private network (VPC) hidden from the
# public internet for security.
#
# API Gateway acts as the public "Front Door" on the internet:
# 1. It receives incoming OpenAI-compatible requests (e.g., /v1/chat/completions).
# 2. It checks the user's Cognito JWT token to verify they are allowed in.
# 3. It forwards approved traffic through an encrypted private tunnel ("VPC Link")
#    directly to our internal Kubernetes vLLM Router load balancer.
################################################################################

# ------------------------------------------------------------------------------
# Step 2A: Firewall Rules for the Private Tunnel (Security Group)
# ------------------------------------------------------------------------------
resource "aws_security_group" "vpc_link" {
  name        = "${local.eks_cluster_name}-vpclink-sg"
  description = "Security group for API Gateway VPC Link to internal vLLM Router NLB"
  vpc_id      = aws_vpc.this.id

  # Outbound Firewall Rule: Allow the VPC Link tunnel to send HTTP traffic (port 80)
  # ONLY to destinations inside our private VPC network.
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
}

# ------------------------------------------------------------------------------
# Step 2B: Build the Private Tunnel (VPC Link)
# ------------------------------------------------------------------------------
# Creates a managed AWS network bridge connecting the public API Gateway into
# our private VPC subnets so it can reach internal Kubernetes load balancers.
resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${local.eks_cluster_name}-vpclink"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = aws_subnet.public[*].id
}

# ------------------------------------------------------------------------------
# Step 2C: Create the Public HTTP API Gateway (The "Front Door")
# ------------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "openai_gateway" {
  name          = "${local.eks_cluster_name}-openai-gateway"
  protocol_type = "HTTP" # Fast, low-latency, cost-effective HTTP API

  # CORS (Cross-Origin Resource Sharing) rules:
  # Allows web browsers running frontends (like ChatGPT-style UIs) on any domain
  # to call this API and send Authorization tokens and session headers.
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Authorization", "Content-Type", "x-session-id"]
  }
}

# ------------------------------------------------------------------------------
# Step 2D: Attach the Security Guard (Cognito JWT Authorizer)
# ------------------------------------------------------------------------------
# Inspects the "Authorization: Bearer <token>" header on every incoming request.
# If the token is missing, expired, fake, or issued by another system, API
# Gateway immediately blocks the request (401 Unauthorized) before it ever
# touches our GPU servers.
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.openai_gateway.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito-oauth-authorizer"

  jwt_configuration {
    # Accept tokens issued to EITHER our human user app OR our machine-to-machine app
    audience = [
      aws_cognito_user_pool_client.user_client.id,
      aws_cognito_user_pool_client.m2m_client.id
    ]
    # Verify the token was genuinely signed by our Cognito User Pool
    issuer = "https://${aws_cognito_user_pool.this.endpoint}"
  }
}

# ------------------------------------------------------------------------------
# Step 2E: Connect the Front Door to the Internal vLLM Router (Integration)
# ------------------------------------------------------------------------------
# Tells API Gateway where to forward approved requests: through our private
# VPC Link directly to the internal Network Load Balancer (NLB) fronting the
# Kubernetes vLLM router.
resource "aws_apigatewayv2_integration" "vllm_router" {
  api_id             = aws_apigatewayv2_api.openai_gateway.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = data.aws_lb_listener.vllm_router_nlb_http.arn
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.this.id
}

# ------------------------------------------------------------------------------
# Step 2F: Define the URL Paths (OpenAI-Compatible Routes)
# ------------------------------------------------------------------------------
# Catches all requests starting with "/v1/" (such as /v1/chat/completions,
# /v1/completions, and /v1/models), forces them through the Cognito JWT check,
# and proxies them cleanly to vLLM.
resource "aws_apigatewayv2_route" "v1_proxy" {
  api_id             = aws_apigatewayv2_api.openai_gateway.id
  route_key          = "ANY /v1/{proxy+}" # Matches /v1/ followed by any sub-path
  target             = "integrations/${aws_apigatewayv2_integration.vllm_router.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# ------------------------------------------------------------------------------
# Step 2G: Publish the API Live ($default Stage)
# ------------------------------------------------------------------------------
# Makes the API active immediately at its root URL without requiring a path
# prefix like "/prod" or "/v1" in the base URL, and auto-publishes future edits.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.openai_gateway.id
  name        = "$default"
  auto_deploy = true
}