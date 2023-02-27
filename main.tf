## Single Terraform file for clarity

## Strict dependencies
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
    time = {
      ## https://registry.terraform.io/providers/hashicorp/time/latest/docs
      source  = "hashicorp/time"
      version = "0.9.1"
    }
    tls = {
      ## https://registry.terraform.io/providers/hashicorp/tls/latest/docs
      source  = "hashicorp/tls"
      version = "4.0.4"
    }
  }
}

## Two KIND clusters

provider "kind" {
  provider = "docker"
}

resource "kind_cluster" "backend" {
  name = "backend"

  config = yamlencode({
    kind       = "Cluster"
    apiVersion = "kind.x-k8s.io/v1alpha4"
    name       = "backend"
    ## Use kind-registry container instead of localhost:5000
    containerdConfigPatches = [join("\n", [
      "[plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"localhost:5000\"]",
      "  endpoint = [\"http://kind-registry:5000\"]"
    ])]
    ## Allows to start inside LXC container (ChromeOS)
    featureGates = {
      KubeletInUserNamespace = true
    }
    nodes = [{
      role = "control-plane"
      # ## Extra patches when Ingress is Nginx
      # kubeadmConfigPatches = [yamlencode({
      #   kind = "InitConfiguration"
      #   nodeRegistration = {
      #     kubeletExtraArgs = {
      #       node-labels = "ingress-ready=true"
      #     }
      #   }
      # })]
    }]
  })
}

resource "kind_cluster" "frontend" {
  name = "frontend"

  config = yamlencode({
    kind       = "Cluster"
    apiVersion = "kind.x-k8s.io/v1alpha4"
    name       = "frontend"
    ## Use kind-registry container instead of localhost:5000
    containerdConfigPatches = [join("\n", [
      "[plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"localhost:5000\"]",
      "  endpoint = [\"http://kind-registry:5000\"]"
    ])]
    ## Allows to start inside LXC container (ChromeOS)
    featureGates = {
      KubeletInUserNamespace = true
    }
    nodes = [{
      role = "control-plane"
      # ## Extra patches when Ingress is Nginx
      # kubeadmConfigPatches = [yamlencode({
      #   kind = "InitConfiguration"
      #   nodeRegistration = {
      #     kubeletExtraArgs = {
      #       node-labels = "ingress-ready=true"
      #     }
      #   }
      # })]
    }]
  })
}

## KIND will write to ~/.kube but there are extra config files used by Terraform

resource "local_sensitive_file" "backend_kubeconfig" {
  content  = resource.kind_cluster.backend.kubeconfig
  filename = ".kube/kind-backend.yaml"
}

resource "local_sensitive_file" "frontend_kubeconfig" {
  content  = resource.kind_cluster.frontend.kubeconfig
  filename = ".kube/kind-frontend.yaml"
}

## KIND will use this registry

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
    kind_cluster.backend,
    kind_cluster.frontend,
  ]
}

resource "time_sleep" "after_kind_registry" {
  create_duration = "60s"

  depends_on = [
    docker_container.registry,
  ]
}


## First KIND cluster will create `kind` network

data "docker_network" "kind" {
  name = "kind"

  depends_on = [
    kind_cluster.backend,
    kind_cluster.frontend,
  ]
}

## Calculate network addresses in `kind` network

locals {
  kind_network                              = [for i in data.docker_network.kind.ipam_config : i.subnet if length(regexall(":", i.subnet)) == 0][0]
  kind_backend_lb_iprange_start             = cidrhost(local.kind_network, 251 * 256)
  kind_backend_lb_iprange_end               = cidrhost(local.kind_network, 251 * 256 + 255)
  kind_backend_lb_ip_istio_ingressgateway   = cidrhost(local.kind_network, 251 * 256)
  kind_backend_lb_ip_istio_eastwestgateway  = cidrhost(local.kind_network, 251 * 256 + 1)
  kind_frontend_lb_iprange_start            = cidrhost(local.kind_network, 252 * 256)
  kind_frontend_lb_iprange_end              = cidrhost(local.kind_network, 252 * 256 + 255)
  kind_frontend_lb_ip_istio_ingressgateway  = cidrhost(local.kind_network, 252 * 256)
  kind_frontend_lb_ip_istio_eastwestgateway = cidrhost(local.kind_network, 252 * 256 + 1)
}

