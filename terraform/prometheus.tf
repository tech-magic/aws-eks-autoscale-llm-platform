################################################################################
# 1. PROMETHEUS & GRAFANA MONITORING STACK (The Cluster's Nervous System)
# ------------------------------------------------------------------------------
# Why do we need this?
# To autoscale our AI models intelligently—and know if our GPUs are healthy—we
# need real-time visibility into how busy the system is:
#   - Prometheus: A time-series database that collects ("scrapes") live numbers
#     every 10 seconds (like how many users are waiting in line for an AI reply,
#     GPU temperature, and VRAM usage).
#   - Grafana: A visual dashboard website where you can view charts and graphs
#     of your AI throughput, latency, and GPU utilization.
#   - Alertmanager: Handles sending alerts (Slack/email) if something breaks.
################################################################################

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts" # Official Prometheus Helm repo
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring" # Keep all monitoring tools neatly in one namespace
  create_namespace = true
  version          = "65.5.0"     # Pin exact version for stability

  values = [
    yamlencode({
      # ------------------------------------------------------------------------
      # Step 1A: Turn Off AWS-Managed Control Plane Scrapers
      # ------------------------------------------------------------------------
      # Because AWS manages the Kubernetes "brain" (scheduler, etcd database,
      # controller manager) behind closed doors in EKS, Prometheus cannot reach
      # those internal components. Disabling them prevents false "target down"
      # alarms in Grafana.
      kubeControllerManager = { enabled = false }
      kubeScheduler         = { enabled = false }
      kubeEtcd              = { enabled = false }
      kubeProxy             = { enabled = false }

      # ------------------------------------------------------------------------
      # Step 1B: Configure Prometheus Data Collection & Autoscaling Math
      # ------------------------------------------------------------------------
      prometheus = {
        prometheusSpec = {
          # Check AI traffic metrics every 10 seconds (instead of the default 30s-60s)
          # so KEDA reacts rapidly when a sudden burst of AI requests arrives.
          scrapeInterval     = "10s"
          evaluationInterval = "10s"

          # Allow Prometheus to automatically discover "ServiceMonitors" (rules
          # telling it how to scrape services like the vLLM Router and NVIDIA GPU
          # Operator) across ALL Kubernetes namespaces, not just `monitoring`.
          serviceMonitorSelectorNilUsesHelmValues = false
          serviceMonitorNamespaceSelector         = {}

          # Allow Prometheus to automatically discover "PodMonitors" (rules for
          # scraping individual dynamic vLLM worker pods) across ALL namespaces.
          podMonitorSelectorNilUsesHelmValues = false
          podMonitorNamespaceSelector         = {}

          # Pin Prometheus onto our CPU-only "system" servers so it never gets
          # scheduled onto expensive GPU nodes or disrupted when GPUs scale down.
          nodeSelector = {
            workload = "system"
          }

          # ----------------------------------------------------------------------
          # Custom Recording Rule: Unified AI Demand Signal for Scale-From-Zero
          # ----------------------------------------------------------------------
          # Why is this clever?
          # When vLLM GPU pods are scaled down to 0 (to save money overnight),
          # `vllm:num_requests_waiting` doesn't exist yet because no GPU pods are
          # running!
          #
          # This rule creates a single, reliable metric (`vllm:keda_model_queue_depth`)
          # for KEDA to watch:
          #   1. First, check if active vLLM workers have requests waiting in queue.
          #   2. If workers are at 0, fall back to counting incoming requests held
          #      at the lightweight CPU vLLM Router (`vllm_router_active_requests`).
          #   3. If both are empty, report `0` so KEDA knows it's safe to sleep.
          additionalPrometheusRulesMap = {
            vllm-keda-rules = {
              groups = [
                {
                  name     = "vllm.autoscaling"
                  interval = "10s"
                  rules = [
                    {
                      record = "vllm:keda_model_queue_depth"
                      expr   = <<-EXPR
                        sum by (model) (vllm:num_requests_waiting)
                        or
                        sum by (model) (vllm_router_active_requests)
                        or vector(0)
                      EXPR
                    }
                  ]
                }
              ]
            }
          }
        }
      }

      # ------------------------------------------------------------------------
      # Step 1C: Configure Alertmanager & Grafana Dashboards
      # ------------------------------------------------------------------------
      alertmanager = {
        alertmanagerSpec = {
          # Keep Alertmanager running on our always-on CPU system servers
          nodeSelector = {
            workload = "system"
          }
        }
      }

      grafana = {
        enabled       = true
        adminPassword = var.grafana_password # Login password pulled from your .env file
        nodeSelector  = {
          workload = "system" # Keep Grafana running on CPU system servers
        }
      }
    })
  ]

  # Wait until the EKS cluster and CPU system servers are ready before installing
  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.system
  ]
}


