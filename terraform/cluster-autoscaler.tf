################################################################################
# 1. IAM PERMISSIONS (Security & Identity)
# ------------------------------------------------------------------------------
# Why do we need this?
# The Kubernetes "Cluster Autoscaler" is a background program running inside
# your cluster that adds or removes AWS EC2 servers (worker nodes) based on 
# demand. To add/remove servers in your AWS account, it needs permission.
#
# Instead of hardcoding risky AWS passwords/keys, we use "IRSA" (IAM Roles for 
# Service Accounts). Think of IRSA as a temporary, strictly scoped digital ID 
# badge given ONLY to the Cluster Autoscaler program inside Kubernetes.
################################################################################

# ------------------------------------------------------------------------------
# Step 1A: Create the AWS IAM Role (The "Digital ID Badge")
# ------------------------------------------------------------------------------
resource "aws_iam_role" "cluster_autoscaler" {
  # Give the role a clear, unique name tied to this specific EKS cluster
  name = "cluster-autoscaler-${local.eks_cluster_name}"

  # The "Trust Policy" defines WHO is allowed to wear this ID badge.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        # Trust the EKS cluster's built-in identity provider (OIDC) to verify identities
        Federated = aws_iam_openid_connect_provider.this.arn
      }
      # Allow Kubernetes to exchange its internal token for temporary AWS credentials
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # SECURITY LOCK 1: Only allow the specific Kubernetes ServiceAccount named
          # "cluster-autoscaler" living in the "kube-system" namespace to use this role.
          "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
          
          # SECURITY LOCK 2: Ensure the token is strictly meant for AWS Security Token Service (STS)
          "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# ------------------------------------------------------------------------------
# Step 1B: Create the IAM Policy (The "Permission Checklist")
# ------------------------------------------------------------------------------
# Now that the Autoscaler has an ID badge, this policy defines WHAT actions 
# that badge actually allows it to perform inside AWS.
resource "aws_iam_policy" "cluster_autoscaler" {
  name = "ClusterAutoscalerPolicy-${local.eks_cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # RULE 1: Read-Only Visibility
        # Allow the autoscaler to inspect EC2 server types, Auto Scaling Groups,
        # and EKS node groups so it can calculate CPU/RAM capacity and plan scaling.
        Sid    = "AllowAutoscalingRead"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ]
        Resource = "*"
      },
      {
        # RULE 2: Scoped Write Access (Adding & Removing Servers)
        # Allow changing the number of servers or shutting down empty servers.
        Sid    = "AllowScopedAutoscalingWrite"
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",            # Scale UP (add servers)
          "autoscaling:TerminateInstanceInAutoScalingGroup" # Scale DOWN (remove idle servers)
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            # SAFETY GUARDRAIL: Prevent the autoscaler from accidentally modifying or
            # deleting servers belonging to OTHER clusters or unrelated AWS projects.
            # It can ONLY touch Auto Scaling Groups tagged as "owned" by this cluster.
            "aws:ResourceTag/k8s.io/cluster-autoscaler/${local.eks_cluster_name}" = "owned"
          }
        }
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# Step 1C: Attach the Policy to the Role
# ------------------------------------------------------------------------------
# Links the "Permission Checklist" (Policy) to the "Digital ID Badge" (Role).
resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}


################################################################################
# 2. CLUSTER AUTOSCALER INSTALLATION (Kubernetes Helm Chart)
# ------------------------------------------------------------------------------
# Helm is like an "app store" or package manager for Kubernetes.
# This block installs the official Cluster Autoscaler software into our cluster
# and connects it to the AWS IAM Role we just created above.
################################################################################

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"                         # Release name inside Kubernetes
  repository = "https://kubernetes.github.io/autoscaler"    # Official Kubernetes Helm repo URL
  chart      = "cluster-autoscaler"                         # Name of the software package
  namespace  = "kube-system"                                # Install in the core system namespace
  version    = "9.43.2"                                     # Pin exact chart version for stability

  # Pass custom configuration settings into the Helm chart (converted to YAML)
  values = [
    yamlencode({
      # Automatically find all AWS Auto Scaling Groups tagged for this cluster
      autoDiscovery = {
        clusterName = local.eks_cluster_name
      }

      # Tell the autoscaler which AWS region our cluster lives in
      awsRegion = var.aws_region

      # Role-Based Access Control (RBAC) & AWS Identity Binding
      rbac = {
        serviceAccount = {
          create = true                 # Create the Kubernetes ServiceAccount
          name   = "cluster-autoscaler" # Must match the exact name in Step 1A's Trust Policy!
          annotations = {
            # Link this Kubernetes ServiceAccount to the AWS IAM Role created in Step 1A
            "eks.amazonaws.com/role-arn" = aws_iam_role.cluster_autoscaler.arn
          }
        }
      }

      # Pin the Cluster Autoscaler pod onto dedicated "system" servers so it never
      # gets evicted or disrupted when user application servers scale down.
      nodeSelector = {
        workload = "system"
      }

      # Fine-tuning flags that control how aggressively the autoscaler scales
      extraArgs = {
        # Keep server counts balanced evenly across multiple Availability Zones (data centers)
        balance-similar-node-groups = true

        # Allow scaling down servers even if they run standard Kubernetes system pods (like CoreDNS)
        skip-nodes-with-system-pods = false

        # Allow scaling down servers even if pods use temporary local disk storage
        skip-nodes-with-local-storage = false

        # When scaling up, pick the server group that wastes the least amount of idle CPU/RAM
        expander = "least-waste"

        # Wait 5 minutes before shutting down an underutilized/empty server (prevents rapid flapping)
        scale-down-unneeded-time = "5m"
      }
    })
  ]

  # Enforce creation order: Wait until the EKS cluster, the system worker nodes,
  # and the IAM permissions are 100% ready before installing this Helm chart.
  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.system,
    aws_iam_role_policy_attachment.cluster_autoscaler
  ]
}