resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

locals {
  poc_tag_name = "eks-elastic-llm"
  workload_tag_name = "llm-inference-gateway"
  naming_suffix = random_string.suffix.result
  eks_cluster_name = "${var.cluster_name}-${local.naming_suffix}"
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      managed_by        = "Terraform"
      eks_cluster_name  = local.eks_cluster_name
      poc               = local.poc_tag_name
      workload          = local.workload_tag_name
      naming_suffix     = local.naming_suffix
    }
  }
}

resource "aws_resourcegroups_group" "cluster_resources" {
  name        = "${local.poc_tag_name}-${local.workload_tag_name}-resource-group"
  description = "Resource group tracking all AWS resources"

  resource_query {
    query = jsonencode({
      ResourceTypeFilters = ["AWS::AllSupported"]
      TagFilters = [
        {
          Key    = "poc"
          Values = [local.poc_tag_name]
        },
        {
          Key    = "function"
          Values = [local.workload_tag_name]
        }
      ]
    })
  }
}

# The Kubernetes provider authenticates using an exec token plugin.
# EKS tokens are short-lived (~15 min), and the exec plugin requests
# fresh tokens on-demand directly via the local AWS CLI/IAM session.
provider "kubernetes" {
  host                   = try(aws_eks_cluster.this.endpoint, null)
  cluster_ca_certificate = try(base64decode(aws_eks_cluster.this.certificate_authority[0].data), null)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      local.eks_cluster_name,
      "--region",
      var.aws_region
    ]
  }
}

provider "kubectl" {
  host                   = try(aws_eks_cluster.this.endpoint, null)
  cluster_ca_certificate = try(base64decode(aws_eks_cluster.this.certificate_authority[0].data), null)
  load_config_file       = false
  lazy_load              = true

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      local.eks_cluster_name,
      "--region",
      var.aws_region
    ]
  }
}

provider "helm" {
  kubernetes {
    host                   = try(aws_eks_cluster.this.endpoint, "")
    cluster_ca_certificate = try(base64decode(aws_eks_cluster.this.certificate_authority[0].data), "")

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks",
        "get-token",
        "--cluster-name",
        local.eks_cluster_name,
        "--region",
        var.aws_region
      ]
    }
  }
}