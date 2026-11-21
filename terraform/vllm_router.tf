resource "kubernetes_service_account_v1" "vllm_router" {
  metadata {
    name      = "vllm-router-sa"
    namespace = "default"
  }

  depends_on = [
    aws_eks_node_group.system
  ]
}

resource "kubernetes_role_v1" "vllm_router_pod_reader" {
  metadata {
    name      = "vllm-router-pod-reader"
    namespace = "default"
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "endpoints", "services"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "vllm_router_pod_reader" {
  metadata {
    name      = "vllm-router-pod-reader-binding"
    namespace = "default"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.vllm_router_pod_reader.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.vllm_router.metadata[0].name
    namespace = kubernetes_service_account_v1.vllm_router.metadata[0].namespace
  }
}

resource "kubernetes_deployment_v1" "vllm_router" {
  metadata {
    name      = "vllm-router"
    namespace = "default"
    labels = {
      app = "vllm-router"
    }
  }

  spec {
    replicas = 1

    # Use "RollingUpdate", if you want to create a new instance and remove the existing whenever you update the router.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        app = "vllm-router"
      }
    }

    template {
      metadata {
        labels = {
          app = "vllm-router"
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.vllm_router.metadata[0].name

        node_selector = {
          workload = "system"
        }

        container {
          name  = "router"
          image = "ghcr.io/vllm-project/production-stack/router:v0.1.14"

          args = [
            "--host", "0.0.0.0",
            "--port", "8000",
            "--service-discovery", "k8s",
            "--k8s-service-discovery-type", "pod-ip", # Discovers individual vLLM worker pod IPs directly
            "--k8s-namespace", "default",
            "--k8s-label-selector", "vllm.ai/router-enabled=true",
            "--k8s-port", "8000",
            "--routing-logic", "roundrobin", # Use "roundrobin" or "session" (for prefix/KV-cache affinity)
            "--session-key", "x-session-id",
            "--engine-stats-interval", "10",
            "--request-stats-window", "60",
          ]

          port {
            container_port = 8000
            name           = "http"
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "2"
              memory = "2Gi"
            }
          }
        }
      }
    }
  }

  depends_on = [
    aws_eks_node_group.system,
    kubernetes_role_binding_v1.vllm_router_pod_reader
  ]
}

resource "kubernetes_service_v1" "vllm_router" {
  metadata {
    name      = "vllm-router-service"
    namespace = "default"
    labels = {
      app = "vllm-router"
    }
    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-type"     = "nlb"
      "service.beta.kubernetes.io/aws-load-balancer-internal" = "true"
    }
  }

  spec {
    type = "LoadBalancer"

    selector = {
      app = kubernetes_deployment_v1.vllm_router.spec[0].template[0].metadata[0].labels.app
    }

    port {
      name        = "http"
      port        = 80
      target_port = 8000
    }
  }

  depends_on = [
    kubernetes_deployment_v1.vllm_router
  ]
}

locals {
  vllm_nlb_hostname = try(kubernetes_service_v1.vllm_router.status[0].load_balancer[0].ingress[0].hostname, "")
  vllm_nlb_name     = local.vllm_nlb_hostname != "" ? split("-", split(".", local.vllm_nlb_hostname)[0])[0] : null
}

data "aws_lb" "vllm_router_nlb" {
  name = local.vllm_nlb_name

  depends_on = [kubernetes_service_v1.vllm_router]
}

data "aws_lb_listener" "vllm_router_nlb_http" {
  load_balancer_arn = data.aws_lb.vllm_router_nlb.arn
  port              = 80
}

resource "kubectl_manifest" "vllm_router_monitor" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "vllm-router-monitor"
      namespace = "monitoring"
    }
    spec = {
      namespaceSelector = {
        matchNames = ["default"]
      }
      selector = {
        matchLabels = {
          app = kubernetes_service_v1.vllm_router.metadata[0].labels.app
        }
      }
      endpoints = [
        {
          port     = "http"
          path     = "/metrics"
          interval = "10s"
        }
      ]
    }
  })

  depends_on = [helm_release.kube_prometheus_stack]
}