## Pass variables from Terraform to Flux through env file

resource "local_file" "backend_env_file" {
  content = join("\n", [
    "cluster_name=${kind_cluster.backend.context}",
    "lb_iprange_start=${local.kind_backend_lb_iprange_start}",
    "lb_iprange_end=${local.kind_backend_lb_iprange_end}",
    "lb_ip_istio_ingressgateway=${local.kind_backend_lb_ip_istio_ingressgateway}",
    "lb_ip_istio_eastwestgateway=${local.kind_backend_lb_ip_istio_eastwestgateway}",
    "lb_ip_istio_remote_eastwestgateway=${local.kind_frontend_lb_ip_istio_eastwestgateway}",
  ])
  filename = "flux/backend/flux-system/cluster-vars.env"

  depends_on = [
    data.docker_network.kind,
  ]
}

resource "local_file" "frontend_env_file" {
  content = join("\n", [
    "cluster_name=${kind_cluster.frontend.context}",
    "lb_iprange_start=${local.kind_frontend_lb_iprange_start}",
    "lb_iprange_end=${local.kind_frontend_lb_iprange_end}",
    "lb_ip_istio_ingressgateway=${local.kind_frontend_lb_ip_istio_ingressgateway}",
    "lb_ip_istio_eastwestgateway=${local.kind_frontend_lb_ip_istio_eastwestgateway}",
    "lb_ip_istio_remote_eastwestgateway=${local.kind_backend_lb_ip_istio_eastwestgateway}",
  ])
  filename = "flux/frontend/flux-system/cluster-vars.env"

  depends_on = [
    data.docker_network.kind,
  ]
}

## Common CA cert for Istio

resource "tls_private_key" "root" {
  algorithm = "RSA"
  rsa_bits  = "4096"
}

resource "local_file" "root_key" {
  content  = tls_private_key.root.private_key_pem
  filename = "flux/common/istio-certs/files/root-key.pem"
}

resource "tls_self_signed_cert" "root" {
  private_key_pem   = tls_private_key.root.private_key_pem
  is_ca_certificate = true

  subject {
    common_name  = "Root CA"
    organization = "Istio"
  }

  validity_period_hours = 10 * 365 * 24 + 2 * 24

  allowed_uses = [
    "digital_signature",
    "content_commitment",
    "key_encipherment",
    "cert_signing",
  ]
}

resource "local_file" "root_cert" {
  content  = tls_self_signed_cert.root.cert_pem
  filename = "flux/common/istio-certs/files/root-cert.pem"
}

## Intermediate CA for Istio

resource "tls_private_key" "backend" {
  algorithm = "RSA"
  rsa_bits  = "4096"
}

resource "local_file" "backend_ca_key" {
  content  = tls_private_key.backend.private_key_pem
  filename = "flux/backend/istio-certs/files/ca-key.pem"
}

resource "tls_cert_request" "backend" {
  private_key_pem = tls_private_key.backend.private_key_pem

  dns_names = [
    "istiod.istio-system.svc",
  ]

  subject {
    organization = "Istio"
    common_name  = "Intermediate CA"
    locality     = "kind-backend"
  }
}

resource "tls_locally_signed_cert" "backend" {
  cert_request_pem   = tls_cert_request.backend.cert_request_pem
  ca_private_key_pem = tls_private_key.root.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.root.cert_pem
  is_ca_certificate  = true

  validity_period_hours = 2 * 365 * 24

  allowed_uses = [
    "digital_signature",
    "content_commitment",
    "key_encipherment",
    "cert_signing",
  ]
}

