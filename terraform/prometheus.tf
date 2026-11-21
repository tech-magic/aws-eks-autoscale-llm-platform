resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  version          = "65.5.0"

  values = [
    yamlencode({
      # Disable managed EKS control-plane components that aren't exposed as scrape targets
      kubeControllerManager = { enabled = false }
      kubeScheduler         = { enabled = false }
      kubeEtcd              = { enabled = false }
      kubeProxy             = { enabled = false }

      prometheus = {
        prometheusSpec = {
          # Fast scrape/evaluation intervals so KEDA reacts promptly to vLLM queue spikes
          scrapeInterval     = "10s"
          evaluationInterval = "10s"

          # Discover ServiceMonitors across all namespaces (e.g., vllm-router, gpu-operator)
          serviceMonitorSelectorNilUsesHelmValues = false
          serviceMonitorNamespaceSelector         = {}

          # Discover PodMonitors across all namespaces (for dynamic vLLM worker pods)
          podMonitorSelectorNilUsesHelmValues = false
          podMonitorNamespaceSelector         = {}

          # Optional: Keep Prometheus scheduled on your CPU system node group
          nodeSelector = {
            workload = "system"
          }

          additionalPrometheusRulesMap = {
            vllm-keda-rules = {
              groups = [
                {
                  name     = "vllm.autoscaling"
                  interval = "10s"
                  rules = [
                    {
                      # Unified demand signal per model: falls back to router metrics when workers are at 0
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

      alertmanager = {
        alertmanagerSpec = {
          nodeSelector = {
            workload = "system"
          }
        }
      }

      grafana = {
        enabled       = true
        adminPassword = var.grafana_password
        nodeSelector  = {
          workload = "system"
        }
      }
    })
  ]

  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.system
  ]
}

resource "kubectl_manifest" "vllm_workers_monitor" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PodMonitor
    metadata:
      name: vllm-workers-monitor
      namespace: monitoring
    spec:
      namespaceSelector:
        matchNames:
          - default
      selector:
        matchLabels:
          vllm.ai/router-enabled: "true"
      podMetricsEndpoints:
        - port: http # Must match the containerPort name on your vLLM worker pods
          path: /metrics
          interval: 10s
          relabelings:
            - sourceLabels: [__meta_kubernetes_pod_label_app]
              targetLabel: app
            - sourceLabels: [__meta_kubernetes_pod_label_vllm_ai_model]
              targetLabel: model
  YAML

  depends_on = [helm_release.kube_prometheus_stack]
}

# KEDA Helm Release
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  version          = "2.14.0"

  depends_on = [aws_eks_cluster.this, aws_eks_node_group.system]
}