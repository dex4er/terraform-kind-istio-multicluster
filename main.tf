terraform {
  required_providers {
    archive = {
      ## https://registry.terraform.io/providers/hashicorp/archive/latest/docs
      source  = "hashicorp/archive"
      version = "2.3.0"
    }
    docker = {
      ## https://registry.terraform.io/providers/kreuzwerker/docker/latest/docs
      source  = "kreuzwerker/docker"
      version = "3.0.1"
    }
    kind = {
      ## https://registry.terraform.io/providers/justenwalker/kind/latest/docs
      source  = "justenwalker/kind"
      version = "0.17.0"
    }
    local = {
      ## https://registry.terraform.io/providers/hashicorp/local/latest/docs
      source  = "hashicorp/local"
      version = "2.3.0"
    }
    null = {
      ## https://registry.terraform.io/providers/hashicorp/null/latest/docs
      source  = "hashicorp/null"
      version = "3.2.1"
    }
  }
}

locals {
  tool_versions = { for line in split("\n", file(".tool-versions")) : split(" ", line)[0] => split(" ", line)[1] if line != "" }
}

resource "docker_image" "registry" {
  name = "registry:2"
}

provider "kind" {
  provider = "docker"
}

resource "kind_cluster" "backend" {
  name = "backend"

  config = yamlencode({
    kind       = "Cluster"
    apiVersion = "kind.x-k8s.io/v1alpha4"
    name       = "backend"
    containerdConfigPatches = [join("\n", [
      "[plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"localhost:5000\"]",
      "  endpoint = [\"http://kind-registry:5000\"]"
    ])]
    featureGates = {
      KubeletInUserNamespace = true
    }
    nodes = [{
      role = "control-plane"
      kubeadmConfigPatches = [yamlencode({
        kind = "InitConfiguration"
        nodeRegistration = {
          kubeletExtraArgs = {
            node-labels = "ingress-ready=true"
          }
        }
      })]
    }]
  })
}

resource "kind_cluster" "frontend" {
  name = "frontend"

  config = yamlencode({
    kind       = "Cluster"
    apiVersion = "kind.x-k8s.io/v1alpha4"
    name       = "frontend"
    containerdConfigPatches = [join("\n", [
      "[plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"localhost:5000\"]",
      "  endpoint = [\"http://kind-registry:5000\"]"
    ])]
    featureGates = {
      KubeletInUserNamespace = true
    }
    nodes = [{
      role = "control-plane"
      kubeadmConfigPatches = [yamlencode({
        kind = "InitConfiguration"
        nodeRegistration = {
          kubeletExtraArgs = {
            node-labels = "ingress-ready=true"
          }
        }
      })]
    }]
  })
}

resource "local_sensitive_file" "backend_kubeconfig" {
  content  = resource.kind_cluster.backend.kubeconfig
  filename = ".kube/kind-backend.yaml"
}

resource "local_sensitive_file" "frontend_kubeconfig" {
  content  = resource.kind_cluster.frontend.kubeconfig
  filename = ".kube/kind-frontend.yaml"
}

resource "docker_container" "registry" {
  name    = "kind-registry"
  image   = docker_image.registry.image_id
  restart = "always"

  ports {
    internal = 5000
    external = 5000
    ip       = "127.0.0.1"
  }

  provisioner "local-exec" {
    command = "docker network connect kind kind-registry"
  }

  depends_on = [
    kind_cluster.backend,
    kind_cluster.frontend,
  ]
}

data "docker_network" "kind" {
  name = "kind"

  depends_on = [
    kind_cluster.backend,
    kind_cluster.frontend,
  ]
}

locals {
  kind_network                             = [for i in data.docker_network.kind.ipam_config : i.subnet if length(regexall(":", i.subnet)) == 0][0]
  kind_backend_lb_iprange_start            = cidrhost(local.kind_network, 251 * 256)
  kind_backend_lb_iprange_end              = cidrhost(local.kind_network, 251 * 256 + 255)
  kind_backend_lb_ip_istio_ingressgateway  = cidrhost(local.kind_network, 251 * 256)
  kind_frontend_lb_iprange_start           = cidrhost(local.kind_network, 252 * 256)
  kind_frontend_lb_iprange_end             = cidrhost(local.kind_network, 252 * 256 + 255)
  kind_frontend_lb_ip_istio_ingressgateway = cidrhost(local.kind_network, 252 * 256)
}

resource "local_file" "backend_env_file" {
  content = join("\n", [
    "lb_iprange_start=${local.kind_backend_lb_iprange_start}",
    "lb_iprange_end=${local.kind_backend_lb_iprange_end}",
    "lb_ip_istio_ingressgateway=${local.kind_backend_lb_ip_istio_ingressgateway}",
  ])
  filename = "flux/backend/flux-system/cluster-vars.env"

  depends_on = [
    data.docker_network.kind,
  ]
}

resource "local_file" "frontend_env_file" {
  content = join("\n", [
    "lb_iprange_start=${local.kind_frontend_lb_iprange_start}",
    "lb_iprange_end=${local.kind_frontend_lb_iprange_end}",
    "lb_ip_istio_ingressgateway=${local.kind_frontend_lb_ip_istio_ingressgateway}",
  ])
  filename = "flux/frontend/flux-system/cluster-vars.env"

  depends_on = [
    data.docker_network.kind,
  ]
}

data "archive_file" "flux" {
  type        = "zip"
  source_dir  = "flux"
  output_path = ".flux.zip"
}