resource "local_file" "backend_ca_cert" {
  content  = tls_locally_signed_cert.backend.cert_pem
  filename = "flux/backend/istio-certs/files/ca-cert.pem"
}

resource "local_file" "backend_cert_chain" {
  content = join("", [
    tls_locally_signed_cert.backend.cert_pem,
    tls_self_signed_cert.root.cert_pem,
  ])
  filename = "flux/backend/istio-certs/files/cert-chain.pem"
}

resource "tls_private_key" "frontend" {
  algorithm = "RSA"
  rsa_bits  = "4096"
}

resource "local_file" "frontend_ca_key" {
  content  = tls_private_key.frontend.private_key_pem
  filename = "flux/frontend/istio-certs/files/ca-key.pem"
}

resource "tls_cert_request" "frontend" {
  private_key_pem = tls_private_key.frontend.private_key_pem

  dns_names = [
    "istiod.istio-system.svc",
  ]

  subject {
    organization = "Istio"
    common_name  = "Intermediate CA"
    locality     = "kind-frontend"
  }
}

resource "tls_locally_signed_cert" "frontend" {
  cert_request_pem   = tls_cert_request.frontend.cert_request_pem
  ca_private_key_pem = tls_private_key.root.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.root.cert_pem
  is_ca_certificate  = true

  validity_period_hours = 2 * 365 * 24

  allowed_uses = [
    "digital_signature",
    "content_commitment",
    "key_encipherment",
    "cert_signing",
  ]
}

resource "local_file" "frontend_ca_cert" {
  content  = tls_locally_signed_cert.frontend.cert_pem
  filename = "flux/frontend/istio-certs/files/ca-cert.pem"
}

resource "local_file" "frontend_cert_chain" {
  content = join("", [
    tls_locally_signed_cert.frontend.cert_pem,
    tls_self_signed_cert.root.cert_pem,
  ])
  filename = "flux/frontend/istio-certs/files/cert-chain.pem"
}

## Calculate checksum for ./flux directory to detect the changes

data "archive_file" "flux" {
  type        = "zip"
  source_dir  = "flux"
  output_path = ".flux.zip"
}

## Push ./flux directory to kind-registry

resource "null_resource" "flux_push_artifact" {
  triggers = {
    flux_directory_checksum = data.archive_file.flux.output_base64sha256
  }

  provisioner "local-exec" {
    command = "flux push artifact oci://localhost:5000/flux-system:latest --path=flux --source=\"localhost\" --revision=\"$(git rev-parse --short HEAD 2>/dev/null || LC_ALL=C date +%Y%m%d%H%M%S)\" --kubeconfig .kube/kind-backend.yaml --context kind-backend"
  }

  depends_on = [
    time_sleep.after_kind_registry,
    local_file.backend_env_file,
    local_file.root_cert,
    local_file.backend_ca_key,
    local_file.backend_ca_cert,
    local_file.backend_cert_chain,
    local_file.frontend_ca_key,
    local_file.frontend_ca_cert,
    local_file.frontend_cert_chain,
  ]
}

## Flux: step 1 - install CRDs and main manifest

resource "null_resource" "flux_system_backend_common_apply" {
  provisioner "local-exec" {
    command = "kubectl apply -k flux/common/flux-system --server-side --kubeconfig .kube/kind-backend.yaml --context kind-backend"
  }

  depends_on = [
    local_sensitive_file.backend_kubeconfig,
  ]
}

resource "null_resource" "flux_system_frontend_common_apply" {
  provisioner "local-exec" {
    command = "kubectl apply -k flux/common/flux-system --server-side --kubeconfig .kube/kind-frontend.yaml --context kind-frontend"
  }

  depends_on = [
    local_sensitive_file.frontend_kubeconfig,
  ]
}

## Flux: step 2 - install sources and kustomization for frontend/backend

