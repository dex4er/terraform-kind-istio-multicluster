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

resource "local_sensitive_file" "kubeconfig" {
  content  = resource.kind_cluster.backend.kubeconfig
  filename = ".kube/config"
}

resource "null_resource" "flux_backend_install_yaml" {
  triggers = {
    flux_version = local.tool_versions["flux2"]
  }

  provisioner "local-exec" {
    command = "mkdir -p flux/common/flux-system && flux install --export --version v${local.tool_versions["flux2"]} > flux/common/flux-system/install.yaml"
  }
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
  ]
}

data "archive_file" "flux" {
  type        = "zip"
  source_dir  = "flux"
  output_path = "flux.zip"
}

resource "null_resource" "flux_push_artifact" {
  triggers = {
    flux_directory_checksum = data.archive_file.flux.output_base64sha256
  }

  provisioner "local-exec" {
    command = "flux push artifact oci://localhost:5000/flux-system:latest --path=flux --source=\"localhost\" --revision=\"$(LC_ALL=C date +%Y%m%d%H%M%S)\""
  }

  depends_on = [
    docker_container.registry,
    null_resource.flux_backend_install_yaml,
  ]
}

resource "null_resource" "flux_system_common_apply" {
  triggers = {
    flux_version = local.tool_versions["flux2"]
  }

  provisioner "local-exec" {
    command = "kubectl apply -k flux/common/flux-system --server-side"
  }

  depends_on = [
    local_sensitive_file.kubeconfig,
    null_resource.flux_backend_install_yaml,
  ]
}

resource "null_resource" "flux_system_backend_apply" {
  triggers = {
    flux_version = local.tool_versions["flux2"]
  }

  provisioner "local-exec" {
    command = "kubectl apply -k flux/backend/flux-system --server-side"
  }

  depends_on = [
    local_sensitive_file.kubeconfig,
    null_resource.flux_system_common_apply,
  ]
}

resource "null_resource" "flux_system_kustomization_backend_apply" {
  provisioner "local-exec" {
    command = "kubectl apply -f flux/backend/flux-system.yaml --server-side"
  }

  depends_on = [
    local_sensitive_file.kubeconfig,
    null_resource.flux_system_backend_apply,
  ]
}


# mkdir -p flux/common/flux-system
# flux install --version v0.39.0 --export > flux/common/flux-system/install.yaml
# kubectl apply -k flux/backend/flux-system --server-side
# flux push artifact oci://localhost:5000/flux-system:latest --path=flux --source="localhost" --revision="main"
# kubectl apply -f flux/backend/flux-system.yaml --server-side
