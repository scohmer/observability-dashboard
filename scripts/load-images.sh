#!/usr/bin/env bash
# load-images.sh
# Loads container images from offline-packages/docker-images/ into the local
# Podman daemon on the air-gapped monitoring server.
#
# NOTE: In a fully controller-driven deployment this script is not needed —
# the deploy-monitoring-server.yml playbook transfers and loads images via
# Ansible. Use this script only for manual troubleshooting or re-loading.
#
# Usage:
#   ./scripts/load-images.sh [--dry-run] [--images-dir /path/to/dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_IMAGES_DIR="${SCRIPT_DIR}/../offline-packages/docker-images"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Parse arguments ───────────────────────────────────────────────────────────
DRY_RUN=false
IMAGES_DIR="${DEFAULT_IMAGES_DIR}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --images-dir)
      IMAGES_DIR="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--images-dir /path/to/dir]"
      echo
      echo "  --dry-run       Show what would be loaded without actually loading"
      echo "  --images-dir    Path to directory containing .tar.gz image archives"
      echo "                  (default: offline-packages/docker-images/)"
      exit 0
      ;;
    *)
      error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# ── Detect container runtime ──────────────────────────────────────────────────
if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD=podman
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD=docker
  warn "Podman not found — falling back to Docker."
else
  error "Neither podman nor docker is installed."
  exit 1
fi

# ── Pre-flight ────────────────────────────────────────────────────────────────
if [[ ! -d "${IMAGES_DIR}" ]]; then
  error "Images directory not found: ${IMAGES_DIR}"
  error "Run scripts/offline-prep.sh on an internet-connected machine first."
  exit 1
fi

# ── Find image archives ───────────────────────────────────────────────────────
mapfile -t IMAGE_FILES < <(find "${IMAGES_DIR}" -maxdepth 1 -name "*.tar.gz" -o -name "*.tar" | sort)

if [[ ${#IMAGE_FILES[@]} -eq 0 ]]; then
  error "No .tar.gz or .tar image archives found in: ${IMAGES_DIR}"
  exit 1
fi

echo
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Container Image Loader — Air-Gapped Deployment${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo
info "Container runtime: ${CONTAINER_CMD}"
info "Images directory:  ${IMAGES_DIR}"
info "Found ${#IMAGE_FILES[@]} image archive(s)"
[[ "$DRY_RUN" == "true" ]] && warn "DRY RUN MODE — no images will be loaded"
echo

# ── Load each image ───────────────────────────────────────────────────────────
LOADED=0
SKIPPED=0
FAILED=0

for image_file in "${IMAGE_FILES[@]}"; do
  filename="$(basename "$image_file")"
  filesize="$(du -sh "$image_file" | cut -f1)"

  info "Processing: ${filename} (${filesize})"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    [DRY RUN] Would load: ${image_file}"
    ((LOADED++)) || true
    continue
  fi

  if ${CONTAINER_CMD} load < "${image_file}" 2>&1; then
    success "Loaded: ${filename}"
    ((LOADED++)) || true
  else
    error "Failed to load: ${filename}"
    ((FAILED++)) || true
  fi
  echo
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "─────────────────────────────────────────────────────────────────────"
echo -e "  Loaded:  ${GREEN}${LOADED}${NC}"
echo -e "  Skipped: ${YELLOW}${SKIPPED}${NC}"
echo -e "  Failed:  ${RED}${FAILED}${NC}"
echo "─────────────────────────────────────────────────────────────────────"

if [[ "$DRY_RUN" == "false" && $LOADED -gt 0 ]]; then
  echo
  info "Loaded images:"
  ${CONTAINER_CMD} images --format "  {{.Repository}}:{{.Tag}}\t{{.Size}}" \
    | grep -E "grafana|prometheus|loki|alloy" | sort || true
  echo
fi

if [[ $FAILED -gt 0 ]]; then
  error "${FAILED} image(s) failed to load. Check the output above for details."
  exit 1
fi

if [[ "$DRY_RUN" == "false" ]]; then
  echo
  success "All images loaded successfully."
  echo
  echo "Next steps:"
  echo "  1. Run setup.sh on the Ansible controller:  ./setup.sh"
  echo "  2. Ansible will push configs and start the stack via podman-compose"
  echo "  3. Open Grafana: http://<monitoring-server>:3000"
  echo
fi
