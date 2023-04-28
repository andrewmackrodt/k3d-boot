#!/bin/bash
set -euo pipefail
cd "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)"

case "$(uname -s)" in
  Darwin )
    platform="mac"
    ;;
  Linux )
    platform="linux"
    ;;
  * )
    echo "error: unsupported OS $(uname -s)" >&2
    exit 1
esac

declare -a params=()
declare -a required_params=()

exit_with_error() {
  echo -ne "\033[31m" >&2
  echo "error: $1" >&2
  echo -ne "\033[0m" >&2
  exit "${2:-1}"
}

exit_with_usage_error() {
  display_usage >&2
  echo "" >&2
  exit_with_error "$@"
}

set_param_once() {
  if [[ "${!1:-}" != "" ]]; then
    exit_with_error "invalid command: --${1//_/-} can not be specified more than once"
  fi
  local args=( "$@" )
  if [[ "${#args[@]}" -lt 3 ]]; then
    exit_with_error "missing argument: --${1//_/-} <>"
  fi
  if [[ "${args[2]}" == "" ]]; then
    if [[ "${required_params[*]}" =~ " $1 " ]]; then
      exit_with_error "invalid command: --${1//_/-} cannot be empty"
    fi
    local default_key="default_${1}"
    if [[ "${!default_key:-}" != "" ]]; then
      unset "$default_key"
    fi
  fi
  printf -v "$1" "%s" "${args[2]}"
}

set_default_params() {
  local default_key
  for k in "${params[@]}"; do
    if [[ "${!k}" == "" ]]; then
      default_key="default_${k}"
      if [[ "${!default_key:-}" != "" ]]; then
        printf -v "$k" "%s" "${!default_key}"
      fi
    fi
  done
  if [[ $(type -t _set_default_params) != "" ]]; then
    _set_default_params
  fi
}

validate_params() {
  for k in "${required_params[@]}"; do
    if [[ "${!k}" == "" ]]; then
      exit_with_usage_error "--${k//_/-} cannot be empty"
    fi
  done
  if [[ $(type -t _validate_params) != "" ]]; then
    _validate_params
  fi
}

print_params() {
  for k in "${params[@]}"; do
    echo "${k//_/ }: ${!k:-~}"
  done
}

error_reporter() {
  echo -e "\n\033[91merror: failed with status $? at line $1:\033[0m" >&2
  awk 'NR>L-3 && NR<L+2 { printf "%s%-5d %s%s\n",(NR==L?"\033[91m> ":"\033[90m  "),NR,$0,"\033[0m" }' "L=$1" "$0" >&2
}