resource "null_resource" "flux_push_artifact" {
  triggers = {
    flux_directory_checksum = data.archive_file.flux.output_base64sha256
  }

  provisioner "local-exec" {
    command = "flux push artifact oci://localhost:5000/flux-system:latest --path=flux --source=\"localhost\" --revision=\"$(git rev-parse --short HEAD 2>/dev/null || LC_ALL=C date +%Y%m%d%H%M%S)\" --kubeconfig .kube/kind-backend.yaml --context kind-backend"
  }

  depends_on = [
    docker_container.registry,
    local_file.backend_env_file,
  ]
}

data "archive_file" "flux-common-flux-system" {
  type        = "zip"
  source_dir  = "flux/common/flux-system"
  output_path = ".flux-common-flux-system.zip"
}

data "archive_file" "flux-backend-flux-system" {
  type        = "zip"
  source_dir  = "flux/backend/flux-system"
  output_path = ".flux-backend-flux-system.zip"
}

data "archive_file" "flux-frontend-flux-system" {
  type        = "zip"
  source_dir  = "flux/frontend/flux-system"
  output_path = ".flux-frontend-flux-system.zip"
}

resource "null_resource" "flux_system_backend_common_apply" {
  triggers = {
    flux_version                    = local.tool_versions["flux2"]
    flux_common_directory_checksum  = data.archive_file.flux-common-flux-system.output_base64sha256
    flux_backend_directory_checksum = data.archive_file.flux-backend-flux-system.output_base64sha256
  }

  provisioner "local-exec" {
    command = "kubectl apply -k flux/common/flux-system --server-side --kubeconfig .kube/kind-backend.yaml --context kind-backend"
  }

  depends_on = [
    local_sensitive_file.backend_kubeconfig,
  ]
}

resource "null_resource" "flux_system_frontend_common_apply" {
  triggers = {
    flux_version                     = local.tool_versions["flux2"]
    flux_common_directory_checksum   = data.archive_file.flux-common-flux-system.output_base64sha256
    flux_frontend_directory_checksum = data.archive_file.flux-frontend-flux-system.output_base64sha256
  }

  provisioner "local-exec" {
    command = "kubectl apply -k flux/common/flux-system --server-side --kubeconfig .kube/kind-frontend.yaml --context kind-backend"
  }

  depends_on = [
    local_sensitive_file.frontend_kubeconfig,
  ]
}

resource "null_resource" "flux_system_backend_apply" {
  triggers = {
    flux_version                    = local.tool_versions["flux2"]
    flux_backend_directory_checksum = data.archive_file.flux-backend-flux-system.output_base64sha256
  }

  provisioner "local-exec" {
    command = "kubectl apply -k flux/backend/flux-system --server-side --kubeconfig .kube/kind-backend.yaml --context kind-backend"
  }

  depends_on = [
    local_sensitive_file.backend_kubeconfig,
    null_resource.flux_system_backend_common_apply,
  ]
}

resource "null_resource" "flux_system_frontend_apply" {
  triggers = {
    flux_version                     = local.tool_versions["flux2"]
    flux_frontend_directory_checksum = data.archive_file.flux-frontend-flux-system.output_base64sha256
  }

  provisioner "local-exec" {
    command = "kubectl apply -k flux/frontend/flux-system --server-side --kubeconfig .kube/kind-frontend.yaml --context kind-backend"
  }

  depends_on = [
    local_sensitive_file.frontend_kubeconfig,
    null_resource.flux_system_frontend_common_apply,
  ]
}

resource "null_resource" "flux_system_kustomization_backend_apply" {
  provisioner "local-exec" {
    command = "kubectl apply -f flux/backend/flux-system.yaml --server-side --kubeconfig .kube/kind-backend.yaml --context kind-backend"
  }

  depends_on = [
    local_sensitive_file.backend_kubeconfig,
    null_resource.flux_system_backend_apply,
  ]
}

resource "null_resource" "flux_system_kustomization_frontend_apply" {
  provisioner "local-exec" {
    command = "kubectl apply -f flux/frontend/flux-system.yaml --server-side --kubeconfig .kube/kind-frontend.yaml --context kind-backend"
  }

  depends_on = [
    local_sensitive_file.frontend_kubeconfig,
    null_resource.flux_system_frontend_apply,
  ]
}

resource "null_resource" "flux_reconcile_backend" {
  triggers = {
    flux_push_artifact_id = null_resource.flux_push_artifact.id
  }

  provisioner "local-exec" {
    command = "flux reconcile source oci flux-system --kubeconfig .kube/kind-backend.yaml --context kind-backend && flux reconcile ks flux-system --kubeconfig .kube/kind-backend.yaml --context kind-backend"
  }

  depends_on = [
    null_resource.flux_system_kustomization_backend_apply,
    null_resource.flux_push_artifact,
  ]
}

resource "null_resource" "flux_reconcile_frontend" {
  triggers = {
    flux_push_artifact_id = null_resource.flux_push_artifact.id
  }

  provisioner "local-exec" {
    command = "flux reconcile source oci flux-system --kubeconfig .kube/kind-frontend.yaml --context kind-backend && flux reconcile ks flux-system --kubeconfig .kube/kind-frontend.yaml --context kind-backend"
  }

  depends_on = [
    null_resource.flux_system_kustomization_frontend_apply,
    null_resource.flux_push_artifact,
  ]
}
