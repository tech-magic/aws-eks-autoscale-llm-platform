###############################
# IAM (required by Karpenter)
###############################

resource "aws_ec2_tag" "cluster_sg_karpenter" {
  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = local.eks_cluster_name
}

# Instance Role for nodes launched by Karpenter
resource "aws_iam_role" "karpenter_node_role" {
  name = "karpenter-node-role-${local.eks_cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_node_WorkerNode" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.karpenter_node_role.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_CNI" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.karpenter_node_role.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ECR" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.karpenter_node_role.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_SSM" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.karpenter_node_role.name
}

# Karpenter Controller Role (IRSA)
resource "aws_iam_role" "karpenter_controller" {
  name = "karpenter-controller-${local.eks_cluster_name}"

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
          "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:sub" = "system:serviceaccount:karpenter:karpenter"
          "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "karpenter_controller_policy" {
  name = "KarpenterControllerPolicy-${local.eks_cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEC2AndDiscovery"
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateTags",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
          "ec2:DeleteLaunchTemplate",
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ssm:GetParameter",
          "pricing:GetProducts"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowInstanceProfileRead"
        Effect = "Allow"
        Action = [
          "iam:GetInstanceProfile",
          "iam:ListInstanceProfiles"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowScopedInstanceProfileLifecycle"
        Effect = "Allow"
        Action = [
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:TagInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile"
        ]
        Resource = "arn:aws:iam::*:instance-profile/*"
      },
      {
        Sid      = "AllowPassNodeRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.karpenter_node_role.arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      },
      {
        Sid      = "AllowClusterEndpointLookup"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = aws_eks_cluster.this.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller_attach" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller_policy.arn
}

# Grant Karpenter Node Role access to join cluster (EKS Access Entry)
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.karpenter_node_role.arn
  type          = "EC2_LINUX"
}

##########################
## Karpenter Config
##########################

resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  namespace        = "karpenter"
  create_namespace = true
  version          = "1.0.6"
  wait             = true

  set {
    name  = "settings.clusterName"
    value = local.eks_cluster_name
  }

  set {
    name  = "settings.clusterEndpoint"
    value = aws_eks_cluster.this.endpoint
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter_controller.arn
  }

  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.system,
    aws_iam_role.karpenter_node_role,
    aws_iam_role.karpenter_controller,
    aws_eks_access_entry.karpenter_node,
    aws_ec2_tag.cluster_sg_karpenter
  ]
}

resource "kubectl_manifest" "gpu_nodeclass" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "gpu-nodes"
    }
    spec = {
      amiFamily = "AL2023"
      role      = aws_iam_role.karpenter_node_role.name
      amiSelectorTerms = [
        {
          alias = "al2023@latest"
        }
      ]
      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.eks_cluster_name
          }
        }
      ]
      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.eks_cluster_name
          }
        }
      ]
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            # Reduced from 150Gi to 80Gi since model weights now reside on EFS
            volumeSize          = "80Gi"
            volumeType          = "gp3"
            deleteOnTermination = true
          }
        }
      ]
    }
  })

  depends_on = [
    helm_release.karpenter,
    aws_iam_role_policy_attachment.karpenter_controller_attach
  ]
}

resource "kubectl_manifest" "gpu_nodepool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "gpu-pool"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            workload = "gpu"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "gpu-nodes"
          }
          requirements = [
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand", "spot"]
            },
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = ["g4dn.xlarge", "g4dn.2xlarge", "g5.xlarge", "g5.2xlarge"]
            }
          ]
          taints = [
            {
              key    = "nvidia.com/gpu"
              value  = "present"
              effect = "NoSchedule"
            }
          ]
        }
      }
      limits = {
        gpu = 8
      }
      disruption = {
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "2m"
      }
    }
  })

  depends_on = [kubectl_manifest.gpu_nodeclass]
}

# Ensures Karpenter terminates all dynamic GPU EC2 instances and releases ENIs
# BEFORE Terraform uninstalls Karpenter or attempts to delete the VPC.
resource "null_resource" "karpenter_node_cleanup" {
  triggers = {
    cluster_name = aws_eks_cluster.this.name
    region       = var.aws_region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      aws eks update-kubeconfig --region ${self.triggers.region} --name ${self.triggers.cluster_name} >/dev/null 2>&1 || exit 0
      kubectl delete nodeclaims --all --ignore-not-found=true --wait=true --timeout=180s || true
    EOT
  }

  depends_on = [
    helm_release.karpenter,
    kubectl_manifest.gpu_nodeclass,
    kubectl_manifest.gpu_nodepool
  ]
}