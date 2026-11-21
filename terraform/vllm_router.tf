################################################################################
# 1. KUBERNETES RBAC PERMISSIONS (Letting the Router Discover GPU Pods)
# ------------------------------------------------------------------------------
# Why do we need this?
# Our vLLM GPU pods scale up and down dynamically (0 to N replicas), which means
# their internal IP addresses constantly change. Instead of hardcoding server
# addresses, the vLLM Router acts as a smart traffic receptionist: it watches
# Kubernetes in real time to see which AI worker pods are awake and ready.
#
# By default, Kubernetes blocks pods from inspecting the cluster. These three
# resources give the Router read-only permission to spot vLLM pods as they appear.
################################################################################

# ------------------------------------------------------------------------------
# Step 1A: Create the Router's Internal Identity (ServiceAccount)
# ------------------------------------------------------------------------------
resource "kubernetes_service_account_v1" "vllm_router" {
  metadata {
    name      = "vllm-router-sa"
    namespace = "default"
  }

  # Wait until the CPU system node group is online before creating Kubernetes objects
  depends_on = [
    aws_eks_node_group.system
  ]
}

# ------------------------------------------------------------------------------
# Step 1B: Define Read-Only Discovery Permissions (Role)
# ------------------------------------------------------------------------------
# Grants permission strictly to inspect ("get", "list", "watch") pods, network
# endpoints, and services inside the "default" namespace—nothing more.
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

# ------------------------------------------------------------------------------
# Step 1C: Attach the Permissions to the Router Identity (RoleBinding)
# ------------------------------------------------------------------------------
# Links the read-only Role (Step 1B) to the Router's ServiceAccount (Step 1A).
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


################################################################################
# 2. VLLM PRODUCTION STACK ROUTER (The Smart AI Traffic Controller)
# ------------------------------------------------------------------------------
# Why do we need this?
# The vLLM Router runs 24/7 on a cheap CPU server (`workload = "system"`) and
# acts as the single entry point for all OpenAI-compatible AI requests:
#   - Multi-Model Routing: Inspects the `"model": "..."` field in each API call
#     and forwards it to the matching vLLM worker deployment (e.g., Llama-3).
#   - Scale-From-Zero Buffering: When all GPU pods are asleep (0 replicas),
#     the router holds incoming requests and reports `vllm_router_active_requests`
#     to Prometheus—signaling KEDA to wake up a GPU node!
#   - Session / Cache Affinity: Can route follow-up chat messages from the same
#     user (`x-session-id`) to the exact GPU pod that already holds their
#     conversation's KV-cache in VRAM for faster responses.
################################################################################

