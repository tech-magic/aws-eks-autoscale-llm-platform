################################################################################
# 1. AMAZON EFS FILE SYSTEM & NETWORKING (Shared Network Hard Drive)
# ------------------------------------------------------------------------------
# Why do we need this?
# Large Language Models (LLMs) like Llama-3 are huge files (tens of gigabytes).
# If every new GPU server had to download the model from Hugging Face over the
# internet every time it booted up, scaling up would be slow and expensive.
#
# Amazon EFS (Elastic File System) acts like a shared network hard drive:
# - We download the AI model weights ONCE into EFS.
# - Whenever new GPU pods spin up, they instantly attach to this shared drive
#   and read the cached model files at high speed without re-downloading.
################################################################################

# ------------------------------------------------------------------------------
# Step 1A: Create the Shared Cloud Hard Drive (EFS File System)
# ------------------------------------------------------------------------------
resource "aws_efs_file_system" "this" {
  # A unique ID token that ensures Terraform doesn't accidentally create duplicate drives
  creation_token = "${local.eks_cluster_name}-efs"

  # Encrypt all stored AI model files at rest for security
  encrypted = true

  # "generalPurpose" provides the lowest latency for normal file operations
  performance_mode = "generalPurpose"

  # "elastic" automatically bursts read speeds up to 3 GiB/s when multiple GPU
  # servers boot up simultaneously and load model weights into VRAM ("cold starts"),
  # then scales back down when idle so you only pay for what you use.
  throughput_mode = "elastic"

  tags = {
    Name    = "efs-${local.eks_cluster_name}"
    project = local.eks_cluster_name
  }
}

# ------------------------------------------------------------------------------
# Step 1B: Firewall Rules for the Shared Drive (Security Group)
# ------------------------------------------------------------------------------
resource "aws_security_group" "efs" {
  name        = "${local.eks_cluster_name}-efs-sg"
  description = "Allow NFS (2049) inbound from EKS cluster and Karpenter nodes"
  vpc_id      = aws_vpc.this.id

  # Inbound Firewall Rule: Network file drives communicate using the NFS protocol
  # on port 2049. Only allow servers inside our EKS cluster to connect to it.
  ingress {
    description     = "NFS from EKS cluster security group"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]
  }

  # Outbound Firewall Rule: Allow EFS to send responses back to connected servers
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "sg-${local.eks_cluster_name}-efs"
    project = local.eks_cluster_name
  }
}

# ------------------------------------------------------------------------------
# Step 1C: Create Network Plug-In Points (EFS Mount Targets)
# ------------------------------------------------------------------------------
# Think of Mount Targets as wall outlets in each data center (Availability Zone).
# Creating one in every subnet ensures that no matter which physical data center
# AWS launches a GPU server in, it has a local, high-speed connection to EFS.
resource "aws_efs_mount_target" "this" {
  count           = length(aws_subnet.public)
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = aws_subnet.public[count.index].id
  security_groups = [aws_security_group.efs.id]
}


################################################################################
# 2. IAM PERMISSIONS (IRSA for the EFS Storage Driver)
# ------------------------------------------------------------------------------
# Why do we need this?
# Kubernetes needs a plugin (the "EFS CSI Driver") to automatically mount and
# create folders on our AWS EFS drive. Using IRSA (IAM Roles for Service Accounts),
# we give that specific Kubernetes plugin a secure digital badge so it can talk
# to AWS EFS without hardcoded passwords.
################################################################################

# ------------------------------------------------------------------------------
# Step 2A: Create the AWS IAM Role (Digital ID Badge)
# ------------------------------------------------------------------------------
resource "aws_iam_role" "efs_csi" {
  name = "${local.eks_cluster_name}-efs-csi-driver-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        # Trust our EKS cluster's built-in identity provider (OIDC)
        Federated = aws_iam_openid_connect_provider.this.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # SECURITY LOCK: Restrict this badge strictly to the official EFS CSI
          # controller ServiceAccount running inside the "kube-system" namespace.
          "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:efs-csi-controller-sa"
          "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# ------------------------------------------------------------------------------
# Step 2B: Attach AWS's Official EFS Driver Permission Policy
# ------------------------------------------------------------------------------
# Grants the driver permission to create Access Points, tag volumes, and
# inspect EFS file systems on your behalf.
resource "aws_iam_role_policy_attachment" "efs_csi_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
  role       = aws_iam_role.efs_csi.name
}


