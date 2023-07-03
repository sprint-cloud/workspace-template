terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 0.6.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.18"
    }
  }
}

provider "coder" {
  feature_use_managed_variables = true
}

variable "namespace" {
  type        = string
  description = "The Kubernetes namespace to create workspaces in (must exist prior to creating workspaces)"
  default = "coder-workspaces"
}

data "coder_parameter" "cpu" {
  name    = "CPU (cores)"
  default = "2"
  icon    = "/icon/memory.svg"
  mutable = true
  option {
    name  = "2 Cores"
    value = "2"
  }
}

data "coder_parameter" "memory" {
  name    = "Memory (GB)"
  default = "2"
  icon    = "/icon/memory.svg"
  mutable = true
  option {
    name  = "2 GB"
    value = "2"
  }
}

data "coder_parameter" "home_disk_size" {
  name    = "Home Disk Size (GB)"
  default = "10"
  type    = "number"
  icon    = "/emojis/1f4be.png"
  mutable = false
  validation {
    min = 1
    max = 10
  }
}

provider "kubernetes" {
  # Authenticate via ~/.kube/config or a Coder-specific ServiceAccount, depending on admin preferences
  config_path = null
}

data "coder_workspace" "me" {}

resource "coder_agent" "main" {
  os                     = "linux"
  arch                   = "amd64"
  login_before_ready     = false
  startup_script_timeout = 180
  startup_script         = <<-EOT
    set -e
    # Bootstrap home
    cp -r /bootstrap/. /home/coder
    # Generate DB_URL
    export DB_URL="postgresql://$DB_USER:$DB_PASS@coder-${lower(data.coder_workspace.me.owner)}-db-rw:5432/postgres"

    # install and start code-server
    curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=/tmp/code-server --version 4.8.3
    /tmp/code-server/bin/code-server --auth none --port 13337 >/tmp/code-server.log 2>&1 &

  EOT
}

# code-server
resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  icon         = "/icon/code.svg"
  url          = "http://localhost:13337?folder=/home/coder"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 3
    threshold = 10
  }
}

### Dev database
resource "kubernetes_manifest" "dev-database" {
  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind = "Cluster"
    metadata = {
      name = "coder-${lower(data.coder_workspace.me.owner)}-db"
      namespace = var.namespace
      labels = {
        "spint.resource.type" = "dev-db"
      }  
    }

    spec = {
      instances = 1
      primaryUpdateStrategy = "unsupervised"
      storage = {
        size = "1Gi"
      }
      monitoring = {
        enablePodMonitor = true
      }
    }
  }
  
}

resource "kubernetes_network_policy_v1" "allow-db-connections" {
  metadata {
    name = "coder-${lower(data.coder_workspace.me.owner)}-db"
    namespace = var.namespace
  }
  spec {
    pod_selector {
        match_expressions {
              key      = "cnpg.io/cluster"
              operator = "In"
              values   = ["coder-${lower(data.coder_workspace.me.owner)}-db"]
            }
    }
  ingress {
    ports {
        port     = "5432"
        protocol = "TCP"
    }
    from {
      pod_selector {
        match_expressions {
          key      = "com.coder.user.username"
          operator = "In"
          values   = [data.coder_workspace.me.owner]
        }
      }
    }

  }
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "coder-${lower(data.coder_workspace.me.owner)}-home"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-pvc"
      "app.kubernetes.io/instance" = "coder-pvc-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}"
      "app.kubernetes.io/part-of"  = "coder"
      // Coder specific labels.
      "com.coder.resource"       = "true"
      "com.coder.workspace.id"   = data.coder_workspace.me.id
      "com.coder.workspace.name" = data.coder_workspace.me.name
      "com.coder.user.id"        = data.coder_workspace.me.owner_id
      "com.coder.user.username"  = data.coder_workspace.me.owner
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace.me.owner_email
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${data.coder_parameter.home_disk_size.value}Gi"
      }
    }
  }
}

resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count
  metadata {
    name      = "coder-${lower(data.coder_workspace.me.owner)}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace"
      "app.kubernetes.io/instance" = "coder-workspace-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}"
      "app.kubernetes.io/part-of"  = "coder"
      // Coder specific labels.
      "com.coder.resource"       = "true"
      "com.coder.workspace.id"   = data.coder_workspace.me.id
      "com.coder.workspace.name" = data.coder_workspace.me.name
      "com.coder.user.id"        = data.coder_workspace.me.owner_id
      "com.coder.user.username"  = data.coder_workspace.me.owner
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace.me.owner_email
    }
  }
  spec {
    automount_service_account_token = false
    security_context {
      run_as_user = "1000"
      fs_group    = "1000"
      run_as_non_root = true
      seccomp_profile {
        type = "RuntimeDefault"
      }
    }
    container {
      name              = "dev"
      image             = "ghcr.io/sprint-cloud/workspace-image:0e9a9524b9cf8816866985f31c7bb3b848f38abb"
      image_pull_policy = "Always"
      command           = ["sh", "-c", coder_agent.main.init_script]
      security_context {
        run_as_user = "1000"
        allow_privilege_escalation = false
        privileged = false
        run_as_non_root = true
        read_only_root_filesystem = true
        capabilities {
              drop = ["ALL"]
            }
       
      }
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      env {
        name = "DB_USER"
        value_from {
          secret_key_ref {
            name = "coder-${lower(data.coder_workspace.me.owner)}-db-app"
            key = username
          }
        }
      }

      env {
        name = "DB_PASS"
        value_from {
          secret_key_ref {
            name = "coder-${lower(data.coder_workspace.me.owner)}-db-app"
            key = password
          }
        }
      }
      resources {
        requests = {
          "cpu"    = "250m"
          "memory" = "512Mi"
        }
        limits = {
          "cpu"    = "${data.coder_parameter.cpu.value}"
          "memory" = "${data.coder_parameter.memory.value}Gi"
        }
      }

      volume_mount {
        mount_path = "/home/coder"
        name       = "home"
        read_only  = false
      }

      volume_mount {
        mount_path = "/tmp"
        name       = "tmp-dir"
        read_only  = false
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home.metadata.0.name
        read_only  = false
      }
    }

    volume {
      name = "tmp-dir"
      empty_dir {
        medium = "Memory"
        size_limit = "2Gi"
      }
    }

    affinity {
      pod_anti_affinity {
        // This affinity attempts to spread out all workspace pods evenly across
        // nodes.
        preferred_during_scheduling_ignored_during_execution {
          weight = 1
          pod_affinity_term {
            topology_key = "kubernetes.io/hostname"
            label_selector {
              match_expressions {
                key      = "app.kubernetes.io/name"
                operator = "In"
                values   = ["coder-workspace"]
              }
            }
          }
        }
      }
    }
  }
}
