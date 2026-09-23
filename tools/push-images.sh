#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULTS_FILE="${ROLE_DIR}/defaults/main.yml"
CALICO_DIR="${ROLE_DIR}/templates/manifests/cni/calico"
TRAEFIK_DIR="${ROLE_DIR}/templates/manifests/ingress/traefik"

CALICO_LINUX_IMAGES=(
    "calico/typha"
    "calico/node"
    "calico/cni"
    "calico/csi"
    "calico/node-driver-registrar"
    "calico/apiserver"
    "calico/kube-controllers"
    "calico/envoy-gateway"
    "calico/envoy-proxy"
    "calico/envoy-ratelimit"
    "calico/dikastes"
    "calico/pod2daemon-flexvol"
    "calico/key-cert-provisioner"
    "calico/goldmane"
    "calico/whisker"
    "calico/whisker-backend"
)

get_default() {
    local var="$1"
    grep "^${var}:" "${DEFAULTS_FILE}" 2>/dev/null | head -1 \
        | sed 's/^[^:]*: *//' | tr -d '"' | sed 's/ *#.*//' | awk '{$1=$1};1'
}

IMAGES=()
DRY_RUN=false
K8S_VERSION=""
CALICO_VERSION=""

usage() {
    cat <<EOF
Usage: $(basename "$0") <target-registry> [component...] [options]

Push container images used by the kubernetes ansible role to a private registry.

Components:
  k8s       Core k8s images pinned by the exact kubeadm version:
            control-plane (apiserver, controller-manager, scheduler, proxy),
            etcd, coredns, pause
  calico    Tigera operator + Calico CNI images
  metrics   metrics-server
  dns       NodeLocal DNS cache
  csr       kubelet-csr-approver
  ingress   Traefik ingress controller
  all       All components (default)

Options:
  --k8s-version VER       Full k8s version for core images (e.g. 1.33.3)
  --calico-version VER    Calico chart version (default: from defaults/main.yml)
  --dry-run               Print image list without pushing

Examples:
  $(basename "$0") harbor.company.local --dry-run
  $(basename "$0") harbor.company.local calico
  $(basename "$0") harbor.company.local k8s --k8s-version 1.33.3
  $(basename "$0") harbor.company.local all --k8s-version 1.33.3

Note: etcd/coredns/pause tags are baked into the kubeadm BINARY, not into
--kubernetes-version. The script runs kubeadm of exactly the requested
version: the local binary when its version matches, otherwise the official
binary downloaded from dl.k8s.io and executed in a docker container
(the temporary binary is removed on exit).
EOF
}

add_image() {
    IMAGES+=("$1")
}

# -- k8s: images pinned by the kubeadm binary of the exact version
KUBEADM_TMPDIR=""
KUBEADM_PINS=()
cleanup() {
    if [[ -n "${KUBEADM_TMPDIR}" && -d "${KUBEADM_TMPDIR}" ]]; then
        rm -rf "${KUBEADM_TMPDIR}"
    fi
}
# preserve the exit status through the cleanup trap
trap 'rc=$?; cleanup; exit "${rc}"' EXIT

