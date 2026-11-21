###############################
# EFS File System & Networking
###############################

resource "aws_efs_file_system" "this" {
  creation_token   = "${local.eks_cluster_name}-efs"
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic" # Scales up to 3 GiB/s read throughput for cold-start model loads

  tags = {
    Name    = "efs-${local.eks_cluster_name}"
    project = local.eks_cluster_name
  }
}

resource "aws_security_group" "efs" {
  name        = "${local.eks_cluster_name}-efs-sg"
  description = "Allow NFS (2049) inbound from EKS cluster and Karpenter nodes"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "NFS from EKS cluster security group"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]
  }

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

resource "aws_efs_mount_target" "this" {
  count           = length(aws_subnet.public)
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = aws_subnet.public[count.index].id
  security_groups = [aws_security_group.efs.id]
}

###############################
# IAM (IRSA for EFS CSI Driver)
###############################

resource "aws_iam_role" "efs_csi" {
  name = "${local.eks_cluster_name}-efs-csi-driver-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.this.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:efs-csi-controller-sa"
          "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "efs_csi_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
  role       = aws_iam_role.efs_csi.name
}

###############################
# EKS Add-on & StorageClass
###############################

resource "aws_eks_addon" "efs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-efs-csi-driver"
  service_account_role_arn = aws_iam_role.efs_csi.arn

  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.system,
    aws_iam_role_policy_attachment.efs_csi_policy,
    aws_efs_mount_target.this
  ]
}

resource "kubernetes_storage_class_v1" "efs_sc" {
  metadata {
    name = "efs-sc"
  }

  storage_provisioner = "efs.csi.aws.com"
  volume_binding_mode = "Immediate"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.this.id
    directoryPerms   = "755"
    uid              = "1000"
    gid              = "1000"
  }

  # Large NFS read/write buffers (1 MiB) maximize sequential model-weight read throughput
  mount_options = [
    "tls",
    "rsize=1048576",
    "wsize=1048576",
    "hard",
    "timeo=600",
    "retrans=2",
    "noresvport"
  ]

  depends_on = [
    aws_eks_addon.efs_csi
  ]
}

###############################
# Shared vLLM Model Cache PVC
###############################

resource "kubernetes_persistent_volume_claim_v1" "vllm_models" {
  metadata {
    name      = "vllm-models-pvc"
    namespace = "default"
    labels = {
      app = "vllm"
    }
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.efs_sc.metadata[0].name

    resources {
      requests = {
        # EFS scales automatically; this value is required by Kubernetes API validation
        storage = "200Gi"
      }
    }
  }

  depends_on = [
    kubernetes_storage_class_v1.efs_sc
  ]
}