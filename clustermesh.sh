#!/bin/bash
set -euo pipefail
cd "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)"

. functions.sh

# define name of clusters and contexts
cluster_name_1="eu-west-1"
cluster_name_2="eu-west-2"
context_1="k3d-$cluster_name_1"
context_2="k3d-$cluster_name_2"

if ! cilium version >/dev/null 2>&1; then
  exit_with_error "cilium-cli not found"
fi

cleanup() {
  set +e
  [[ "${bridge_name:-}" == "" ]] || docker rm -f "$bridge_name"
  ./destroy.sh -n "$cluster_name_1"
  ./destroy.sh -n "$cluster_name_2"
  set -e
}

trap cleanup exit

trap 'error_reporter $LINENO' ERR

# create clusters
./create.sh -n "$cluster_name_1" -i 1 -a 6443 -t 8443 -p '' &
./create.sh -n "$cluster_name_2" -i 2 -a 6444 -t 8444 -p '' &

wait

# enable intra-cluster node communication
if [[ "$platform" == "linux" ]]; then
  br1="br-$(docker network ls | awk '$2 == "'"$context_1"'" { print $1 }')"
  br2="br-$(docker network ls | awk '$2 == "'"$context_2"'" { print $1 }')"
  sudo iptables -I DOCKER-USER -i "$br1" -o "$br2" -j ACCEPT
  sudo iptables -I DOCKER-USER -i "$br2" -o "$br1" -j ACCEPT
else
  bridge_name="k3d-bridge_${cluster_name_1}_${cluster_name_2}"
  docker create --network="$context_1" --name "$bridge_name" alpine ash -c 'sleep inf'
  docker network connect "$context_2" "$bridge_name"
  docker start "$bridge_name"
  cluster_subnet_1=$(docker network inspect "$context_1" -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' | head -n1)
  cluster_subnet_2=$(docker network inspect "$context_2" -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' | head -n1)

  bridge_ip_1=$(docker inspect "$bridge_name" -f '{{range.NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' | head -n1)
  for node in $(k3d node list | awk '$3 == "'"$cluster_name_1"'" && $2 != "" { print $1 }'); do
    docker exec "$node" iptables -A INPUT -s "$cluster_subnet_1" -d "$cluster_subnet_2" -j ACCEPT
    docker exec "$node" ip route add "$cluster_subnet_2" via "$bridge_ip_1"
  done

  bridge_ip_2=$(docker inspect "$bridge_name" -f '{{range.NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' | tail -n+2 | head -n1)
  for node in $(k3d node list | awk '$3 == "'"$cluster_name_2"'" && $2 != "" { print $1 }'); do
    docker exec "$node" iptables -A INPUT -s "$cluster_subnet_2" -d "$cluster_subnet_1" -j ACCEPT
    docker exec "$node" ip route add "$cluster_subnet_1" via "$bridge_ip_2"
  done
fi

# connect servers
cilium clustermesh connect --context "$context_1" --destination-context "$context_2"

# wait for clustermesh
clustermesh_status=1
for _ in $(seq 1 12); do
  if cilium clustermesh status; then
    clustermesh_status=0
    break
  fi
  sleep 5
done
if [[ $clustermesh_status -ne 0 ]]; then
  exit_with_error "failed to create clustermesh"
fi

# install example global service deployments
kubectl --context "$context_1" apply -f https://raw.githubusercontent.com/cilium/cilium/v1.15.2/examples/kubernetes/clustermesh/global-service-example/cluster1.yaml
kubectl --context "$context_2" apply -f https://raw.githubusercontent.com/cilium/cilium/v1.15.2/examples/kubernetes/clustermesh/global-service-example/cluster2.yaml

# wait for deployments to be ready
kubectl --context "$context_1" wait deployment x-wing --for condition=Available=True --timeout=120s
kubectl --context "$context_2" wait deployment x-wing --for condition=Available=True --timeout=120s

# select a pod to execute commands with
pod=$(kubectl --context "$context_1" get pods -l name=x-wing -o name | cut -d/ -f2 | head -n1)

# make 10 requests to determine if requests are served from both clusters
for _ in $(seq 1 10); do
  kubectl --context "$context_1" exec -ti "$pod" -- curl rebel-base
done
