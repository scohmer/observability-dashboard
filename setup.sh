#!/usr/bin/env bash
# setup.sh — Interactive setup for the observability dashboard
# Generates inventory, prometheus config, docker-compose, and per-host Alloy config previews.
set -euo pipefail

###############################################################################
# Helpers
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

ask() {
  local prompt="$1" default="${2:-}" var
  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "${CYAN}?${NC} ${prompt} [${default}]: ")" var
    echo "${var:-$default}"
  else
    read -rp "$(echo -e "${CYAN}?${NC} ${prompt}: ")" var
    echo "$var"
  fi
}

ask_password() {
  local prompt="$1" var
  read -rsp "$(echo -e "${CYAN}?${NC} ${prompt}: ")" var
  echo
  echo "$var"
}

ask_yes_no() {
  local prompt="$1" default="${2:-y}" answer
  read -rp "$(echo -e "${CYAN}?${NC} ${prompt} [y/n] (${default}): ")" answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy] ]]
}

###############################################################################
# Banner
###############################################################################
echo -e "${GREEN}"
cat <<'BANNER'
 ___  _                              _   _ _ _ _
/ _ \| |__  ___  ___ _ ____   ____ _| |_(_) (_) |_ _   _
| | | | '_ \/ __|/ _ \ '__\ \ / / _` | __| | | | __| | | |
| |_| | |_) \__ \  __/ |   \ V / (_| | |_| | | | |_| |_| |
 \___/|_.__/|___/\___|_|    \_/ \__,_|\__|_|_|_|\__|\__, |
                                                     |___/
         D A S H B O A R D   S E T U P
BANNER
echo -e "${NC}"
echo "This wizard generates all configuration files for your observability stack."
echo "Stack: Grafana · Prometheus · Loki · Alloy · Node Exporter"
echo "------------------------------------------------------------------------"
echo

###############################################################################
# 1. Monitoring server
###############################################################################
MONITORING_HOST=$(ask "Monitoring server hostname or IP" "localhost")
MONITORING_SSH_USER=$(ask "Monitoring server SSH username" "ansible")
GRAFANA_PORT=$(ask "Grafana port" "3000")
PROMETHEUS_PORT=$(ask "Prometheus port" "9090")
LOKI_PORT=$(ask "Loki port" "3100")
GRAFANA_PASS=$(ask_password "Grafana admin password")
if [[ -z "$GRAFANA_PASS" ]]; then
  error "Grafana password cannot be empty."
  exit 1
fi

###############################################################################
# 2. Hosts to monitor
###############################################################################
NUM_HOSTS=$(ask "Number of hosts to monitor" "1")
if ! [[ "$NUM_HOSTS" =~ ^[0-9]+$ ]] || [[ "$NUM_HOSTS" -lt 1 ]]; then
  error "Number of hosts must be a positive integer."
  exit 1
fi

declare -a HOST_NAMES HOST_IPS HOST_OS HOST_SSH_USER HOST_WINRM_USER HOST_WINRM_PASS HOST_PORTS

for i in $(seq 1 "$NUM_HOSTS"); do
  echo
  echo -e "${YELLOW}--- Host $i of $NUM_HOSTS ---${NC}"
  HOST_NAMES[$i]=$(ask "  Hostname (used as label)")
  HOST_IPS[$i]=$(ask "  IP address or FQDN")
  HOST_OS[$i]=$(ask "  OS type (linux/windows)" "linux")
  HOST_OS[$i]="${HOST_OS[$i],,}"   # lowercase

  if [[ "${HOST_OS[$i]}" == "linux" ]]; then
    HOST_SSH_USER[$i]=$(ask "  SSH username" "ansible")
    HOST_WINRM_USER[$i]=""
    HOST_WINRM_PASS[$i]=""
  else
    HOST_WINRM_USER[$i]=$(ask "  WinRM username" "Administrator")
    HOST_WINRM_PASS[$i]=$(ask_password "  WinRM password")
    HOST_SSH_USER[$i]=""
  fi

  HOST_PORTS[$i]=$(ask "  Additional TCP ports to monitor (comma-separated, or leave blank)" "")
done

###############################################################################
# 3. Run Ansible?
###############################################################################
RUN_ANSIBLE=false
if ask_yes_no "Run Ansible deployment now?" "n"; then
  RUN_ANSIBLE=true
fi

###############################################################################
# 4. Generate files
###############################################################################
info "Generating configuration files..."

ANSIBLE_DIR="${SCRIPT_DIR}/ansible"
CONFIG_DIR="${SCRIPT_DIR}/config"
ALLOY_DIR="${CONFIG_DIR}/alloy"

mkdir -p "${ANSIBLE_DIR}/inventory"
mkdir -p "${CONFIG_DIR}/prometheus"
mkdir -p "${ALLOY_DIR}"

# ── 4a. Ansible inventory ────────────────────────────────────────────────────
INVENTORY_FILE="${ANSIBLE_DIR}/inventory/hosts.yml"
cat > "$INVENTORY_FILE" <<YAML
---
all:
  vars:
    loki_server: "${MONITORING_HOST}"
    monitoring_server: "${MONITORING_HOST}"

  children:
    monitoring:
      hosts:
        monitoring-server:
          ansible_host: ${MONITORING_HOST}
          ansible_user: ${MONITORING_SSH_USER}

    linux:
      hosts:
YAML

for i in $(seq 1 "$NUM_HOSTS"); do
  if [[ "${HOST_OS[$i]}" == "linux" ]]; then
    cat >> "$INVENTORY_FILE" <<YAML
        ${HOST_NAMES[$i]}:
          ansible_host: ${HOST_IPS[$i]}
          ansible_user: ${HOST_SSH_USER[$i]}
YAML
  fi
done

cat >> "$INVENTORY_FILE" <<YAML
    windows:
      hosts:
YAML

for i in $(seq 1 "$NUM_HOSTS"); do
  if [[ "${HOST_OS[$i]}" == "windows" ]]; then
    cat >> "$INVENTORY_FILE" <<YAML
        ${HOST_NAMES[$i]}:
          ansible_host: ${HOST_IPS[$i]}
          ansible_user: ${HOST_WINRM_USER[$i]}
          ansible_password: "${HOST_WINRM_PASS[$i]}"
YAML
  fi
done

success "Generated ${INVENTORY_FILE}"

# ── 4b. Prometheus config ────────────────────────────────────────────────────
PROM_FILE="${CONFIG_DIR}/prometheus/prometheus.yml"
cat > "$PROM_FILE" <<YAML
---
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    monitor: 'observability-dashboard'

alerting:
  alertmanagers: []

rule_files:
  - /etc/prometheus/alerts/*.yml

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:${PROMETHEUS_PORT}']

  - job_name: 'node-linux'
    static_configs:
      - targets:
YAML

for i in $(seq 1 "$NUM_HOSTS"); do
  if [[ "${HOST_OS[$i]}" == "linux" ]]; then
    echo "        - '${HOST_IPS[$i]}:9100'" >> "$PROM_FILE"
    echo "        # ${HOST_NAMES[$i]}" >> "$PROM_FILE"
  fi
done

cat >> "$PROM_FILE" <<YAML

  - job_name: 'node-windows'
    static_configs:
      - targets:
YAML

for i in $(seq 1 "$NUM_HOSTS"); do
  if [[ "${HOST_OS[$i]}" == "windows" ]]; then
    echo "        - '${HOST_IPS[$i]}:9182'" >> "$PROM_FILE"
    echo "        # ${HOST_NAMES[$i]}" >> "$PROM_FILE"
  fi
done

# Additional port probing (blackbox-style placeholder)
for i in $(seq 1 "$NUM_HOSTS"); do
  if [[ -n "${HOST_PORTS[$i]}" ]]; then
    IFS=',' read -ra PORTS <<< "${HOST_PORTS[$i]}"
    for port in "${PORTS[@]}"; do
      port="${port// /}"
      cat >> "$PROM_FILE" <<YAML

  - job_name: 'tcp-${HOST_NAMES[$i]}-${port}'
    metrics_path: /probe
    params:
      module: [tcp_connect]
    static_configs:
      - targets: ['${HOST_IPS[$i]}:${port}']
        labels:
          hostname: '${HOST_NAMES[$i]}'
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 'localhost:9115'
YAML
    done
  fi
done

success "Generated ${PROM_FILE}"

# ── 4c. Podman Compose file ───────────────────────────────────────────────────
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
cat > "$COMPOSE_FILE" <<YAML
# docker-compose.yml — generated by setup.sh for use with podman-compose.
# Deployed to the monitoring server by ansible/playbooks/deploy-monitoring-server.yml.

networks:
  observability:
    driver: bridge

volumes:
  grafana-data:
  prometheus-data:
  loki-data:

services:

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports:
      - "${GRAFANA_PORT}:3000"
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: "${GRAFANA_PASS}"
      GF_PATHS_PROVISIONING: /etc/grafana/provisioning
      GF_SERVER_ROOT_URL: "http://${MONITORING_HOST}:${GRAFANA_PORT}"
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"
      GF_AUTH_ANONYMOUS_ENABLED: "false"
    volumes:
      - grafana-data:/var/lib/grafana
      - ./config/grafana/provisioning:/etc/grafana/provisioning:ro
      - ./config/grafana/dashboards:/var/lib/grafana/dashboards:ro
    networks:
      - observability
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:3000/api/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    logging:
      driver: "journald"
      options:
        tag: "grafana"

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "${PROMETHEUS_PORT}:9090"
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=90d'
      - '--web.enable-lifecycle'
      - '--web.enable-admin-api'
    volumes:
      - prometheus-data:/prometheus
      - ./config/prometheus:/etc/prometheus:ro
    networks:
      - observability
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:9090/-/healthy || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 20s
    logging:
      driver: "journald"
      options:
        tag: "prometheus"

  loki:
    image: grafana/loki:latest
    container_name: loki
    restart: unless-stopped
    ports:
      - "${LOKI_PORT}:3100"
    command: -config.file=/etc/loki/loki-config.yml
    volumes:
      - loki-data:/loki
      - ./config/loki:/etc/loki:ro
    networks:
      - observability
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:3100/ready || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 20s
    logging:
      driver: "journald"
      options:
        tag: "loki"
YAML

success "Generated ${COMPOSE_FILE}"

# ── 4d. Per-host Alloy configs ────────────────────────────────────────────────
# NOTE: These are reference copies only. The authoritative config is deployed
# by the alloy_linux/alloy_windows Ansible roles using Jinja2 templates.
# These files give the admin a preview of what will be deployed to each host.
for i in $(seq 1 "$NUM_HOSTS"); do
  ALLOY_FILE="${ALLOY_DIR}/config-${HOST_NAMES[$i]}.alloy"
  if [[ "${HOST_OS[$i]}" == "linux" ]]; then
    cat > "$ALLOY_FILE" <<ALLOY
// Grafana Alloy configuration preview for ${HOST_NAMES[$i]} (Linux)
// Deployed by: ansible/playbooks/deploy-alloy.yml

loki.write "default" {
  endpoint {
    url = "http://${MONITORING_HOST}:${LOKI_PORT}/loki/api/v1/push"
  }
}

local.file_match "varlog" {
  path_targets = [
    { __path__ = "/var/log/*.log",    job = "varlog", host = "${HOST_NAMES[$i]}" },
    { __path__ = "/var/log/**/*.log", job = "varlog", host = "${HOST_NAMES[$i]}" },
  ]
}

loki.source.file "varlog" {
  targets    = local.file_match.varlog.targets
  forward_to = [loki.write.default.receiver]
}

loki.source.journal "journal" {
  forward_to = [loki.write.default.receiver]
  max_age    = "12h"
  labels = { job = "systemd-journal", host = "${HOST_NAMES[$i]}" }
  relabel_rules = loki.relabel.journal.rules
}

loki.relabel "journal" {
  forward_to = []
  rule { source_labels = ["__journal__systemd_unit"] target_label = "unit" }
  rule { source_labels = ["__journal__hostname"]     target_label = "hostname" }
  rule { source_labels = ["__journal_priority_keyword"] target_label = "level" }
}
ALLOY
  else
    cat > "$ALLOY_FILE" <<ALLOY
// Grafana Alloy configuration preview for ${HOST_NAMES[$i]} (Windows)
// Deployed by: ansible/playbooks/deploy-alloy.yml

loki.write "default" {
  endpoint {
    url = "http://${MONITORING_HOST}:${LOKI_PORT}/loki/api/v1/push"
  }
}

loki.source.windowsevent "application" {
  eventlog_name = "Application"
  use_incoming_timestamp = false
  forward_to = [loki.write.default.receiver]
  labels = { job = "windows-event-log", host = "${HOST_NAMES[$i]}", log_type = "application" }
}

loki.source.windowsevent "system" {
  eventlog_name = "System"
  use_incoming_timestamp = false
  forward_to = [loki.write.default.receiver]
  labels = { job = "windows-event-log", host = "${HOST_NAMES[$i]}", log_type = "system" }
}

loki.source.windowsevent "security" {
  eventlog_name = "Security"
  use_incoming_timestamp = false
  forward_to = [loki.write.default.receiver]
  labels = { job = "windows-event-log", host = "${HOST_NAMES[$i]}", log_type = "security" }
}

local.file_match "iis" {
  path_targets = [{ __path__ = "C:\\\\inetpub\\\\logs\\\\LogFiles\\\\**\\\\*.log", job = "iis", host = "${HOST_NAMES[$i]}" }]
}

loki.source.file "iis" {
  targets    = local.file_match.iis.targets
  forward_to = [loki.write.default.receiver]
}
ALLOY
  fi
  success "Generated ${ALLOY_FILE}"
done

###############################################################################
# 5. Install Ansible collections
###############################################################################
OFFLINE_COLLECTIONS="${SCRIPT_DIR}/offline-packages/ansible-collections"

if ! command -v ansible-galaxy >/dev/null 2>&1; then
  warn "ansible-galaxy not found — skipping collection install."
  warn "Install Ansible on this controller before running playbooks."
  warn "Required collections: ansible.posix  community.general  ansible.windows  community.windows"
else
  info "Installing Ansible Galaxy collections..."

  # Prefer offline packages if they were produced by offline-prep.sh
  if ls "${OFFLINE_COLLECTIONS}/"*.tar.gz >/dev/null 2>&1; then
    info "Offline collection packages found — installing without internet access..."
    ansible-galaxy collection install \
      "${OFFLINE_COLLECTIONS}/"*.tar.gz \
      --upgrade 2>&1 | grep -v "^WARNING" || true
    success "Ansible collections installed from offline-packages/ansible-collections/"
  else
    info "No offline packages found — installing from Ansible Galaxy..."
    ansible-galaxy collection install \
      -r "${ANSIBLE_DIR}/requirements.yml" \
      --upgrade 2>&1 | grep -v "^WARNING" || true
    success "Ansible collections installed from Galaxy."
  fi
fi

###############################################################################
# 6. Summary
###############################################################################
echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo "Generated files:"
echo "  ${INVENTORY_FILE}"
echo "  ${PROM_FILE}"
echo "  ${COMPOSE_FILE}"
for i in $(seq 1 "$NUM_HOSTS"); do
  echo "  ${ALLOY_DIR}/config-${HOST_NAMES[$i]}.alloy  (preview)"
done
echo
echo "Next steps:"
echo "  1. Review generated configs in ./config/ and ./ansible/inventory/"
echo "  2. Deploy the full stack via Ansible (images + config + start):"
echo "       ansible-playbook ansible/playbooks/deploy-monitoring-server.yml"
echo "  3. Deploy node exporters and Alloy to monitored hosts:"
echo "       ansible-playbook ansible/playbooks/deploy-node-exporter.yml"
echo "       ansible-playbook ansible/playbooks/deploy-alloy.yml"
echo "  4. Open Grafana at:  http://${MONITORING_HOST}:${GRAFANA_PORT}"
echo

###############################################################################
# 7. Optional: run Ansible
###############################################################################
if [[ "$RUN_ANSIBLE" == "true" ]]; then
  info "Running Ansible deployment..."
  cd "${ANSIBLE_DIR}"
  info "Step 1/3: Deploying observability stack to monitoring server..."
  ansible-playbook playbooks/deploy-monitoring-server.yml
  info "Step 2/3: Deploying node exporters to monitored hosts..."
  ansible-playbook playbooks/deploy-node-exporter.yml
  info "Step 3/3: Deploying Grafana Alloy to monitored hosts..."
  ansible-playbook playbooks/deploy-alloy.yml
  success "Ansible deployment complete."
  echo
  echo "  Grafana is available at: http://${MONITORING_HOST}:${GRAFANA_PORT}"
fi
