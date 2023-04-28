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

docker rm -fv "k3d-${cluster_name}-proxy" || true
k3d cluster delete "$cluster_name" || true