resource "kubernetes_deployment_v1" "vllm_router" {
  metadata {
    name      = "vllm-router"
    namespace = "default"
    labels = {
      app = "vllm-router"
    }
  }

  spec {
    # Run 1 lightweight router instance (increase to 2+ for high availability)
    replicas = 1

    # Deployment Update Strategy:
    # - "Recreate" stops the old router pod before starting the updated one
    #   (prevents two routers from fighting over metrics/state during updates).
    # - Switch to "RollingUpdate" if you want zero-downtime router upgrades.
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
        # Run with the read-only ServiceAccount created in Step 1A
        service_account_name = kubernetes_service_account_v1.vllm_router.metadata[0].name

        # Pin this lightweight router onto our always-on CPU "system" servers
        # so it never consumes expensive GPU nodes
        node_selector = {
          workload = "system"
        }

        container {
          name  = "router"
          image = "ghcr.io/vllm-project/production-stack/router:v0.1.14"

          # Startup flags configuring how the router discovers and routes to vLLM pods:
          args = [
            "--host", "0.0.0.0",                           # Listen on all container network interfaces
            "--port", "8000",                              # Expose HTTP API and /metrics on port 8000
            "--service-discovery", "k8s",                  # Automatically find workers via Kubernetes API
            "--k8s-service-discovery-type", "pod-ip",      # Connect directly to individual vLLM pod IPs
            "--k8s-namespace", "default",                  # Watch for vLLM workers in the "default" namespace
            "--k8s-label-selector", "vllm.ai/router-enabled=true", # Only route to pods carrying this tag
            "--k8s-port", "8000",                          # Port where vLLM worker pods listen
            "--routing-logic", "roundrobin",               # Distribute traffic evenly ("session" enables KV-cache stickiness)
            "--session-key", "x-session-id",               # HTTP header used to identify user chat sessions
            "--engine-stats-interval", "10",               # Poll vLLM worker health/queue stats every 10 seconds
            "--request-stats-window", "60",                # Track rolling request throughput over a 60-second window
          ]

          # Expose port 8000 (named "http" so Prometheus ServiceMonitor can find it)
          port {
            container_port = 8000
            name           = "http"
          }

          # Reserve guaranteed CPU/RAM and cap maximum usage on the system node
          resources {
            requests = {
              cpu    = "500m" # Guarantee 0.5 vCPU
              memory = "1Gi"  # Guarantee 1 GB RAM
            }
            limits = {
              cpu    = "2"    # Allow bursting up to 2 vCPUs during traffic spikes
              memory = "2Gi"  # Hard cap at 2 GB RAM to prevent out-of-memory crashes
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


################################################################################
# 3. INTERNAL AWS NETWORK LOAD BALANCER (The Private Bridge for API Gateway)
# ------------------------------------------------------------------------------
# Why do we need this?
# Our public AWS API Gateway (configured in `cognito.tf`) needs a stable network
# target inside our private VPC to send authenticated AI requests to.
#
# By creating a Kubernetes `LoadBalancer` Service with AWS annotations, EKS
# automatically provisions an internal-only AWS Network Load Balancer (NLB)
# that forwards port 80 traffic straight to port 8000 on the vLLM Router pod.
################################################################################

resource "kubernetes_service_v1" "vllm_router" {
  metadata {
    name      = "vllm-router-service"
    namespace = "default"
    labels = {
      app = "vllm-router"
    }
    annotations = {
      # Tell AWS to provision a fast Layer-4 Network Load Balancer (NLB)
      "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb"

      # CRITICAL SECURITY SETTING: Keep this load balancer strictly internal
      # inside your private VPC so nobody on the public internet can bypass
      # Cognito authentication and hit the router directly.
      "service.beta.kubernetes.io/aws-load-balancer-internal" = "true"
    }
  }

  spec {
    type = "LoadBalancer"

    # Send traffic to any pod matching `app = "vllm-router"`
    selector = {
      app = kubernetes_deployment_v1.vllm_router.spec[0].template[0].metadata[0].labels.app
    }

    port {
      name        = "http"
      port        = 80   # NLB listens on standard HTTP port 80
      target_port = 8000 # Forwards traffic to port 8000 inside the router container
    }
  }

  depends_on = [
    kubernetes_deployment_v1.vllm_router
  ]
}


################################################################################
# 4. NLB DISCOVERY LOOKUPS (Connecting API Gateway VPC Link to the New NLB)
# ------------------------------------------------------------------------------
# Why do we need this?
# Because Kubernetes created the AWS NLB automatically in Step 3, Terraform
# doesn't natively know its AWS ARN (Amazon Resource Name). These `locals` and
# `data` blocks extract the NLB's name from its DNS hostname and look up its
# port 80 listener ARN so API Gateway can plug directly into it.
################################################################################

locals {
  # Extract the auto-generated AWS DNS hostname assigned to the Kubernetes Service
  # (e.g., "a1b2c3d4e5f6-1234567890.elb.us-east-1.amazonaws.com")
  vllm_nlb_hostname = try(kubernetes_service_v1.vllm_router.status[0].load_balancer[0].ingress[0].hostname, "")

  # Parse out the short AWS NLB name ("a1b2c3d4e5f6") from the full DNS hostname
  vllm_nlb_name = local.vllm_nlb_hostname != "" ? split("-", split(".", local.vllm_nlb_hostname)[0])[0] : null
}

# Look up the AWS NLB object by name to retrieve its unique ARN
data "aws_lb" "vllm_router_nlb" {
  name = local.vllm_nlb_name

  depends_on = [kubernetes_service_v1.vllm_router]
}

# Look up the NLB's port 80 listener ARN, which API Gateway uses as its backend target
data "aws_lb_listener" "vllm_router_nlb_http" {
  load_balancer_arn = data.aws_lb.vllm_router_nlb.arn
  port              = 80
}


################################################################################
# 5. ROUTER METRICS SCRAPER (Feeding Scale-From-Zero Signals to Prometheus)
# ------------------------------------------------------------------------------
# Why do we need this?
# When GPU worker pods are scaled down to 0, the vLLM Router is the ONLY component
# that knows new user requests have arrived. This `ServiceMonitor` tells Prometheus
# to scrape the router's `/metrics` endpoint every 10 seconds so KEDA sees
# `vllm_router_active_requests > 0` and immediately wakes up a GPU server.
################################################################################

resource "kubectl_manifest" "vllm_router_monitor" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "vllm-router-monitor"
      namespace = "monitoring"
    }
    spec = {
      # Look for the router service inside the "default" namespace
      namespaceSelector = {
        matchNames = ["default"]
      }

      # Match the `vllm-router-service` created in Step 3
      selector = {
        matchLabels = {
          app = kubernetes_service_v1.vllm_router.metadata[0].labels.app
        }
      }

      # Scrape the router's `/metrics` page every 10 seconds
      endpoints = [
        {
          port     = "http"
          path     = "/metrics"
          interval = "10s"
        }
      ]
    }
  })

  # Wait until Prometheus Operator is installed so Kubernetes recognizes `kind: ServiceMonitor`
  depends_on = [helm_release.kube_prometheus_stack]
}