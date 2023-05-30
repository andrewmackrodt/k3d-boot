#!/bin/bash
set -euo pipefail
cd "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)"

. functions.sh

default_cluster_name="default"
cluster_name=""
params+=( cluster_name )
required_params+=( cluster_name )

default_cluster_id=0
cluster_id=""
params+=( cluster_id )
required_params+=( cluster_id )

default_cni="cilium"
cni=""
params+=( cni )
required_params+=( cni )

default_load_balancer="metallb"
load_balancer=""
params+=( load_balancer )
required_params+=( load_balancer )

default_api_port=6443
api_port=""
params+=( api_port )
required_params+=( api_port )

default_proxy_protocol="false"
proxy_protocol=""
params+=( proxy_protocol )
required_params+=( proxy_protocol )

default_proxy_http_port=8080
proxy_http_port=""
params+=( proxy_http_port )

default_proxy_tls_port=8443
proxy_tls_port=""
params+=( proxy_tls_port )

default_proxy_no_labels="false"
proxy_no_labels=""
params+=( proxy_no_labels )
required_params+=( proxy_no_labels )

proxy_host=""
params+=( proxy_host )

default_proxy_certresolver="letsencrypt"
proxy_certresolver=""
params+=( proxy_certresolver )
required_params+=( proxy_certresolver )

default_proxy_entrypoint="websecure"
proxy_entrypoint=""
params+=( proxy_entrypoint )
required_params+=( proxy_entrypoint )

default_proxy_service="k3s-\${cluster_name}"
proxy_service=""
params+=( proxy_service )
required_params+=( proxy_service )

display_usage() {
  local script_name
  script_name=$(basename "${BASH_SOURCE[0]}")
  cat <<EOF
Usage:
  ./$script_name [options]

Options:
  -n, --cluster-name <>        cluster name (default: "$default_cluster_name")
  -i, --cluster-id <>          cilium cluster id: 1..255 (default: "$default_cluster_id")
  -c, --cni <>                 cni plugin: "cilium" | "calico" | "flannel" (default: "$default_cni")
  -l, --load-balancer <>       load balancer implementation: "metallb" | "servicelb" (default: "$default_load_balancer")
  -a, --api-port <>            server api port (default: $default_api_port)
  -P, --proxy-protocol         enable proxy protocol for ingress communication
  -p, --proxy-http-port <>     ingress http port to expose on host (default: ${default_proxy_http_port:-none})
  -t, --proxy-tls-port <>      ingress tls port to expose on host (default: ${default_proxy_tls_port:-none})
  -L, --proxy-no-labels        do not add traefik labels to the proxy container
  -d, --proxy-host <>          traefik router host (e.g. k3s.localhost)
  -k, --proxy-certresolver <>  traefik certResolver (default: "$default_proxy_certresolver")
  -e, --proxy-entrypoint <>    traefik entryPoint (default: "$default_proxy_entrypoint")
  -s, --proxy-service <>       traefik service name (default: "$default_proxy_service")
  -h, --help                   display help
EOF
}

get_params() {
  while (( "$#" )); do
    [[ $1 == --*=* ]] && set -- "${1%%=*}" "${1#*=}" "${@:2}"
    case "$1" in
      -n | --cluster-name ) set_param_once cluster_name "$@"; shift ;;
      -i | --cluster-id ) set_param_once cluster_id "$@"; shift ;;
      -c | --cni ) set_param_once cni "$@"; shift ;;
      -l | --load-balancer ) set_param_once load_balancer "$@"; shift ;;
      -a | --api-port ) set_param_once api_port "$@"; shift ;;
      -P | --proxy-protocol ) set_param_once proxy_protocol -- true ;;
      -p | --proxy-http-port ) set_param_once proxy_http_port "$@"; shift ;;
      -t | --proxy-tls-port ) set_param_once proxy_tls_port "$@"; shift ;;
      -L | --proxy-no-labels ) set_param_once proxy_no_labels -- true ;;
      -d | --proxy-host ) set_param_once proxy_host "$@"; shift ;;
      -k | --proxy-certresolver ) set_param_once proxy_certresolver "$@"; shift ;;
      -e | --proxy-entrypoint ) set_param_once proxy_entrypoint "$@"; shift ;;
      -s | --proxy-service ) set_param_once proxy_service "$@"; shift ;;
      -h | --help ) display_usage; exit ;;
      -* ) exit_with_usage_error "unsupported option: $1" ;;
      *  ) exit_with_usage_error "unsupported argument: $1" ;;
    esac
    shift
  done
}

