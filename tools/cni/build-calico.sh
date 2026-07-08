#!/usr/bin/env bash
set -euo pipefail

CALICO_DIR="templates/manifests/cni/calico"
HELM_REPO="https://docs.tigera.io/calico/charts"
NAMESPACE="tigera-operator"
DEPLOYMENT_FILE="03-tigera-operator.yaml"

VALUES_DEFAULT=$(cat <<'EOF'
installation:
  enabled: false

# apiServer configures the Calico API server, needed for interacting with
# the projectcalico.org/v3 suite of APIs.
apiServer:
  enabled: false

# goldmane configures the Calico Goldmane flow aggregator.
goldmane:
  enabled: false

# whisker configures the Calico Whisker observability UI.
whisker:
  enabled: false

# Affinity for the tigera-operator pod.
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: node-role.kubernetes.io/CONTROLPLANE_NODESELECTOR
              operator: Exists

  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              k8s-app: tigera-operator
          topologyKey: kubernetes.io/hostname
EOF
)

usage() {
    echo "Usage: $0 <chart-version> [--clean]"
    echo ""
    echo "  chart-version   Tigera operator Helm chart version (e.g. v3.32.0)"
    echo "  --clean         Remove existing version directory before generating"
    echo ""
    echo "Examples:"
    echo "  $0 v3.32.0          Generate manifests for v3.32.0"
    echo "  $0 v3.33.0 --clean  Regenerate v3.33.0 from scratch"
    echo ""
    echo "After running, update defaults/main.yml:"
    echo "  kubernetes_calico_chart_version: \"<version>\""
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

VERSION="${1}"
CLEAN=false

if [[ "${2:-}" == "--clean" ]]; then
    CLEAN=true
fi

VERSION_DIR="${CALICO_DIR}/${VERSION}"
MANIFESTS_DIR="${VERSION_DIR}/manifests/tigera-operator/templates/tigera-operator"

echo "==> Calico chart version: ${VERSION}"

if [[ "${CLEAN}" == true ]] && [[ -d "${VERSION_DIR}" ]]; then
    echo "==> Removing existing ${VERSION_DIR}..."
    rm -rf "${VERSION_DIR}"
fi

mkdir -p "${VERSION_DIR}"

# values.yaml
if [[ -f "${VERSION_DIR}/values.yaml" ]]; then
    echo "==> Using existing values.yaml"
else
    echo "==> Creating default values.yaml"
    echo "${VALUES_DEFAULT}" > "${VERSION_DIR}/values.yaml"
fi

# Helm repo
echo "==> Updating Helm repo..."
helm repo add tigera "${HELM_REPO}" 2>/dev/null || true
helm repo update tigera

# Generate manifests
echo "==> Generating manifests..."
cd "${VERSION_DIR}"
helm template tigera-operator tigera/tigera-operator \
    --version "${VERSION}" \
    -f values.yaml \
    --namespace "${NAMESPACE}" \
    --output-dir manifests
cd - > /dev/null

# Remove Helm hook files (only meaningful with helm uninstall)
for f in "${MANIFESTS_DIR}"/00-uninstall.yaml; do
    if [[ -f "${f}" ]]; then
        echo "==> Removing Helm hook: $(basename "${f}")"
        rm "${f}"
    fi
done

# Create namespace manifest
echo "==> Creating namespace manifest..."
cat > "${MANIFESTS_DIR}/00-namespace-tigera-operator.yaml" << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: tigera-operator
  labels:
    name: tigera-operator
    pod-security.kubernetes.io/enforce: privileged
EOF

# Replace image with Jinja2, rename to 03- prefix and add .j2 extension
DEPLOYMENT_SRC="${MANIFESTS_DIR}/02-tigera-operator.yaml"
DEPLOYMENT_DST="${MANIFESTS_DIR}/${DEPLOYMENT_FILE}.j2"

if [[ -f "${DEPLOYMENT_SRC}" ]]; then
    echo "==> Injecting Jinja2 image variables..."
    IMAGE_TAG=$(sed -n 's|.*image: quay.io/tigera/operator:\(.*\)|\1|p' "${DEPLOYMENT_SRC}")
    sed -i '' 's|image: quay.io|image: {{ kubernetes_calico_cni_image_repository }}|' "${DEPLOYMENT_SRC}"
    sed -i '' 's|node-role.kubernetes.io/CONTROLPLANE_NODESELECTOR|node-role.kubernetes.io/{{ kubernetes_calico_controlplane_nodeselector }}|' "${DEPLOYMENT_SRC}"
    mv "${DEPLOYMENT_SRC}" "${DEPLOYMENT_DST}"
    echo ""
    echo "==> Image tag for this chart: ${IMAGE_TAG}"
else
    echo "WARNING: Deployment file not found at ${DEPLOYMENT_SRC}"
    IMAGE_TAG="unknown"
fi

echo ""
echo "==> Done! Files in ${VERSION_DIR}/:"
find "${VERSION_DIR}" -type f | sort | sed "s|${VERSION_DIR}/||"
echo ""
echo "==> Update defaults/main.yml:"
echo "    kubernetes_calico_chart_version: \"${VERSION}\""
