#!/usr/bin/env bash
# offline-prep.sh
# Run this script on an INTERNET-CONNECTED machine to download all artifacts
# needed for an air-gapped deployment of the observability dashboard.
#
# Artifacts downloaded:
#   - Container images: Grafana, Prometheus, Loki, Promtail (saved as .tar.gz)
#   - node_exporter binaries: Linux amd64 and arm64
#   - windows_exporter MSI: amd64
#   - Promtail binaries: Linux amd64, arm64, and Windows amd64
#   - NSSM (Non-Sucking Service Manager) for Windows service registration
#   - Ansible Galaxy collections (for air-gapped controller)
#   - podman-compose pip wheels (for air-gapped monitoring server)
#
# Output directory: ./offline-packages/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/../offline-packages"

# ── Versions ─────────────────────────────────────────────────────────────────
GRAFANA_VERSION="${GRAFANA_VERSION:-latest}"
PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-latest}"
LOKI_VERSION="${LOKI_VERSION:-latest}"
PROMTAIL_VERSION="${PROMTAIL_VERSION:-3.0.0}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.8.2}"
WINDOWS_EXPORTER_VERSION="${WINDOWS_EXPORTER_VERSION:-0.29.2}"
NSSM_VERSION="${NSSM_VERSION:-2.24}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Detect container runtime ──────────────────────────────────────────────────
if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD=podman
  info "Using Podman as container runtime."
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD=docker
  warn "Podman not found — falling back to Docker for image pull/save."
else
  error "Neither podman nor docker is installed. Install one before running this script."
  exit 1
fi

# ── Pre-flight ────────────────────────────────────────────────────────────────
command -v curl    >/dev/null 2>&1 || { error "curl is required but not installed."; exit 1; }

info "Creating output directories..."
mkdir -p "${OUTPUT_DIR}/docker-images"
mkdir -p "${OUTPUT_DIR}/node_exporter"
mkdir -p "${OUTPUT_DIR}/windows_exporter"
mkdir -p "${OUTPUT_DIR}/promtail"
mkdir -p "${OUTPUT_DIR}/nssm"
mkdir -p "${OUTPUT_DIR}/pip-packages"

MANIFEST_FILE="${OUTPUT_DIR}/MANIFEST.txt"
echo "# Offline Package Manifest" > "${MANIFEST_FILE}"
echo "# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "${MANIFEST_FILE}"
echo "# Script: offline-prep.sh" >> "${MANIFEST_FILE}"
echo >> "${MANIFEST_FILE}"

###############################################################################
# Helper: download with retry
###############################################################################
download() {
  local url="$1" dest="$2" desc="${3:-$1}"
  if [[ -f "$dest" ]]; then
    warn "Already exists, skipping: $(basename "$dest")"
    return 0
  fi
  info "Downloading ${desc}..."
  curl -fsSL --retry 3 --retry-delay 5 --progress-bar -o "${dest}.tmp" "$url"
  mv "${dest}.tmp" "$dest"
  success "Downloaded: $(basename "$dest") ($(du -sh "$dest" | cut -f1))"
  echo "$(basename "$dest")  $(sha256sum "$dest" | cut -d' ' -f1)" >> "${MANIFEST_FILE}"
}

###############################################################################
# 1. Container images
###############################################################################
echo
info "=== Pulling container images ==="

pull_and_save() {
  local image="$1" tag="${2:-latest}" output_file="$3"
  local full_image="${image}:${tag}"

  if [[ -f "${OUTPUT_DIR}/docker-images/${output_file}" ]]; then
    warn "Already exists, skipping: ${output_file}"
    return 0
  fi

  info "Pulling ${full_image}..."
  ${CONTAINER_CMD} pull "${full_image}"

  info "Saving ${full_image} -> ${output_file}..."
  ${CONTAINER_CMD} save "${full_image}" | gzip > "${OUTPUT_DIR}/docker-images/${output_file}"
  local size
  size=$(du -sh "${OUTPUT_DIR}/docker-images/${output_file}" | cut -f1)
  success "Saved: ${output_file} (${size})"
  echo "${output_file}  $(sha256sum "${OUTPUT_DIR}/docker-images/${output_file}" | cut -d' ' -f1)" >> "${MANIFEST_FILE}"
}

