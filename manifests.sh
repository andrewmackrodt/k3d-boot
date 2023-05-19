#!/bin/bash
set -euo pipefail
cd "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)"
cd manifests

curl_download() {
  echo "downloading kubectl config: $2"
  curl -fsSL "$1" -o "./$2"
}

helm_download() {
  local repo
  local chart
  local directory
  if [[ "${2:-}" != "" ]]; then
    if [[ "$2" =~ / ]]; then
      repo=$(echo "$2" | sed -E 's#/.*$##')
      chart="$2"
    else
      repo="$2"
      chart="$repo/$repo"
    fi
    if ! helm repo list | grep -qE "^$repo\b"; then
      helm repo add "$repo" "$1"
    fi
    directory=$(basename "$2")
  else
    repo=$(basename "$1")
    chart="$1"
    directory=$(basename "$1")
  fi
  echo "pulling helm chart: $chart"
  if [[ -d "$directory" ]]; then
    rm -rf "./$directory"
  fi
  helm pull "$chart" --untar
}

helm_download "https://helm.cilium.io/" cilium
curl_download "https://k3d.io/v5.4.3/usage/advanced/calico.yaml" calico.yaml
patch calico.yaml calico.patch
curl_download "https://raw.githubusercontent.com/metallb/metallb/v0.13.9/config/manifests/metallb-native.yaml" metallb-native.yaml
helm_download "https://kubernetes.github.io/ingress-nginx/" ingress-nginx
helm_download "https://charts.jetstack.io" jetstack/cert-manager
curl_download "https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml" kubernetes-dashboard.yaml
