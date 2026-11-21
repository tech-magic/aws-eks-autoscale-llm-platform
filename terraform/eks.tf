################################################################################
# 1. IAM ROLES & PERMISSIONS (Security Badges for the Cluster & Servers)
# ------------------------------------------------------------------------------
# Why do we need this?
# In AWS, nothing is allowed to do anything by default. Before we build our
# Kubernetes cluster (EKS), we must create two "Digital ID Badges" (IAM Roles):
#   1. Cluster Role: Allows the AWS EKS control plane ("the brain") to manage
#      AWS networking and load balancers on your behalf.
#   2. Node Role: Allows the individual worker servers ("the muscle") to join
#      the cluster, configure network IP addresses, and download container images.
################################################################################

# ------------------------------------------------------------------------------
# Step 1A: Create the EKS Control Plane Role ("The Brain's ID Badge")
# ------------------------------------------------------------------------------
resource "aws_iam_role" "cluster" {
  name = "role-${local.eks_cluster_name}-cluster"

  # Trust Policy: Only allow the official AWS EKS service to wear this badge
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

# Attach AWS's standard permission checklist for managing an EKS cluster
resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

# ------------------------------------------------------------------------------
# Step 1B: Create the Worker Node Role ("The Servers' ID Badge")
# ------------------------------------------------------------------------------
resource "aws_iam_role" "nodes" {
  name = "role-${local.eks_cluster_name}-nodes"

  # Trust Policy: Only allow AWS EC2 virtual servers to wear this badge
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Permission 1: Allow EC2 servers to register themselves as Kubernetes worker nodes
resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.nodes.name
}

# Permission 2: Allow the networking plugin (VPC CNI) to assign internal IP
# addresses to every container ("pod") running on these servers
resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.nodes.name
}

# Permission 3: Allow servers to download ("pull") pre-built Docker container
# images from AWS Elastic Container Registry (ECR)
resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.nodes.name
}


################################################################################
# 2. EKS CONTROL PLANE (The Kubernetes "Brain")
# ------------------------------------------------------------------------------
# Creates the managed Kubernetes control plane. AWS runs and maintains the core
# Kubernetes API servers and database across multiple data centers for you.
################################################################################

resource "aws_eks_cluster" "this" {
  name     = local.eks_cluster_name
  role_arn = aws_iam_role.cluster.arn     # Link to the Cluster ID Badge from Step 1A
  version  = var.kubernetes_version       # Kubernetes software version (e.g., "1.31")

  # Network & Firewall Settings for talking to the Kubernetes API
  vpc_config {
    subnet_ids              = aws_subnet.public[*].id
    endpoint_public_access  = true # Allow running `kubectl` from your local laptop
    endpoint_private_access = true # Allow worker nodes inside AWS to talk privately

    # SECURITY LOCK: Even though the API endpoint is reachable over the internet,
    # AWS blocks every IP address on Earth EXCEPT your specific home/office IP.
    public_access_cidrs = [local.home_ip_cidr]
  }

  # Authentication Settings: Controls who has admin access to run `kubectl` commands
  access_config {
    # Support both modern AWS IAM Access Entries and legacy Kubernetes ConfigMaps
    authentication_mode = "API_AND_CONFIG_MAP"

    # Automatically grant full cluster administrator permissions to the AWS IAM
    # user/role that runs `terraform apply`
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Wait until the Cluster IAM permissions are attached before creating the cluster
  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy
  ]

  tags = {
    project = local.eks_cluster_name
  }
}


################################################################################
# 3. SYSTEM NODE GROUP (Dedicated CPU Servers for Core Infrastructure)
# ------------------------------------------------------------------------------
# Why do we need a separate "System" node group?
# Expensive GPU servers should be reserved strictly for running AI models.
# Meanwhile, Kubernetes needs always-on CPU servers to run background management
# tools (DNS, networking, Prometheus monitoring, Karpenter, and Autoscalers).
# Keeping them separate ensures AI traffic spikes never crash core cluster tools.
################################################################################

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.nodes.arn   # Link to the Worker Node badge from Step 1B
  subnet_ids      = aws_subnet.public[*].id

  # Server Hardware & Operating System Specs
  instance_types = [var.system_instance_type] # Standard CPU server (e.g., m6i.large)
  capacity_type  = "ON_DEMAND"                # Reliable, non-interruptible servers
  ami_type       = "AL2023_x86_64_STANDARD"   # Amazon Linux 2023 optimized for EKS
  disk_size      = 80                         # 80 GB root hard drive per server

  # Auto-Scaling Boundaries (Managed by Cluster Autoscaler)
  scaling_config {
    desired_size = 1 # Start with 1 server initially
    min_size     = 1 # Never go below 1 server (keeps cluster alive)
    max_size     = 3 # Grow up to 3 servers if Prometheus/controllers need more RAM/CPU
  }

  # Kubernetes Label: Lets infrastructure pods (like Cluster Autoscaler & CoreDNS)
  # specifically request to run on these "workload=system" servers
  labels = {
    workload = "system"
  }

  # AWS Tags: Required so the Kubernetes Cluster Autoscaler automatically discovers
  # this server group and knows it has permission to scale it between 1 and 3 nodes
  tags = {
    project                                               = local.eks_cluster_name
    "k8s.io/cluster-autoscaler/enabled"                   = "true"
    "k8s.io/cluster-autoscaler/${local.eks_cluster_name}" = "owned"
  }

  # Terraform Drift Protection: Once created, let the Cluster Autoscaler dynamically
  # adjust the live server count (1 to 3) without Terraform resetting it back to 1
  # on future `terraform apply` runs.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  # Wait until all 3 worker node IAM permissions are attached before launching servers
  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly
  ]
}


################################################################################
# 4. HUGGING FACE API TOKEN SECRET (Secure Storage for Model Downloads)
# ------------------------------------------------------------------------------
# Gated AI models (like Meta's Llama-3) require a Hugging Face account token to
# download. Storing it as a Kubernetes Secret keeps your token encrypted at rest
# and injects it safely into vLLM pods as an environment variable.
################################################################################

resource "kubernetes_secret" "hf_token" {
  metadata {
    name      = "hf-token-secret"
    namespace = "default"
  }

  data = {
    # Terraform's Kubernetes provider automatically base64-encodes this value
    HF_TOKEN = var.huggingface_token
  }

  type = "Opaque" # Standard generic key-value secret type

  # Wait until the cluster and at least one system server are online before creating
  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.system
  ]
}


################################################################################
# 5. OIDC IDENTITY PROVIDER (The Security Bridge for IRSA)
# ------------------------------------------------------------------------------
# Why do we need this?
# This connects Kubernetes's internal identity system to AWS IAM. It allows
# individual Kubernetes pods (like Cluster Autoscaler, Karpenter, and the EFS
# Storage Driver) to prove their identity to AWS and receive temporary, scoped
# AWS credentials ("IRSA" - IAM Roles for Service Accounts).
################################################################################

# Step 5A: Fetch the public TLS security certificate from our EKS cluster's
# built-in OpenID Connect (OIDC) URL so AWS can verify its authenticity
data "tls_certificate" "cluster" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

# Step 5B: Register our EKS cluster as a trusted identity issuer inside AWS IAM
resource "aws_iam_openid_connect_provider" "this" {
  # Allow tokens issued for the AWS Security Token Service (STS)
  client_id_list = ["sts.amazonaws.com"]

  # Pin the cryptographic fingerprint of our cluster's certificate to prevent spoofing
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]

  # The unique web address of this EKS cluster's identity service
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}