# Runs in the main shell process: fills KUBEADM_PINS so that failures exit
# the script and the cleanup trap sees the temp dir
resolve_kubeadm_pins() {
    local ver="$1" vver="v$1"
    KUBEADM_PINS=()

    # fast path: local kubeadm of exactly this version
    if command -v kubeadm >/dev/null 2>&1; then
        if [[ "$(kubeadm version -o short 2>/dev/null)" == "${vver}" ]]; then
            local line
            while read -r line; do
                [[ -n "${line}" ]] && KUBEADM_PINS+=("${line}")
            done < <(kubeadm config images list --kubernetes-version "${vver}" --image-repository registry.k8s.io)
            return 0
        fi
        echo "==> Local kubeadm is not ${vver}, using an exact-version binary in docker" >&2
    fi

    command -v docker >/dev/null 2>&1 \
        || { echo "ERROR: docker is required to run kubeadm ${vver}" >&2; exit 1; }

    local arch
    case "$(uname -m)" in
        x86_64)        arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) echo "ERROR: unsupported architecture $(uname -m)" >&2; exit 1 ;;
    esac

    KUBEADM_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/push-images.XXXXXX")"
    local bin="${KUBEADM_TMPDIR}/kubeadm"
    local list="${KUBEADM_TMPDIR}/images.txt"
    local base="https://dl.k8s.io/${vver}/bin/linux/${arch}"

    echo "==> Downloading kubeadm ${vver} (linux/${arch})" >&2
    curl -fsSL "${base}/kubeadm" -o "${bin}" \
        || { echo "ERROR: failed to download ${base}/kubeadm" >&2; exit 1; }
    curl -fsSL "${base}/kubeadm.sha256" -o "${KUBEADM_TMPDIR}/kubeadm.sha256" \
        || { echo "ERROR: failed to download ${base}/kubeadm.sha256" >&2; exit 1; }

    (
        cd "${KUBEADM_TMPDIR}"
        sha256sum -c kubeadm.sha256 >/dev/null 2>&1 \
            || shasum -a 256 -c kubeadm.sha256 >/dev/null 2>&1
    ) || { echo "ERROR: kubeadm checksum mismatch" >&2; exit 1; }

    chmod +x "${bin}"
    # kubeadm is a static binary; `config images list` is client-side only
    docker run --rm --platform "linux/${arch}" -v "${bin}:/kubeadm:ro" alpine:3 \
        /kubeadm config images list --kubernetes-version "${vver}" \
        --image-repository registry.k8s.io > "${list}" \
        || { echo "ERROR: kubeadm ${vver} failed to list images" >&2; exit 1; }

    local line
    while read -r line; do
        [[ -n "${line}" ]] && KUBEADM_PINS+=("${line}")
    done < "${list}"
}

add_k8s_images() {
    resolve_kubeadm_pins "$1"
    local img
    for img in "${KUBEADM_PINS[@]}"; do
        add_image "${img}"
    done
}

# -- calico: operator + CNI images
add_calico_images() {
    local calico_ver="$1"

    local manifest="${CALICO_DIR}/${calico_ver}/manifests/tigera-operator/templates/tigera-operator/03-tigera-operator.yaml.j2"
    if [[ ! -f "${manifest}" ]]; then
        echo "ERROR: ${manifest} not found."
        echo "Run tools/cni/build-calico.sh ${calico_ver} first."
        exit 1
    fi

    local operator_tag
    operator_tag=$(sed -n 's|.*tigera/operator:\(.*\)|\1|p' "${manifest}" | head -1)

    add_image "quay.io/tigera/operator:${operator_tag}"
    for img in "${CALICO_LINUX_IMAGES[@]}"; do
        add_image "quay.io/${img}:${calico_ver}"
    done
}

# Resolve {{ kubernetes_image_repository }} in Jinja2 values
resolve_image_repo() {
    local value="$1"
    local base
    base=$(get_default kubernetes_image_repository)
    echo "${value//\{\{ kubernetes_image_repository \}\}/${base}}"
}

# -- metrics-server
add_metrics_images() {
    local repo tag
    repo=$(resolve_image_repo "$(get_default kubernetes_extensions_metrics_server_image_repo)")
    tag=$(get_default kubernetes_extensions_metrics_server_image_tag)
    add_image "${repo}:${tag}"
}

# -- NodeLocal DNS
add_dns_images() {
    local repo tag
    repo=$(resolve_image_repo "$(get_default kubernetes_extensions_node_local_dns_image_repo)")
    tag=$(get_default kubernetes_extensions_node_local_dns_image_tag)
    add_image "${repo}:${tag}"
}