pull_and_save "grafana/grafana"  "${GRAFANA_VERSION}"    "grafana-grafana-${GRAFANA_VERSION}.tar.gz"
pull_and_save "prom/prometheus"  "${PROMETHEUS_VERSION}" "prom-prometheus-${PROMETHEUS_VERSION}.tar.gz"
pull_and_save "grafana/loki"     "${LOKI_VERSION}"       "grafana-loki-${LOKI_VERSION}.tar.gz"
pull_and_save "grafana/promtail" "${LOKI_VERSION}"       "grafana-promtail-${LOKI_VERSION}.tar.gz"

###############################################################################
# 2. node_exporter — Linux binaries
###############################################################################
echo
info "=== Downloading node_exporter binaries ==="

NE_BASE_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}"

for ARCH in amd64 arm64; do
  TARBALL="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
  download \
    "${NE_BASE_URL}/${TARBALL}" \
    "${OUTPUT_DIR}/node_exporter/${TARBALL}" \
    "node_exporter ${NODE_EXPORTER_VERSION} linux/${ARCH}"
done

# Checksum file
download \
  "${NE_BASE_URL}/sha256sums.txt" \
  "${OUTPUT_DIR}/node_exporter/sha256sums.txt" \
  "node_exporter checksums"

###############################################################################
# 3. windows_exporter — MSI
###############################################################################
echo
info "=== Downloading windows_exporter MSI ==="

WE_BASE_URL="https://github.com/prometheus-community/windows_exporter/releases/download/v${WINDOWS_EXPORTER_VERSION}"
WE_MSI="windows_exporter-${WINDOWS_EXPORTER_VERSION}-amd64.msi"

download \
  "${WE_BASE_URL}/${WE_MSI}" \
  "${OUTPUT_DIR}/windows_exporter/${WE_MSI}" \
  "windows_exporter ${WINDOWS_EXPORTER_VERSION}"

###############################################################################
# 4. Promtail — Linux and Windows binaries
###############################################################################
echo
info "=== Downloading Promtail binaries ==="

PT_BASE_URL="https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}"

# Linux amd64
download \
  "${PT_BASE_URL}/promtail-linux-amd64.zip" \
  "${OUTPUT_DIR}/promtail/promtail-linux-amd64.zip" \
  "Promtail ${PROMTAIL_VERSION} linux/amd64"

# Linux arm64
download \
  "${PT_BASE_URL}/promtail-linux-arm64.zip" \
  "${OUTPUT_DIR}/promtail/promtail-linux-arm64.zip" \
  "Promtail ${PROMTAIL_VERSION} linux/arm64"

# Windows amd64
download \
  "${PT_BASE_URL}/promtail-windows-amd64.exe.zip" \
  "${OUTPUT_DIR}/promtail/promtail-windows-amd64.exe.zip" \
  "Promtail ${PROMTAIL_VERSION} windows/amd64"

# Extract Windows exe from zip
if [[ -f "${OUTPUT_DIR}/promtail/promtail-windows-amd64.exe.zip" && ! -f "${OUTPUT_DIR}/promtail/promtail-windows-amd64.exe" ]]; then
  info "Extracting Promtail Windows exe..."
  unzip -q -o "${OUTPUT_DIR}/promtail/promtail-windows-amd64.exe.zip" \
    -d "${OUTPUT_DIR}/promtail/"
  success "Extracted promtail-windows-amd64.exe"
fi

###############################################################################
# 5. NSSM — Windows service manager
###############################################################################
echo
info "=== Downloading NSSM (Windows service manager) ==="

download \
  "https://nssm.cc/release/nssm-${NSSM_VERSION}.zip" \
  "${OUTPUT_DIR}/nssm/nssm-${NSSM_VERSION}.zip" \
  "NSSM ${NSSM_VERSION}"

if [[ -f "${OUTPUT_DIR}/nssm/nssm-${NSSM_VERSION}.zip" && ! -f "${OUTPUT_DIR}/nssm/nssm.exe" ]]; then
  info "Extracting NSSM exe for 64-bit Windows..."
  unzip -q -o "${OUTPUT_DIR}/nssm/nssm-${NSSM_VERSION}.zip" \
    "nssm-${NSSM_VERSION}/win64/nssm.exe" \
    -d "${OUTPUT_DIR}/nssm/extracted/"
  cp "${OUTPUT_DIR}/nssm/extracted/nssm-${NSSM_VERSION}/win64/nssm.exe" \
     "${OUTPUT_DIR}/nssm/nssm.exe"
  rm -rf "${OUTPUT_DIR}/nssm/extracted"
  success "Extracted NSSM to offline-packages/nssm/nssm.exe"