################################################################################
# 2. VLLM WORKER METRICS SCRAPER (Kubernetes PodMonitor)
# ------------------------------------------------------------------------------
# Why do we need this?
# As Karpenter and KEDA spin vLLM GPU pods up and down dynamically, their IP
# addresses constantly change. A "PodMonitor" tells Prometheus: "Automatically
# find any running pod in the `default` namespace labeled `vllm.ai/router-enabled=true`,
# visit its `/metrics` web page every 10 seconds, and record its performance."
################################################################################

resource "kubectl_manifest" "vllm_workers_monitor" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PodMonitor
    metadata:
      name: vllm-workers-monitor
      namespace: monitoring
    spec:
      # Look for vLLM worker pods inside the "default" namespace
      namespaceSelector:
        matchNames:
          - default

      # Only scrape pods carrying this specific label (ignores unrelated pods)
      selector:
        matchLabels:
          vllm.ai/router-enabled: "true"

      podMetricsEndpoints:
        - port: http        # Must match the named port ("http") on the vLLM container
          path: /metrics    # Standard Prometheus metrics endpoint exposed by vLLM
          interval: 10s     # Collect fresh queue & token throughput metrics every 10s

          # Label Cleanup (Relabeling):
          # Copies Kubernetes pod metadata labels onto the Prometheus metrics so we
          # can filter and autoscale each AI model (e.g., Llama-3 vs. Mistral) independently.
          relabelings:
            - sourceLabels: [__meta_kubernetes_pod_label_app]
              targetLabel: app
            - sourceLabels: [__meta_kubernetes_pod_label_vllm_ai_model]
              targetLabel: model
  YAML

  # Wait until Prometheus Operator is installed so Kubernetes recognizes `kind: PodMonitor`
  depends_on = [helm_release.kube_prometheus_stack]
}


################################################################################
# 3. KEDA AUTOSCALER (Event-Driven Pod Scaling & Scale-to-Zero)
# ------------------------------------------------------------------------------
# Why do we need this?
# Standard Kubernetes autoscalers only scale pods based on basic CPU or RAM usage,
# which doesn't work well for AI models (and cannot scale down to 0 pods).
#
# KEDA (Kubernetes Event-driven Autoscaling) bridges Prometheus and Kubernetes:
# - It continuously queries Prometheus for `vllm:keda_model_queue_depth`.
# - When requests arrive while pods = 0, KEDA wakes up a vLLM pod (0 -> 1),
#   which triggers Karpenter to boot a brand-new GPU server.
# - When traffic spikes, KEDA adds more vLLM pods (1 -> N).
# - When traffic stops, KEDA scales vLLM pods back to 0 so Karpenter can shut
#   down the expensive GPU servers.
################################################################################

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts" # Official KEDA Helm repository
  chart            = "keda"
  namespace        = "keda" # Isolate KEDA system components in their own namespace
  create_namespace = true
  version          = "2.14.0" # Pin exact version for stability

  # Wait until the EKS cluster and CPU system servers are ready before installing
  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.system
  ]
}