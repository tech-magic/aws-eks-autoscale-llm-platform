################################################################################
# 1. IAM PERMISSIONS & TAGGING (Security Badges Required by Karpenter)
# ------------------------------------------------------------------------------
# Why do we need this?
# Karpenter is an ultra-fast Kubernetes autoscaler built specifically for AWS.
# When an AI pod (vLLM) needs a graphics card (GPU) and none are available,
# Karpenter talks directly to AWS EC2 to rent a brand-new GPU server in seconds,
# and automatically shuts it down when the AI workload finishes to save money.
#
# To do this safely, we set up two distinct AWS IAM "Digital ID Badges":
#   1. Node Role: Worn by the new GPU servers themselves so they can join the
#      cluster and download AI container images.
#   2. Controller Role (IRSA): Worn by the Karpenter brain pod so it has
#      permission to buy, configure, and terminate EC2 servers on your behalf.
################################################################################

# ------------------------------------------------------------------------------
# Step 1A: Tag the Cluster Firewall so Karpenter Can Find It
# ------------------------------------------------------------------------------
# Karpenter discovers which network subnets and security groups (firewalls) to
# attach to new GPU servers by searching for the tag `karpenter.sh/discovery`.
resource "aws_ec2_tag" "cluster_sg_karpenter" {
  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = local.eks_cluster_name
}

# ------------------------------------------------------------------------------
# Step 1B: Create the GPU Worker Server ID Badge (Karpenter Node Role)
# ------------------------------------------------------------------------------
resource "aws_iam_role" "karpenter_node_role" {
  name = "karpenter-node-role-${local.eks_cluster_name}"

  # Trust Policy: Only allow AWS EC2 virtual servers to wear this badge
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Permission 1: Allow GPU servers to register as Kubernetes worker nodes
resource "aws_iam_role_policy_attachment" "karpenter_node_WorkerNode" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.karpenter_node_role.name
}

# Permission 2: Allow the networking plugin (CNI) to assign internal IPs to pods
resource "aws_iam_role_policy_attachment" "karpenter_node_CNI" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.karpenter_node_role.name
}

# Permission 3: Allow servers to download ("pull") Docker images from AWS ECR
resource "aws_iam_role_policy_attachment" "karpenter_node_ECR" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.karpenter_node_role.name
}

# Permission 4: Allow secure remote debugging/management via AWS Systems Manager
# (SSM) without needing open SSH ports or risky SSH key files
resource "aws_iam_role_policy_attachment" "karpenter_node_SSM" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.karpenter_node_role.name
}

# ------------------------------------------------------------------------------
# Step 1C: Create the Karpenter Brain ID Badge (IRSA Controller Role)
# ------------------------------------------------------------------------------
resource "aws_iam_role" "karpenter_controller" {
  name = "karpenter-controller-${local.eks_cluster_name}"

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
          # SECURITY LOCK: Restrict this badge strictly to the Kubernetes ServiceAccount
          # named "karpenter" inside the "karpenter" namespace.
          "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:sub" = "system:serviceaccount:karpenter:karpenter"
          "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# ------------------------------------------------------------------------------
# Step 1D: Define What Karpenter Is Allowed to Do in AWS (Controller Policy)
# ------------------------------------------------------------------------------
resource "aws_iam_policy" "karpenter_controller_policy" {
  name = "KarpenterControllerPolicy-${local.eks_cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # RULE 1: Launch, Inspect, and Terminate EC2 GPU Servers + Check Spot Prices
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
          "ec2:DescribeSpotPriceHistory", # Lets Karpenter pick the cheapest Spot GPU
          "ec2:DescribeSubnets",
          "ec2:DeleteLaunchTemplate",
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ssm:GetParameter", # Look up the latest official AWS EKS machine image IDs
          "pricing:GetProducts"
        ]
        Resource = "*"
      },
      {
        # RULE 2: Inspect IAM Instance Profiles (wrappers that attach roles to EC2s)
        Sid    = "AllowInstanceProfileRead"
        Effect = "Allow"
        Action = [
          "iam:GetInstanceProfile",
          "iam:ListInstanceProfiles"
        ]
        Resource = "*"
      },
      {
        # RULE 3: Create and clean up Instance Profiles for newly launched GPU servers
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
        # RULE 4: Hand the "Node Role" badge (Step 1B) to newly created EC2 servers
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
        # RULE 5: Look up our EKS cluster's API server address so new nodes know where to connect
        Sid      = "AllowClusterEndpointLookup"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = aws_eks_cluster.this.arn
      }
    ]
  })
}

# Attach the permission policy (Step 1D) to the Karpenter Controller role (Step 1C)
resource "aws_iam_role_policy_attachment" "karpenter_controller_attach" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller_policy.arn
}

# ------------------------------------------------------------------------------
# Step 1E: Authorize Karpenter GPU Nodes to Join Kubernetes (EKS Access Entry)
# ------------------------------------------------------------------------------
# Registers the Karpenter Node Role inside EKS's security whitelist so that
# whenever Karpenter boots up a new EC2 GPU server, Kubernetes immediately
# trusts it and lets it join the cluster as a worker node.
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.karpenter_node_role.arn
  type          = "EC2_LINUX"
}


