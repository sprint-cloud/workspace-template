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
  default = "coder"
}

variable "userdata_disk_size" {
  type = number
  default = 15
}

data "coder_parameter" "workspace_image" {
  name    = "Worspace Image"
  default = "ghcr.io/sprint-cloud/workspace-python:production"
  mutable = true

  option {
    name = "Base"
    value = "ghcr.io/sprint-cloud/workspace-base:production"
  }

  option {
    name = "Python"
    value = "ghcr.io/sprint-cloud/workspace-python:production"
  }
}

data "coder_parameter" "database_image" {
  name    = "Database Type"
  default = "redis:7.2.1-alpine"
  mutable = true
  
  option {
    name = "Redis"
    value = "redis:7.2.1-alpine"
  }

  option {
    name = "Postgresql"
    value = "postgres:16.0-alpine"
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
    # Bootstrap Home
    if [ ! -d "/userdata/home" ]; then
      cp -r /bootstrap /userdata/home
    fi
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

resource "kubernetes_persistent_volume_claim" "userdata" {
  metadata {
    name      = "coder-${lower(data.coder_workspace.me.owner)}-userdata"
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
        storage = "${var.userdata_disk_size}Gi"
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
      image             = "${data.coder_parameter.workspace_image.value}"
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


      resources {
        requests = {
          "cpu"    = "250m"
          "memory" = "512Mi"
        }
        limits = {
          "cpu"    = "2"
          "memory" = "2Gi"
        }
      }

      volume_mount {
        mount_path = "/userdata"
        name       = "userdata"
        read_only  = false
      }

      volume_mount {
        mount_path = "/tmp"
        name       = "tmp-dir"
        read_only  = false
      }
    }

    container {
      name              = "database"
      image             = "${data.coder_parameter.database_image.value}"
      image_pull_policy = "Always"
      env {
        name = "POSTGRES_PASSWORD"
        value = "sprint"
      }
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

      resources {
        requests = {
          "cpu"    = "250m"
          "memory" = "256Mi"
        }
        limits = {
          "cpu"    = "250m"
          "memory" = "512Mi"
        }
      }

      volume_mount {
        mount_path = "/tmp"
        name       = "tmp-dir"
        read_only  = false
      }
    }

    volume {
      name = "userdata"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.userdata.metadata.0.name
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