_set_default_params() {
  if [[ "$proxy_service" == "$default_proxy_service" ]]; then
    proxy_service="k3s-${cluster_name}"
  fi
}

_validate_params() {
  if ! echo "$cluster_id" | grep -qE '^(0|[1-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$'; then
    exit_with_usage_error "--cluster-id must be between 1 and 255"
  fi
  if [[ $cluster_id -gt 0 ]] && [[ "$cni" != "cilium" ]]; then
    exit_with_error 'usage of --cluster-id without --cni="cilium" is invalid'
  fi
}

get_params "$@"
set_default_params
validate_params

install_kubectl() {
  local os arch kubectl_stable_release kubectl_url
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  [[ "$(uname -m)" == "arm64" ]] && arch=arm64 || arch="amd64"
  kubectl_stable_release=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  kubectl_url="https://dl.k8s.io/release/$kubectl_stable_release/bin/$os/$arch/kubectl"
  sudo curl -fsSL "$kubectl_url" -o /usr/local/bin/kubectl
  sudo chmod +x /usr/local/bin/kubectl
}

if ! which helm >/dev/null 2>&1; then
  curl -fsSo- "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3" | bash
fi

if ! which k3d >/dev/null 2>&1; then
  curl -fsSo- "https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh" | bash
fi

if ! which kubectl >/dev/null 2>&1; then
  install_kubectl
fi

print_params

trap 'error_reporter $LINENO' ERR

# create cluster
if ! k3d cluster list "$cluster_name" >/dev/null 2>&1; then
  declare -a cluster_create_extra_args=( --wait --no-lb )
  if [[ "$cni" != "flannel" ]]; then
    cluster_create_extra_args+=( --k3s-arg '--disable-network-policy@server:*' )
    cluster_create_extra_args+=( --k3s-arg '--flannel-backend=none@server:*' )
  fi
  if [[ "$cni" == "cilium" ]]; then
    cluster_create_extra_args+=( -v "$PWD/scripts/k3d-entrypoint-cilium.sh:/bin/k3d-entrypoint-cilium.sh:ro@server:*" )
    cluster_create_extra_args+=( -v "$PWD/scripts/k3d-entrypoint-cilium.sh:/bin/k3d-entrypoint-cilium.sh:ro@agent:*" )
  fi
  if [[ "$load_balancer" != "servicelb" ]] && [[ "$load_balancer" != "klipper" ]]; then
    cluster_create_extra_args+=( --k3s-arg '--disable=servicelb@server:*' )
  fi
  k3d cluster create "$cluster_name" --servers 1 --agents 1 \
    --api-port "$api_port" \
    --k3s-arg '--disable=traefik@server:*' \
    --k3s-arg '--secrets-encryption@server:*' \
    "${cluster_create_extra_args[@]}"
fi

context="k3d-${cluster_name}"

# cni
case "$cni" in
  calico )
    internal_cidr=""
    while [[ "$internal_cidr" == "" ]]; do
      internal_cidr=$(kubectl --context "$context" get nodes -o jsonpath='{.items[*].spec.podCIDR}' | tr ' ' $'\n' | sort -V | head -n1)
      if [[ "$internal_cidr" == "" ]]; then
        sleep 0.1
      fi
    done
    sed -E 's/# (- name: CALICO_IPV4POOL_CIDR)/\1/' ./manifests/calico.yaml \
      | sed -E 's%#   value: "192.168.0.0/16"%  value: "'"$internal_cidr"'"%' \
      | kubectl --context "$context" apply -f -
    echo "waiting for kube-system deployment.apps/calico-kube-controllers"
    kubectl --context "$context" -n kube-system wait deployment calico-kube-controllers --for condition=Available=True --timeout=300s
    ;;
  cilium )
    if [[ $cluster_id -gt 0 ]]; then
      useAPIServer="true"
      identityAllocationMode="kvstore"
      clusterPoolIPv4PodCIDR="10.${cluster_id}.0.0/16"
    else
      useAPIServer="false"
      identityAllocationMode="crd"
      clusterPoolIPv4PodCIDR="10.0.0.0/8"
    fi
    helm upgrade --install cilium ./manifests/cilium \
      --kube-context "$context" \
      --create-namespace \
      --namespace kube-system \
      --set cluster.name="$cluster_name" \
      --set cluster.id="$cluster_id" \
      --set clustermesh.useAPIServer="$useAPIServer" \
      --set hubble.enabled=true \
      --set hubble.metrics.enabled="{dns,drop,tcp,flow,icmp,http}" \
      --set hubble.relay.enabled=true \
      --set hubble.ui.enabled=true \
      --set identityAllocationMode="$identityAllocationMode" \
      --set ipam.operator.clusterPoolIPv4PodCIDRList[0]="$clusterPoolIPv4PodCIDR" \
      --set operator.replicas=1
    echo "waiting for kube-system daemonset.apps/cilium"
    kubectl --context "$context" -n kube-system rollout status -w --timeout=300s daemonset/cilium