################################################################################
# 2. KARPENTER INSTALLATION & GPU SCALING RULES
# ------------------------------------------------------------------------------
# Here we install the Karpenter software via Helm and give it two blueprints:
#   1. EC2NodeClass ("gpu-nodes"): Defines the AWS hardware & OS specs (disk
#      size, Amazon Linux 2023 image, network subnets, security groups).
#   2. NodePool ("gpu-pool"): Defines the business rules (which GPU models are
#      allowed, Spot vs. On-Demand pricing, spending caps, and shutdown timers).
################################################################################

# ------------------------------------------------------------------------------
# Step 2A: Install the Karpenter Controller Helm Chart
# ------------------------------------------------------------------------------
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter" # Official AWS ECR Public registry
  chart            = "karpenter"
  namespace        = "karpenter"
  create_namespace = true
  version          = "1.0.6"
  wait             = true # Wait until Karpenter pods are healthy before continuing

  # Tell Karpenter which EKS cluster it is managing
  set {
    name  = "settings.clusterName"
    value = local.eks_cluster_name
  }

  # Provide the direct API URL for our EKS cluster
  set {
    name  = "settings.clusterEndpoint"
    value = aws_eks_cluster.this.endpoint
  }

  # Bind the Karpenter Kubernetes ServiceAccount to our AWS IAM Role from Step 1C
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

# ------------------------------------------------------------------------------
# Step 2B: Define AWS Hardware & OS Blueprint (EC2NodeClass)
# ------------------------------------------------------------------------------
resource "kubectl_manifest" "gpu_nodeclass" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "gpu-nodes"
    }
    spec = {
      # Use Amazon Linux 2023 (pre-configured with NVIDIA drivers & containerd)
      amiFamily = "AL2023"
      role      = aws_iam_role.karpenter_node_role.name

      # Automatically select the latest official EKS-optimized AL2023 GPU image
      amiSelectorTerms = [
        {
          alias = "al2023@latest"
        }
      ]

      # Launch GPU servers in any subnet tagged with `karpenter.sh/discovery`
      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.eks_cluster_name
          }
        }
      ]

      # Attach any security group tagged with `karpenter.sh/discovery`
      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.eks_cluster_name
          }
        }
      ]

      # Configure the local boot disk for each GPU server
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            # 80 GB fast gp3 SSD is plenty because large AI model weights are
            # stored on our shared EFS network drive rather than local disk.
            volumeSize          = "80Gi"
            volumeType          = "gp3"
            deleteOnTermination = true # Automatically delete disk when node terminates
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

# ------------------------------------------------------------------------------
# Step 2C: Define GPU Scheduling, Cost & Shutdown Rules (NodePool)
# ------------------------------------------------------------------------------
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
          # Label all servers from this pool as `workload=gpu` so vLLM pods can target them
          labels = {
            workload = "gpu"
          }
        }
        spec = {
          # Link to the AWS hardware blueprint we defined in Step 2B
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "gpu-nodes"
          }

          # Server Selection Constraints:
          requirements = [
            {
              # Allow both discounted "spot" instances (up to 70% cheaper) and
              # guaranteed "on-demand" instances as a fallback if Spot capacity is scarce
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand", "spot"]
            },
            {
              # Restrict Karpenter to specific NVIDIA GPU server families:
              # - g4dn: NVIDIA T4 GPUs (great for smaller/quantized 7B-8B models)
              # - g5:   NVIDIA A10G GPUs (faster compute & 24GB VRAM for larger models)
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = ["g4dn.xlarge", "g4dn.2xlarge", "g5.xlarge", "g5.2xlarge"]
            }
          ]

          # "No Entry" Sign (Taint): Blocks regular CPU apps from accidentally running
          # on these expensive GPU servers. Only pods explicitly tolerating
          # `nvidia.com/gpu=present:NoSchedule` (like vLLM & GPU Operator) can land here.
          taints = [
            {
              key    = "nvidia.com/gpu"
              value  = "present"
              effect = "NoSchedule"
            }
          ]
        }
      }

      # BUDGET GUARDRAIL: Never provision more than 8 total GPUs across this pool
      limits = {
        gpu = 8
      }

      # AUTOMATIC SCALE-TO-ZERO (Cost Savings):
      # Once all vLLM AI pods finish their work and scale down to 0, wait 2 minutes
      # ("2m") to confirm no new requests arrive, then terminate the empty GPU server.
      disruption = {
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "2m"
      }
    }
  })

  depends_on = [kubectl_manifest.gpu_nodeclass]
}


################################################################################
# 3. TEARDOWN SAFETY HOOK (Graceful GPU Cleanup During `terraform destroy`)
# ------------------------------------------------------------------------------
# Why do we need this?
# Because GPU servers are created dynamically by Karpenter (not directly by
# Terraform), running `terraform destroy` would normally uninstall Karpenter
# first—leaving orphaned GPU EC2 instances and network interfaces (ENIs) stuck
# inside your VPC, which causes AWS VPC deletion to fail and hang.
#
# This hook runs automatically right before Terraform destroys Karpenter,
# deleting all active NodeClaims so Karpenter cleanly terminates every GPU
# server first.
################################################################################

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