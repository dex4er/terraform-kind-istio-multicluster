terraform {
  required_providers {
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

provider "kind" {
  provider = "docker"
}

resource "kind_cluster" "backend" {
  name = "backend"

  config = yamlencode({
    kind       = "Cluster"
    apiVersion = "kind.x-k8s.io/v1alpha4"
    name       = "backend"
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

resource "null_resource" "flux_backend" {
  triggers = {
    flux_version = local.tool_versions["flux2"]
  }

  provisioner "local-exec" {
    command = "flux install --context kind-backend --kubeconfig .kube/config --version v${local.tool_versions["flux2"]}"
  }
}
