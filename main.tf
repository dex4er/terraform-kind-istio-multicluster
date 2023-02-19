terraform {
  required_providers {
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

## tf import docker_network.kind $(docker network inspect kind | jq -r .[0].Id)
resource "docker_network" "kind" {
  name = "kind"
  ipv6 = true

  options = {
    "com.docker.network.bridge.enable_ip_masquerade" = "true"
    "com.docker.network.driver.mtu"                  = "1500"
  }
}

resource "docker_network" "test" {
  name = "test"
}

resource "docker_image" "registry" {
  name = "registry:2"
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
    docker_network.kind,
  ]
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

  depends_on = [
    docker_network.kind,
  ]
}

resource "local_sensitive_file" "kubeconfig" {
  content  = resource.kind_cluster.backend.kubeconfig
  filename = ".kube/config"
}

resource "null_resource" "flux_backend" {
  triggers = {
    flux_version = local.tool_versions["flux2"]
  }

  provisioner "local-exec" {
    command = "flux install --context kind-backend --kubeconfig .kube/config --version v${local.tool_versions["flux2"]}"
  }

  depends_on = [
    docker_network.kind,
    local_sensitive_file.kubeconfig,
  ]
}