################################################################################
# 3. EKS STORAGE ADD-ON & STORAGE CLASS (Connecting EFS to Kubernetes)
# ------------------------------------------------------------------------------
# Now that the AWS hardware (EFS) and permissions (IAM) exist, we install the
# driver inside Kubernetes and define a "StorageClass" blueprint that tells
# Kubernetes how to mount the drive onto AI containers.
################################################################################

# ------------------------------------------------------------------------------
# Step 3A: Install the AWS EFS CSI Driver Add-on
# ------------------------------------------------------------------------------
resource "aws_eks_addon" "efs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-efs-csi-driver"
  service_account_role_arn = aws_iam_role.efs_csi.arn # Link to our IAM Role from Step 2A

  # Wait until the cluster, system nodes, IAM policy, and network mount targets
  # are completely ready before installing the driver.
  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.system,
    aws_iam_role_policy_attachment.efs_csi_policy,
    aws_efs_mount_target.this
  ]
}

# ------------------------------------------------------------------------------
# Step 3B: Define the Storage Blueprint (Kubernetes StorageClass)
# ------------------------------------------------------------------------------
resource "kubernetes_storage_class_v1" "efs_sc" {
  metadata {
    name = "efs-sc" # The name pods will reference when requesting EFS storage
  }

  storage_provisioner = "efs.csi.aws.com"

  # "Immediate" creates the storage folder as soon as a claim is requested,
  # rather than waiting for a GPU pod to be scheduled first.
  volume_binding_mode = "Immediate"

  parameters = {
    # "efs-ap" (Access Point) automatically creates an isolated subfolder on EFS
    # with clean file ownership so containers don't hit "Permission Denied" errors.
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.this.id
    directoryPerms   = "755"  # Owner can read/write/execute; others can read/execute
    uid              = "1000" # Linux user ID inside the container that owns the files
    gid              = "1000" # Linux group ID inside the container that owns the files
  }

  # Performance & Security Tuning Options when mounting the network drive:
  mount_options = [
    "tls",           # Encrypt all data in transit between GPU servers and EFS
    "rsize=1048576", # Read 1 MiB chunks at a time (maximizes large AI model load speed)
    "wsize=1048576", # Write 1 MiB chunks at a time
    "hard",          # If EFS momentarily hiccups, pause and retry rather than corrupting data
    "timeo=600",     # Wait 60 seconds (600 deciseconds) before retrying a stalled request
    "retrans=2",     # Retry failed network packets twice before logging a timeout
    "noresvport"     # Use standard ephemeral TCP ports so reconnects work cleanly after drops
  ]

  depends_on = [
    aws_eks_addon.efs_csi
  ]
}


################################################################################
# 4. SHARED VLLM MODEL CACHE PVC (The Shared Storage Folder for AI Pods)
# ------------------------------------------------------------------------------
# A PersistentVolumeClaim (PVC) is a "storage request" inside Kubernetes.
# All of our vLLM GPU pods will attach this exact same PVC to their Hugging Face
# cache directory (/root/.cache/huggingface) so they share downloaded models.
################################################################################

resource "kubernetes_persistent_volume_claim_v1" "vllm_models" {
  metadata {
    name      = "vllm-models-pvc"
    namespace = "default"
    labels = {
      app = "vllm"
    }
  }

  spec {
    # "ReadWriteMany" (RWX) is the magic superpower of EFS:
    # Unlike standard EBS disks (which can only attach to ONE server at a time),
    # ReadWriteMany allows dozens of GPU pods across multiple servers to read and
    # write to the exact same folder simultaneously.
    access_modes = ["ReadWriteMany"]

    # Use the "efs-sc" blueprint we defined in Step 3B
    storage_class_name = kubernetes_storage_class_v1.efs_sc.metadata[0].name

    resources {
      requests = {
        # Note: EFS is serverless and grows/shrinks infinitely on its own, so you
        # are only billed for actual gigabytes stored. However, Kubernetes requires
        # a placeholder number here to validate the configuration.
        storage = "200Gi"
      }
    }
  }

  depends_on = [
    kubernetes_storage_class_v1.efs_sc
  ]
}