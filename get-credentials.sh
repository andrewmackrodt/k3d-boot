#!/bin/bash
set -euo pipefail
cd "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)"

. functions.sh

default_cluster_name="default"
cluster_name=""
params+=( cluster_name )
required_params+=( cluster_name )

display_usage() {
  local script_name
  script_name=$(basename "${BASH_SOURCE[0]}")
  cat <<EOF
Usage:
  ./$script_name [options]

Options:
  -n, --cluster-name <>        cluster name (default: "$default_cluster_name")
  -h, --help                   display help
EOF
}

get_params() {
  while (( "$#" )); do
    [[ $1 == --*=* ]] && set -- "${1%%=*}" "${1#*=}" "${@:2}"
    case "$1" in
      -n | --cluster-name ) set_param_once cluster_name "$@"; shift ;;
      -h | --help ) display_usage; exit ;;
      -* ) exit_with_usage_error "unsupported option: $1" ;;
      *  ) exit_with_usage_error "unsupported argument: $1" ;;
    esac
    shift
  done
}

get_params "$@"
set_default_params
validate_params

trap 'error_reporter $LINENO' ERR

context="k3d-${cluster_name}"

hostnames=$( \
    kubectl --context "$context" -n kubernetes-dashboard get ingress/kubernetes-dashboard -o jsonpath='{.spec.tls[0].hosts}' \
      | sed -E 's/"|\[|\]//g' \
      | tr ',' $'\n' \
      | tail -n+2 \
      | sed -E 's/^console\.//'
  )

proxy_host=$(echo "$hostnames" | head -n1)
host_domain=$(echo "$hostnames" | tail -n1)

proxy_tls_port=$( \
    docker inspect k3d-default-proxy \
      -f '{{ (index (index .NetworkSettings.Ports "443/tcp") 0).HostPort }}' 2>/dev/null \
    || true \
  )

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
cat <<YML

grafana:
  password: $(kubectl --context "$context" -n monitoring get secret prometheus-operator-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
  urls:
    - https://grafana.$proxy_host/
YML
if [[ "$proxy_tls_port" != "" ]]; then
  cat <<YML
    - https://grafana.$host_domain:$proxy_tls_port/
YML
fi