fi

###############################################################################
# 6. Ansible Galaxy collections
###############################################################################
echo
info "=== Downloading Ansible Galaxy collections ==="

if ! command -v ansible-galaxy >/dev/null 2>&1; then
  warn "ansible-galaxy not found — skipping collection download."
  warn "Install Ansible on this machine to include offline collection packages."
  warn "Collections required: ansible.posix, community.general, ansible.windows, community.windows"
else
  REQUIREMENTS_FILE="${SCRIPT_DIR}/../ansible/requirements.yml"

  if [[ ! -f "$REQUIREMENTS_FILE" ]]; then
    warn "ansible/requirements.yml not found — skipping collection download."
  else
    mkdir -p "${OUTPUT_DIR}/ansible-collections"

    info "Downloading collections listed in ansible/requirements.yml..."
    ansible-galaxy collection download \
      -r "$REQUIREMENTS_FILE" \
      --download-path "${OUTPUT_DIR}/ansible-collections"

    # Log each downloaded tarball into the manifest
    shopt -s nullglob
    for tarball in "${OUTPUT_DIR}/ansible-collections/"*.tar.gz; do
      echo "$(basename "$tarball")  $(sha256sum "$tarball" | cut -d' ' -f1)" >> "${MANIFEST_FILE}"
      success "Packaged: $(basename "$tarball") ($(du -sh "$tarball" | cut -f1))"
    done
    shopt -u nullglob

    success "Ansible collections saved to offline-packages/ansible-collections/"
  fi
fi

###############################################################################
# 7. podman-compose pip wheel (for air-gapped monitoring server)
###############################################################################
echo
info "=== Downloading podman-compose pip wheel ==="

if ! command -v pip3 >/dev/null 2>&1; then
  warn "pip3 not found — skipping podman-compose wheel download."
  warn "podman-compose will require PyPI access on the monitoring server."
else
  info "Downloading podman-compose and its dependencies as pip wheels..."
  pip3 download podman-compose \
    -d "${OUTPUT_DIR}/pip-packages"

  shopt -s nullglob
  for wheel in "${OUTPUT_DIR}/pip-packages/"*.whl; do
    echo "$(basename "$wheel")  $(sha256sum "$wheel" | cut -d' ' -f1)" >> "${MANIFEST_FILE}"
    success "Packaged: $(basename "$wheel") ($(du -sh "$wheel" | cut -f1))"
  done
  shopt -u nullglob

  success "podman-compose wheels saved to offline-packages/pip-packages/"
fi

###############################################################################
# 8. Manifest summary
###############################################################################
echo
echo "─────────────────────────────────────────────────────────────────────"
echo -e "${GREEN}Download complete!${NC}"
echo "─────────────────────────────────────────────────────────────────────"
echo
echo "Manifest written to: ${MANIFEST_FILE}"
echo
echo "Directory summary:"
du -sh "${OUTPUT_DIR}"/*/  2>/dev/null | sort -h
echo
echo "Total size:"
du -sh "${OUTPUT_DIR}"
echo
echo "─────────────────────────────────────────────────────────────────────"
echo "Next steps for air-gapped deployment:"
echo "  1. Copy the entire project directory (including offline-packages/) to"
echo "     the target network via USB drive or secure file transfer."
echo "  2. On the Ansible controller, run:  ./setup.sh"
echo "     setup.sh will auto-detect offline-packages/ansible-collections/ and"
echo "     install Ansible Galaxy collections from local files before deploying."
echo "  3. setup.sh (or the Ansible playbook it triggers) will:"
echo "       - Install Podman and podman-compose on the monitoring server"
echo "       - Transfer and load container images"
echo "       - Push all configuration files"
echo "       - Start the observability stack"
echo "       - Deploy node exporters and Promtail to all monitored hosts"
echo "─────────────────────────────────────────────────────────────────────"
