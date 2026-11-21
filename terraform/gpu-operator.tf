################################################################################
# NVIDIA GPU OPERATOR (Enabling Kubernetes to See & Use Graphics Cards)
# ------------------------------------------------------------------------------
# Why do we need this?
# Out of the box, Kubernetes only knows how to schedule CPU and RAM. Even if
# Karpenter launches a powerful AWS GPU server (like an NVIDIA A10G or T4),
# Kubernetes won't recognize the graphics card or let AI pods use it.
#
# The NVIDIA GPU Operator automates GPU management inside Kubernetes:
# - It installs the "Device Plugin" that advertises available GPUs to Kubernetes
#   (allowing pods to request `nvidia.com/gpu: 1`).
# - It deploys "DCGM Exporter" to stream live GPU metrics (temperature, VRAM
#   usage, compute %) into Prometheus and Grafana.
# - It automatically labels GPU nodes with hardware details (model, VRAM size).
################################################################################

resource "helm_release" "gpu_operator" {
  name             = "gpu-operator"                       # Release name inside Kubernetes
  repository       = "https://helm.ngc.nvidia.com/nvidia" # Official NVIDIA Helm repository
  chart            = "gpu-operator"                       # Software package name
  version          = "v26.3.2"                            # Pin exact version for stability
  namespace        = "gpu-operator"                       # Isolate all GPU system pods here
  create_namespace = true                                 # Automatically create the namespace

  # ----------------------------------------------------------------------------
  # 1. Skip Redundant Driver & Container Toolkit Installations
  # ----------------------------------------------------------------------------
  # Normally, the GPU Operator tries to compile and install Linux GPU drivers
  # from scratch on every new server, which takes several minutes and slows down
  # autoscaling.
  #
  # Because our Karpenter GPU NodePool uses official AWS EKS NVIDIA-optimized
  # machine images (AMIs), both the low-level NVIDIA kernel driver and the
  # container runtime hooks are ALREADY pre-installed on the server. Turning
  # these off makes new GPU nodes ready for vLLM pods in seconds instead of minutes.
  set {
    name  = "driver.enabled"
    value = "false" # Use the pre-baked host NVIDIA driver instead of installing via container
  }

  set {
    name  = "toolkit.enabled"
    value = "false" # Use the pre-configured containerd NVIDIA toolkit on the host OS
  }

  # ----------------------------------------------------------------------------
  # 2. Permission Pass for "Tainted" GPU Servers (Tolerations)
  # ----------------------------------------------------------------------------
  # To prevent regular background apps (like CoreDNS or logging agents) from
  # accidentally landing on expensive GPU servers and wasting money, our Karpenter
  # GPU NodePool puts a "No Entry" sign (a Kubernetes Taint: `nvidia.com/gpu=present:NoSchedule`)
  # on every GPU node.
  #
  # However, the GPU Operator's own monitoring and discovery agents (DaemonSets)
  # MUST run on every GPU server to expose the graphics card to vLLM. These
  # four `tolerations` settings give NVIDIA's system agents a VIP pass to bypass
  # that "No Entry" sign and run on the GPU nodes.
  set {
    name  = "daemonsets.tolerations[0].key"
    value = "nvidia.com/gpu" # Must match the exact taint key on the GPU NodePool
  }

  set {
    name  = "daemonsets.tolerations[0].value"
    value = "present"        # Must match the exact taint value on the GPU NodePool
  }

  set {
    name  = "daemonsets.tolerations[0].operator"
    value = "Equal"          # Require an exact key=value match
  }

  set {
    name  = "daemonsets.tolerations[0].effect"
    value = "NoSchedule"     # Bypass the "NoSchedule" restriction
  }

  # ----------------------------------------------------------------------------
  # 3. Creation Order Dependencies
  # ----------------------------------------------------------------------------
  # Wait until the EKS cluster and the CPU-only "system" node group are online
  # before installing, because the main GPU Operator manager pod runs on the
  # system nodes while waiting for GPU nodes to spin up.
  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.system
  ]
}