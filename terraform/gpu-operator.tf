resource "helm_release" "gpu_operator" {
  name             = "gpu-operator"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  version          = "v26.3.2"
  namespace        = "gpu-operator"
  create_namespace = true

  # AWS EKS NVIDIA AMIs come pre-baked with both the NVIDIA kernel driver
  # AND the NVIDIA Container Toolkit configured in containerd.
  set {
    name  = "driver.enabled"
    value = "false"
  }
  set {
    name  = "toolkit.enabled"
    value = "false"
  }

  # Match the taint applied by your Karpenter GPU NodePool
  set {
    name  = "daemonsets.tolerations[0].key"
    value = "nvidia.com/gpu"
  }
  set {
    name  = "daemonsets.tolerations[0].value"
    value = "present"
  }
  set {
    name  = "daemonsets.tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "daemonsets.tolerations[0].effect"
    value = "NoSchedule"
  }

  # Depend on the system node group (where the GPU Operator controller runs)
  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.system
  ]
}