resource "null_resource" "flux_system_backend_apply" {
  provisioner "local-exec" {
    command = "kubectl apply -k flux/backend/flux-system --server-side --kubeconfig .kube/kind-backend.yaml --context kind-backend"
  }

  depends_on = [
    local_sensitive_file.backend_kubeconfig,
    null_resource.flux_system_backend_common_apply,
  ]
}

resource "null_resource" "flux_system_frontend_apply" {
  provisioner "local-exec" {
    command = "kubectl apply -k flux/frontend/flux-system --server-side --kubeconfig .kube/kind-frontend.yaml --context kind-frontend"
  }

  depends_on = [
    local_sensitive_file.frontend_kubeconfig,
    null_resource.flux_system_frontend_common_apply,
  ]
}

## Flux: step 3 - install main Flux kustomization

resource "null_resource" "flux_system_all_backend_apply" {
  provisioner "local-exec" {
    command = "kubectl apply -f flux/backend/all.yaml --server-side --kubeconfig .kube/kind-backend.yaml --context kind-backend"
  }

  depends_on = [
    local_sensitive_file.backend_kubeconfig,
    null_resource.flux_system_backend_apply,
  ]
}

resource "null_resource" "flux_system_all_frontend_apply" {
  provisioner "local-exec" {
    command = "kubectl apply -f flux/frontend/all.yaml --server-side --kubeconfig .kube/kind-frontend.yaml --context kind-frontend"
  }

  depends_on = [
    local_sensitive_file.frontend_kubeconfig,
    null_resource.flux_system_frontend_apply,
  ]
}

## Reconcile Flux source repo and kustomization

resource "null_resource" "flux_reconcile_all_backend" {
  triggers = {
    flux_push_artifact_id = null_resource.flux_push_artifact.id
  }

  provisioner "local-exec" {
    command = "flux reconcile source oci flux-system --kubeconfig .kube/kind-backend.yaml --context kind-backend && flux reconcile ks flux-system --kubeconfig .kube/kind-backend.yaml --context kind-backend"
  }

  depends_on = [
    time_sleep.after_flux_all_apply,
    null_resource.flux_push_artifact,
  ]
}

resource "null_resource" "flux_reconcile_all_frontend" {
  triggers = {
    flux_push_artifact_id = null_resource.flux_push_artifact.id
  }

  provisioner "local-exec" {
    command = "flux reconcile source oci flux-system --kubeconfig .kube/kind-frontend.yaml --context kind-frontend && flux reconcile ks flux-system --kubeconfig .kube/kind-frontend.yaml --context kind-frontend"
  }

  depends_on = [
    time_sleep.after_flux_all_apply,
    null_resource.flux_push_artifact,
  ]
}

## Create remote secrets for Istio

resource "time_sleep" "after_flux_all_apply" {
  create_duration = "120s"

  depends_on = [
    local_sensitive_file.backend_kubeconfig,
    local_sensitive_file.frontend_kubeconfig,
    null_resource.flux_system_all_backend_apply,
    null_resource.flux_system_all_frontend_apply,
  ]
}

resource "null_resource" "istio_remote_secret_backend" {
  provisioner "local-exec" {
    command = "istioctl x create-remote-secret --name kind-backend --server https://backend-control-plane:6443 --kubeconfig .kube/kind-backend.yaml --context kind-backend | kubectl apply -l istio/multiCluster=true -f - --server-side --kubeconfig .kube/kind-frontend.yaml --context kind-frontend"
  }

  depends_on = [
    time_sleep.after_flux_all_apply,
  ]
}

resource "null_resource" "istio_remote_secret_frontend" {
  provisioner "local-exec" {
    command = "istioctl x create-remote-secret --name kind-frontend --server https://frontend-control-plane:6443 --kubeconfig .kube/kind-frontend.yaml --context kind-frontend | kubectl apply -l istio/multiCluster=true -f - --server-side --kubeconfig .kube/kind-backend.yaml --context kind-backend"
  }

  depends_on = [
    time_sleep.after_flux_all_apply,
  ]
}