esac

# load balancer
case "$load_balancer" in
  metallb )
    kubectl --context "$context" apply -f ./manifests/metallb-native.yaml
    echo "waiting for metallb-system deployment.apps/controller"
    kubectl --context "$context" -n metallb-system wait deployment controller --for condition=Available=True --timeout=300s
    external_cidr=$(docker network inspect "$context" -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' | head -n1)
    external_gateway=${external_cidr%???}
    first_addr=$(echo "$external_gateway" | awk -F'.' '{ print $1,$2,1,2 }' OFS='.')
    last_addr=$(echo "$external_gateway" | awk -F'.' '{ print $1,$2,255,254 }' OFS='.')
    ingress_range="$first_addr-$last_addr"
    sed "s/{{ .Values.ingressRange }}/$ingress_range/g" ./manifests/metallb-native-postinst.yaml | kubectl --context "$context" apply -f -
    ;;
esac

# ingress-nginx
declare -a ingress_args=()
if [[ "${proxy_protocol}" == "true" ]]; then
  ingress_args+=( --set controller.config.use-proxy-protocol=true )
else
  ingress_args+=( --set controller.config.enable-real-ip=true )
  ingress_args+=( --set "controller.config.proxy-real-ip-cidr=192.168.0.0/16\, 172.16.0.0/12\, 10.0.0.0/8" )
  ingress_args+=( --set controller.config.use-forwarded-headers=true )
fi
controller_affinity_prefix="controller.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions"
helm upgrade --install ingress-nginx ./manifests/ingress-nginx \
  --kube-context "$context" \
  --create-namespace \
  --namespace ingress-nginx \
  --set "${controller_affinity_prefix}[0].key=node-role.kubernetes.io/control-plane" \
  --set "${controller_affinity_prefix}[0].operator=DoesNotExist" \
  --set controller.config.compute-full-forwarded-for=true \
  "${ingress_args[@]}" \
  --set controller.ingressClassResource.default=true \
  --set controller.metrics.enabled=true \
  --set controller.podAnnotations."prometheus\.io/port"="10254" \
  --set controller.podAnnotations."prometheus\.io/scrape"="true" \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443 \
  --set controller.watchIngressWithoutClass=true

echo "waiting for ingress-nginx deployment.apps/ingress-nginx-controller"
kubectl --context "$context" -n ingress-nginx wait deployment ingress-nginx-controller --for condition=Available=True --timeout=300s

# cert-manager
helm upgrade --install cert-manager ./manifests/cert-manager \
  --kube-context "$context" \
  --create-namespace \
  --namespace cert-manager \
  --set installCRDs=true

echo "waiting for cert-manager deployment.apps/cert-manager"
kubectl --context "$context" -n cert-manager wait deployment cert-manager --for condition=Available=True --timeout=300s
sed "s/{{ .Values.name }}/k3d-$cluster_name/g" ./manifests/cert-manager-postinst.yaml | kubectl --context "$context" apply -f -

# detect ingress-nginx service ip address
lb_ip=$(kubectl --context "$context" -n ingress-nginx get svc/ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# default proxy_host to sslip magic domain
sslip_prefix="k3s-$(echo "$cluster_name" | sed -E 's/([0-9])$/\1-/')"
if [[ "$proxy_host" == "" ]]; then
  proxy_host="${sslip_prefix}-${lb_ip//./-}.sslip.io"
fi

# create proxy to access ingress load balancer service
declare -a proxy_args=()
[[ "$proxy_http_port" == "" ]] || proxy_args+=( -p "$proxy_http_port:80" )
[[ "$proxy_tls_port"  == "" ]] || proxy_args+=( -p "$proxy_tls_port:443" )
proxy_args+=( --env "INGRESS_HOST=$lb_ip" )

if [[ "$proxy_protocol" == "true" ]]; then
  if [[ "$proxy_no_labels" == "false" ]]; then
    proxy_args+=( --label "traefik.enable=true" )
    proxy_args+=( --label "traefik.tcp.routers.$proxy_service.rule=HostSNIRegexp(\`$proxy_host\`, \`{subdomain:[a-z0-9_-]+}.$proxy_host\`)" )
    proxy_args+=( --label "traefik.tcp.routers.$proxy_service.entryPoints=$proxy_entrypoint" )
    proxy_args+=( --label "traefik.tcp.routers.$proxy_service.tls.passthrough=true" )
    proxy_args+=( --label "traefik.tcp.services.$proxy_service.loadBalancer.proxyProtocol.version=2" )
    proxy_args+=( --label "traefik.tcp.services.$proxy_service.loadBalancer.server.port=443" )
  fi
  nginx_conf_listen_extra="proxy_protocol"
  nginx_conf_server_extra="
    proxy_protocol on;
    set_real_ip_from 10.0.0.0/8;
    set_real_ip_from 172.16.0.0/12;
    set_real_ip_from 192.168.0.0/16;"
else
  if [[ "$proxy_no_labels" == "false" ]]; then
    proxy_args+=( --label "traefik.enable=true" )
    proxy_args+=( --label "traefik.http.routers.$proxy_service.rule=HostRegexp(\`$proxy_host\`, \`{subdomain:[a-z0-9_-]+}.$proxy_host\`)" )
    proxy_args+=( --label "traefik.http.routers.$proxy_service.entryPoints=$proxy_entrypoint" )
    proxy_args+=( --label "traefik.http.routers.$proxy_service.tls.certResolver=$proxy_certresolver" )
    proxy_args+=( --label "traefik.http.routers.$proxy_service.tls.domains[0].main=$proxy_host" )
    proxy_args+=( --label "traefik.http.routers.$proxy_service.tls.domains[0].sans=*.$proxy_host" )
    proxy_args+=( --label "traefik.http.services.$proxy_service.loadBalancer.server.port=443" )
    proxy_args+=( --label "traefik.http.services.$proxy_service.loadBalancer.server.scheme=https" )
  fi
  nginx_conf_listen_extra=""
  nginx_conf_server_extra=""
fi

declare -a proxy_command=( bash -c "$(cat <<ESH
cat <<EOF >/etc/nginx/nginx.conf
error_log stderr notice;
worker_processes auto;

events {
  multi_accept on;
  use epoll;
  worker_connections 1024;
}

stream {
  upstream 80_tcp {
    server \${INGRESS_HOST}:80;
  }

  server {
    listen 80${nginx_conf_listen_extra};
    proxy_pass 80_tcp;${nginx_conf_server_extra}
  }

  upstream 443_tcp {
    server \${INGRESS_HOST}:443;
  }

  server {
    listen 443${nginx_conf_listen_extra:+ $nginx_conf_listen_extra};
    proxy_pass 443_tcp;${nginx_conf_server_extra}
  }
}
EOF
nginx -g 'daemon off;'
ESH
    )" )

proxy_name="${context}-proxy"
docker rm -f "$proxy_name" 2>/dev/null || true
docker create --name "$proxy_name" --restart=always --network="$context" "${proxy_args[@]}" nginx "${proxy_command[@]}"
docker start "$proxy_name"

# determine host ip address
host_ip=$(ifconfig | perl -0777 -pe 's/\n+^[ \t]/ /gm' | grep 'inet ' | grep RUNNING | grep -v LOOPBACK \
  | sed -nE 's/.* inet ([^ ]+).*/\1/p' | grep -vE '\.1$')

host_domain="${sslip_prefix}-${host_ip//./-}.sslip.io"

# kubernetes dashboard
kubectl --context "$context" apply -f ./manifests/kubernetes-dashboard.yaml
sed "s/{{ .Values.domain1 }}/$proxy_host/g" ./manifests/kubernetes-dashboard-postinst.yaml\
  | sed "s/{{ .Values.domain2 }}/$host_domain/g" \
  | kubectl --context "$context" apply -f -

# prometheus
helm upgrade --install prometheus ./manifests/prometheus \
  --kube-context "$context" \
  --create-namespace \
  --namespace prometheus

# print endpoints
cat <<YML

---
dashboard:
  token: $(kubectl --context "$context" -n kubernetes-dashboard create token admin-user)
  urls:
    - https://console.$proxy_host/#login
YML
if [[ "$proxy_tls_port" != "" ]]; then
  cat <<YML
    - https://console.$host_domain:$proxy_tls_port/#login
YML
fi
