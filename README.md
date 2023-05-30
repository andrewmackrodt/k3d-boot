# k3d-boot

Linux and macOS script to create a k3d (k3s in docker) cluster for development
including:

- [Cert Manager](https://github.com/cert-manager/cert-manager) provision and manage TLS certificates in Kubernetes
- [Cilium](https://github.com/cilium/cilium) eBPF-based networking, security, and observability
- [Grafana](https://github.com/grafana/grafana) visualize metrics, logs, and traces
- [Ingress-NGINX](https://github.com/kubernetes/ingress-nginx) ingress controller for Kubernetes using NGINX
- [Kubernetes Dashboard](https://github.com/kubernetes/dashboard) general-purpose web UI for Kubernetes
- [MetalLB](https://github.com/metallb/metallb) network load-balancer implementation
- [Prometheus](https://github.com/prometheus/prometheus) monitoring system and time series database

## Requirements

A working `docker` installation is required. Additional tooling will be downloaded automatically if they are not
available: `helm`, `k3d` and `kubectl`.

### macOS notes

Docker Desktop for Mac does not support routing to containers by IP address meaning that cluster nodes and load balancer
addresses cannot be accessed directly. This functionality is supported natively by Linux and requires additional tooling
on macOS. One such utility is [docker-mac-net-connect](https://github.com/chipmk/docker-mac-net-connect) which can be
installed via [homebrew](https://brew.sh/):

```sh
brew install chipmk/tap/docker-mac-net-connect
brew services start chipmk/tap/docker-mac-net-connect
```

## Quick Start

Use `./create.sh` to create the cluster. Once started the following ports will
be accessible via localhost:

- `8080` Ingress Controller HTTP port
- `8443` Ingress Controller HTTPS port
- `6443` Kubernetes API server

To configure the cluster use the command-line options:

```
Usage: 
  ./create.sh [options]

Options:
  -n, --cluster-name <>        cluster name (default: "default")
  -i, --cluster-id <>          cilium cluster id: 1..255 (default: 0)
  -c, --cni <>                 cni plugin: "cilium" | "calico" | "flannel" (default: "cilium")
  -l, --load-balancer <>       load balancer implementation: "metallb" | "servicelb" (default: "metallb")
  -a, --api-port <>            server api port (default: 6443)
  -P, --proxy-protocol         enable proxy protocol for ingress communication
  -p, --proxy-http-port <>     ingress http port to expose on host (default: 8080)
  -t, --proxy-tls-port <>      ingress tls port to expose on host (default: 8443)
  -L, --proxy-no-labels        do not add traefik labels to the proxy container
  -d, --proxy-host <>          traefik router host (e.g. k3s.localhost)
  -k, --proxy-certresolver <>  traefik certResolver (default: "letsencrypt")
  -e, --proxy-entrypoint <>    traefik entryPoint (default: "websecure")
  -s, --proxy-service <>       traefik service name (default: "k3s-${cluster_name}")
  -h, --help                   display help
```

To delete the cluster, run `./destroy.sh`.

## Advanced Configuration

### Cilium Multi-Cluster (Cluster Mesh)

The Cilium CNI plugin (`--cni="cilium"`) supports creating a cluster mesh:

> Cluster mesh extends the networking datapath across multiple clusters.
> It allows endpoints in all connected clusters to communicate while providing full policy enforcement.
> Load-balancing is available via Kubernetes annotations.

To create a cluster capable of joining a mesh, pass `--cluster-id <>` as an argument to `./create.sh`. Each cluster
**must** have a unique ID between 1 and 255. `cilium-cli` is required to connect the clusters together and additional
network configuration/bridging must be performed to allow traffic between the otherwise isolated docker networks.
See [./clustermesh.sh](clustermesh.sh) for an example of creating a 2 cluster mesh.

## Services

### Kubernetes Dashboard

The token for the dashboard can be created by running `kubectl -n kubernetes-dashboard create token admin-user`.

To access the dashboard visit https://console.k3s.localhost:8443/#login.

Alternatively, use `kubectl proxy` and visit http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/#login.

### Hubble

Use `kubectl port-forward`, e.g. `kubectl -n kube-system port-forward service/hubble-ui 8081:80` would make the service available at http://localhost:8081.