# -- kubelet-csr-approver
add_csr_images() {
    local repo tag
    repo=$(get_default kubernetes_extensions_kubelet_csr_approver_image_repo)
    tag=$(get_default kubernetes_extensions_kubelet_csr_approver_image_tag)
    add_image "${repo}:${tag}"
}

# -- ingress: traefik (source: docker.io, tag from generated manifest)
add_ingress_images() {
    local traefik_ver
    traefik_ver=$(get_default kubernetes_extensions_traefik_chart_version)

    local manifest="${TRAEFIK_DIR}/${traefik_ver}/manifests/traefik/templates/03-deployment.yaml.j2"
    if [[ ! -f "${manifest}" ]]; then
        echo "ERROR: ${manifest} not found."
        echo "Run tools/ingress/build-traefik.sh ${traefik_ver} first."
        exit 1
    fi

    local tag
    tag=$(sed -n 's|.*traefik:\(.*\)|\1|p' "${manifest}" | head -1)
    add_image "docker.io/traefik:${tag}"
}

# -- Parse arguments
TARGET_REGISTRY=""
COMPONENTS=()

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)        DRY_RUN=true; shift ;;
        --k8s-version)    K8S_VERSION="$2"; shift 2 ;;
        --calico-version) CALICO_VERSION="$2"; shift 2 ;;
        --help|-h)        usage; exit 0 ;;
        -*)               echo "Unknown option: $1"; usage; exit 1 ;;
        *)
            if [[ -z "${TARGET_REGISTRY}" ]]; then
                TARGET_REGISTRY="$1"
            else
                COMPONENTS+=("$1")
            fi
            shift
            ;;
    esac
done

if [[ -z "${TARGET_REGISTRY}" ]]; then
    echo "ERROR: target-registry is required"
    exit 1
fi

if [[ ${#COMPONENTS[@]} -eq 0 ]]; then
    COMPONENTS=(k8s calico metrics dns csr ingress)
fi

# -- Build image list
for comp in "${COMPONENTS[@]}"; do
    case "$comp" in
        k8s)
            if [[ -z "${K8S_VERSION}" ]]; then
                echo "WARNING: --k8s-version not set, skipping k8s images"
            else
                add_k8s_images "${K8S_VERSION}"
            fi
            ;;
        calico)
            CALICO_VERSION="${CALICO_VERSION:-$(get_default kubernetes_calico_chart_version)}"
            add_calico_images "${CALICO_VERSION}"
            ;;
        metrics)  add_metrics_images  ;;
        dns)      add_dns_images      ;;
        csr)      add_csr_images      ;;
        ingress)  add_ingress_images  ;;
        all)
            if [[ -n "${K8S_VERSION}" ]]; then add_k8s_images "${K8S_VERSION}"; fi
            CALICO_VERSION="${CALICO_VERSION:-$(get_default kubernetes_calico_chart_version)}"
            add_calico_images "${CALICO_VERSION}"
            add_metrics_images
            add_dns_images
            add_csr_images
            add_ingress_images
            ;;
        *)
            echo "ERROR: Unknown component: ${comp}"
            usage
            exit 1
            ;;
    esac
done

# -- Summary
echo "==> Target: ${TARGET_REGISTRY}"
echo "==> Images: ${#IMAGES[@]}"
echo ""

# -- Push
i=0
for src in "${IMAGES[@]}"; do
    i=$((i + 1))
    dst="${TARGET_REGISTRY}/${src#*/}"
    echo "  [${i}/${#IMAGES[@]}] ${src} -> ${dst}"

    if [[ "${DRY_RUN}" == true ]]; then
        continue
    fi

    docker pull "${src}"
    docker tag "${src}" "${dst}"
    docker push "${dst}"
done

echo ""
if [[ "${DRY_RUN}" == true ]]; then
    echo "==> Dry run complete. ${#IMAGES[@]} images."
else
    echo "==> Done! ${#IMAGES[@]} images pushed to ${TARGET_REGISTRY}"
fi
