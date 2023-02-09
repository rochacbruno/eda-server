#!/usr/bin/env bash
set -o errexit
set -o pipefail
set -o nounset

SCRIPTS_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PROJECT_DIR="${SCRIPTS_DIR}/.."

CMD=${1:-help}
VERSION=${2:-'latest'}


export DEBUG=${DEBUG:-false}

# import common & logging
source "${SCRIPTS_DIR}"/common/logging.sh
source "${SCRIPTS_DIR}"/common/utils.sh

trap handle_errors ERR

handle_errors() {
  log-err "An error occurred on or around line ${BASH_LINENO[0]}. Unable to continue."
  exit 1
}

# deployment dir
DEPLOY_DIR="${PROJECT_DIR}"/tools/deploy

# minikube namespace
NAMESPACE=${NAMESPACE:-aap-eda}

usage() {
    log-info "Usage: $(basename "$0") <command> [command_arg]"
    log-info ""
    log-info "commands:"
    log-info "\t build <version>              build and push image to minikube"
    log-info "\t deploy <version>             build deployment and deploy to minikube"
    log-info "\t clean                        remove deployment directory and all EDA resource from minikube"
    log-info "\t port-forward-api             forward local port to EDA API (default: 8000)"
    log-info "\t port-forward-ui              forward local port to EDA UI (default: 8080)"
    log-info "\t eda-api-logs                 get eda-api pod logs"
    log-info "\t help                         show usage"
}

help() {
    usage
}

build-deployment() {
  local _api_image="aap-eda:${1}"
  local _ngx_image="eda-nginx:${1}"
  local _temp_dir="${DEPLOY_DIR}"/temp

  log-info "Using Deployment Directory: ${DEPLOY_DIR}/temp"

  if [ -d "${_temp_dir}" ]; then
    rm -rf "${_temp_dir}"
  fi
  mkdir "${_temp_dir}"

  cd "${DEPLOY_DIR}"/eda-api
  log-debug "kustomize edit set image aap-eda=${_api_image}"
  kustomize edit set image aap-eda="${_api_image}"

  cd "${DEPLOY_DIR}"/nginx
  log-debug "kustomize edit set image eda-nginx=${_ngx_image}"
  kustomize edit set image ngx-server="${_ngx_image}"

  cd "${PROJECT_DIR}"
  log-debug "kustomize build ${DEPLOY_DIR} -o ${DEPLOY_DIR}/temp"
  kustomize build "${DEPLOY_DIR}" -o "${DEPLOY_DIR}/temp"
}

build-eda-image() {
  local _image="aap-eda:${1}"

  log-info "Building aap-eda image"
  log-debug "minikube image build . -t ${_image} -f tools/docker/Dockerfile"
  minikube image build . -t "${_image}" -f tools/docker/Dockerfile
}

build-nginx-image() {
  local _image="eda-nginx:${1}"
  local _temp_dir=./tmp

  if [ -d "${_temp_dir}" ]; then
    rm -rf "${_temp_dir}"
  fi
  mkdir "${_temp_dir}"

  log-info "Clone ansible-ui"
  log-debug "git clone git@github.com:ansible/ansible-ui.git ${_temp_dir}/ansible-ui"
  git clone git@github.com:ansible/ansible-ui.git "${_temp_dir}"/ansible-ui

  log-info "Build eda-nginx image"
  log-debug "minikube image build . -t ${_image} -f tools/docker/nginx/Dockerfile"
  minikube image build . -t "${_image}" -f tools/docker/nginx/Dockerfile
  rm -rf "${_temp_dir}"
}

build-all() {
  build-eda-image "${1}"
  build-nginx-image "${1}"
  build-deployment "${1}"
}

remove-image() {
  local _image_name="${1}"

  if minikube image ls | grep "${_image_name}" &> /dev/null; then
    log-info "Removing image ${_image_name} from minikube registry"
    log-debug "minikube image rm ${_image_name}"
    minikube image rm "${_image_name}"
  fi
}

remove-deployment-tempdir() {
  if [ -d "${DEPLOY_DIR}"/temp ]; then
    log-debug "rm -rf ${DEPLOY_DIR}/temp"
    rm -rf "${DEPLOY_DIR}"/temp
  else
    log-debug "${DEPLOY_DIR}/temp does not exist"
  fi
}

deploy() {
  local _image="${1}"

  if [ -d "${DEPLOY_DIR}"/temp ]; then
    if ! kubectl get ns -o jsonpath='{..name}'| grep "${NAMESPACE}" &> /dev/null; then
      log-debug "kubectl create namespace ${NAMESPACE}"
      kubectl create namespace "${NAMESPACE}"
    fi

    kubectl config set-context --current --namespace="${NAMESPACE}"

    log-info "deploying eda to ${NAMESPACE}"
    log-debug "kubectl apply -f ${DEPLOY_DIR}/temp"
    kubectl apply -f "${DEPLOY_DIR}"/temp

  else
    log-err "You must run 'minikube:build' before running minikube:deploy"
  fi
}

clean-deployment() {
  log-info "cleaning minikube deployment..."
  if kubectl get ns -o jsonpath='{..name}'| grep "${NAMESPACE}" &> /dev/null; then
    log-debug "kubectl delete all -l 'app in (eda)' -n ${NAMESPACE}"
    kubectl delete all -l 'app in (eda)' -n "${NAMESPACE}"
    log-debug "kubectl delete pvc --all --grace-period=0 --force -n ${NAMESPACE}"
    kubectl delete pvc --all --grace-period=0 --force -n "${NAMESPACE}"
    log-debug "kubectl delete pv --all --grace-period=0 --force -n ${NAMESPACE}"
    kubectl delete pv --all --grace-period=0 --force -n "${NAMESPACE}"
  else
    log-debug "${NAMESPACE} does not exist"
  fi

  for image in  redis:7 postgres:13 aap-eda:latest eda-nginx:latest; do
    remove-image "${image}"
  done

  remove-deployment-tempdir
}

port-forward() {
  local _svc_name=${1}
  local _local_port=${2}
  local _svc_port=${3}

  log-info "kubectl port-forward svc/${_svc_name} ${_local_port}:${_svc_port}"
  kubectl port-forward "svc/${_svc_name}" "${_local_port}":"${_svc_port}"
}

port-forward-ui() {
  local _local_port=${1}
  local _svc_name=eda-ui
  local _svc_port=8080

  log-debug "port-forward ${_svc_name} ${_local_port} ${_svc_port}"
  port-forward "${_svc_name}" "${_local_port}" "${_svc_port}"
}

port-forward-api() {
  local _local_port=${1}
  local _svc_name=eda-api
  local _svc_port=8000

  log-debug "port-forward ${_svc_name} ${_local_port} ${_svc_port}"
  port-forward "${_svc_name}" "${_local_port}" "${_svc_port}"
}

get-eda-api-logs() {
  local _pod_name=$(kubectl get pod -l comp=api -o jsonpath="{.items[0].metadata.name}")

  log-debug "kubectl logs ${_pod_name} -f"
  kubectl logs "${_pod_name}" -f
}

#
# execute
#
case ${CMD} in
  "build") build-all "${VERSION}" ;;
  "clean") clean-deployment "${VERSION}";;
  "deploy") deploy "${VERSION}" ;;
  "port-forward-api") port-forward-api 8000 ;;
  "port-forward-ui") port-forward-ui 8080 ;;
  "add-dev-user") add-dev-user ;;
  "load-rbac-data") load-rbac-data ;;
  "eda-api-logs") get-eda-api-logs ;;
  "help") usage ;;
   *) usage ;;
esac
