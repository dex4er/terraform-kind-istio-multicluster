# terraform-kind-istio-multicluster

Example of Terraform project using KIND clusters.

- Two clusters with communication between them using Istio multicluster mesh.
- Additional Docker container for a local OCI registry.
- Flux CD uses a local OCI registry as a source repository. Terraform will push
  there when changes to [`flux`](flux) directory are detected.
- MetalLB exposes cluster services.

## Usage

- Install [asdf](https://asdf-vm.com/guide/getting-started.html)

```sh
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.11.1
echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc
while read plugin version; do asdf plugin add $plugin || test $? = 2; done < .tool-versions
asdf install
```

- Run Terraform

```sh
terraform init
terraform apply
```

- Connect to frontend ingress:

```sh
kubectl config set-context kind-frontend
kubectl get svc -n istio-ingressgateway istio-ingressgateway
curl http://$EXTERNAL_IP
```

## Note

There is only a single Terraform file [`main.tf`](main.tf). The state should be
local because `local_file` resources are used for extra files generated: Istio
certificates and environment variables for Flux.

`local-exec` runs `kubectl`, `istioctl` and `flux` commands.

Istio is configured as a multicluster mesh and frontend ingress uses backend
podinfo service only for demo purpose.
