# Observability Dashboard

A production-ready, self-hosted infrastructure monitoring stack built with
**Grafana**, **Prometheus**, **Loki**, **Promtail**, and **Node Exporter**.
Designed to work on both internet-connected and **air-gapped / disconnected**
networks. Supports Linux and Windows hosts.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        MONITORING SERVER                                 │
│                                                                          │
│  ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐   │
│  │     Grafana       │   │    Prometheus     │   │       Loki        │   │
│  │  (port 3000)     │──▶│   (port 9090)    │   │   (port 3100)    │   │
│  │  Dashboards       │   │  Metrics storage  │   │   Log storage    │   │
│  │  Alerts           │◀──│  Alert rules      │◀──│   Log queries    │   │
│  └──────────────────┘   └────────┬─────────┘   └────────▲─────────┘   │
│                                   │ scrape                │ push logs   │
└───────────────────────────────────┼───────────────────────┼─────────────┘
                                    │                       │
       ┌────────────────────────────┼───────────────────────┼──────┐
       │                            │                       │      │
       ▼                            ▼                       │      │
┌─────────────────────┐   ┌─────────────────────┐          │      │
│   Linux Host(s)      │   │   Windows Host(s)    │          │      │
│                      │   │                      │          │      │
│ ┌──────────────────┐ │   │ ┌──────────────────┐ │          │      │
│ │  node_exporter   │ │   │ │windows_exporter  │ │          │      │
│ │  (port 9100)     │ │   │ │  (port 9182)     │ │          │      │
│ └──────────────────┘ │   │ └──────────────────┘ │          │      │
│                      │   │                      │          │      │
│ ┌──────────────────┐ │   │ ┌──────────────────┐ │          │      │
│ │    Promtail      │─┼───┼─│    Promtail       │─┼──────────┘      │
│ │  (port 9080)     │ │   │ │  (port 9080)     │ │                  │
│ │  /var/log/*.log  │ │   │ │  Windows Events  │ │                  │
│ │  journald        │ │   │ │  IIS logs        │ │                  │
│ └──────────────────┘ │   │ └──────────────────┘ │                  │
└─────────────────────┘   └─────────────────────┘                   │
                                                                     │
All metrics scraped via HTTP pull (Prometheus model)                 │
All logs pushed via HTTP push (Loki Promtail model)  ────────────────┘
```

### Data Flow Summary

| Data Type | Protocol | Direction | Port |
|-----------|----------|-----------|------|
| Metrics (Linux) | HTTP scrape | Pull: Prometheus ← node_exporter | 9100 |
| Metrics (Windows) | HTTP scrape | Pull: Prometheus ← windows_exporter | 9182 |
| Logs (Linux) | HTTP push | Push: Promtail → Loki | 3100 |
| Logs (Windows) | HTTP push | Push: Promtail → Loki | 3100 |
| Visualization | HTTP | Browser → Grafana | 3000 |

---

## Prerequisites

### Monitoring Server

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| OS | Linux (any systemd distro) | Ubuntu 22.04 LTS / RHEL 9 |
| CPU | 2 cores | 4 cores |
| RAM | 4 GB | 8 GB |
| Disk | 50 GB | 200 GB |
| Docker | 24.x | latest |
| Docker Compose | v2.20+ | latest |

### Ansible Control Node (for agent deployment)

- Python 3.9+
- Ansible 2.14+
- `community.general` collection: `ansible-galaxy collection install community.general`
- `ansible.posix` collection: `ansible-galaxy collection install ansible.posix`
- `community.windows` collection: `ansible-galaxy collection install community.windows`
- `ansible.windows` collection: `ansible-galaxy collection install ansible.windows`

### Linux Target Hosts

- SSH access with sudo privileges
- Python 3 installed
- Firewall allows inbound TCP on port 9100 (node_exporter) and 9080 (Promtail)

### Windows Target Hosts

- WinRM enabled (HTTP, port 5985) — see setup instructions below
- Administrator credentials or equivalent
- .NET Framework 4.5+ (pre-installed on Windows Server 2012+)
- Firewall allows inbound TCP on port 9182 (windows_exporter) and 9080 (Promtail)

---

## Quick Start — Internet-Connected Network

### 1. Clone and configure

```bash
git clone https://github.com/scohmer/observability-dashboard.git
cd observability-dashboard

# Install Ansible collections
cd ansible && ansible-galaxy collection install -r requirements.yml 2>/dev/null || true; cd ..
```

### 2. Run the interactive setup wizard

```bash
bash setup.sh
```

The wizard prompts for:
- Monitoring server IP/hostname
- Number of hosts to monitor
- Per-host: IP, OS type, credentials, ports
- Grafana admin password
- Whether to run Ansible now

It generates:
- `ansible/inventory/hosts.yml`
- `config/prometheus/prometheus.yml` (with your scrape targets)
- `docker-compose.yml` (with your passwords and ports)
- `config/promtail/promtail-<hostname>.yml` (per host)

### 3. Start the monitoring stack

```bash
docker compose up -d

# Watch startup logs
docker compose logs -f

# Check all services are healthy
docker compose ps
```

### 4. Deploy agents to hosts

```bash
cd ansible

# Verify connectivity
ansible all -m ping

# Deploy node_exporter (Linux) and windows_exporter (Windows)
ansible-playbook playbooks/deploy-node-exporter.yml

# Deploy Promtail log shipper
ansible-playbook playbooks/deploy-promtail.yml
```

### 5. Open Grafana

Navigate to `http://<monitoring-server>:3000` in your browser.

- Default login: `admin` / `<password you set in setup.sh>`
- The **Infrastructure Overview** dashboard loads automatically
- Click any host row to drill into the **Node Detail** dashboard

---

## Air-Gapped Deployment Guide

### Phase 1 — Online machine (internet access required)

```bash
# Download all artifacts to offline-packages/
bash scripts/offline-prep.sh
```

This downloads (~1.5 GB):
- 4 Docker image tarballs (Grafana, Prometheus, Loki, Promtail)
- node_exporter binaries for Linux amd64 and arm64
- windows_exporter MSI for amd64
- Promtail binaries for Linux and Windows
- NSSM (Windows service manager)
- SHA-256 manifest for integrity verification

### Phase 2 — Transfer to air-gapped network

Copy the entire project directory to the monitoring server in the restricted
network (USB drive, secured file transfer, etc.).

Verify integrity after transfer:

```bash
cd offline-packages
sha256sum -c <(grep "tar.gz\|\.msi\|\.exe\|\.zip" MANIFEST.txt) 2>/dev/null
```

### Phase 3 — Monitoring server setup (air-gapped)

```bash
# 1. Load Docker images from tarballs
bash scripts/load-images.sh

# Verify images loaded
docker images | grep -E "grafana|prometheus|loki"

# 2. Run the setup wizard
bash setup.sh

# 3. Start the stack
docker compose up -d
```

### Phase 4 — Deploy agents (air-gapped)

Ansible roles automatically detect the `offline-packages/` directory and
copy binaries directly to target hosts without internet access.

```bash
cd ansible
ansible-playbook playbooks/deploy-node-exporter.yml
ansible-playbook playbooks/deploy-promtail.yml
```

---

## Configuration Reference

### Key configuration files

| File | Purpose | Generated by |
|------|---------|-------------|
| `docker-compose.yml` | Container orchestration | `setup.sh` (or edit manually) |
| `config/prometheus/prometheus.yml` | Scrape targets and global settings | `setup.sh` (or edit manually) |
| `config/prometheus/alerts/node-alerts.yml` | Alerting rules | Static (edit as needed) |
| `config/loki/loki-config.yml` | Log storage settings, retention | Static (edit as needed) |
| `config/grafana/provisioning/datasources/datasources.yml` | Grafana datasource provisioning | Static |
| `config/grafana/provisioning/dashboards/dashboards.yml` | Dashboard provider config | Static |
| `config/grafana/dashboards/overview.json` | Fleet overview dashboard | Static |
| `config/grafana/dashboards/node-detail.json` | Per-host detail dashboard | Static |
| `ansible/inventory/hosts.yml` | Ansible host inventory | `setup.sh` |
| `ansible/group_vars/all.yml` | Shared Ansible variables | Static (edit as needed) |

### Prometheus retention

Edit `docker-compose.yml` to change retention:

```yaml
command:
  - '--storage.tsdb.retention.time=90d'   # Change to 30d, 180d, 1y, etc.
  - '--storage.tsdb.retention.size=10GB'  # Limit by disk size
```

### Loki retention

Edit `config/loki/loki-config.yml`:

```yaml
limits_config:
  retention_period: 720h  # 30 days; change to 168h (7d), 2160h (90d), etc.
```

### Adding more hosts after initial setup

Re-run `setup.sh` — it regenerates all config files. Then:

```bash
docker compose restart prometheus  # Reload Prometheus config
ansible-playbook ansible/playbooks/deploy-node-exporter.yml --limit new_host
```

Or reload Prometheus without restart (if `--web.enable-lifecycle` is set):

```bash
curl -X POST http://localhost:9090/-/reload
```

---

## Dashboard Descriptions

### Infrastructure Overview (`uid: overview`)

Single-pane-of-glass view of all monitored hosts.

| Panel | Description |
|-------|-------------|
| Hosts Up / Down | Live count of reachable vs unreachable instances |
| Avg CPU | Average CPU utilization across all hosts |
| Avg Memory | Average memory utilization across all hosts |
| Max Disk | Highest disk usage across all filesystems |
| Host Inventory (table) | All hosts with status, CPU%, RAM%, Disk%, Uptime — click any row to drill down |
| CPU Usage (Linux) | Time-series: per-host CPU% for Linux hosts |
| CPU Usage (Windows) | Time-series: per-host CPU% for Windows hosts |
| Memory Usage (Linux) | Time-series: per-host memory% for Linux hosts |
| Memory Usage (Windows) | Time-series: per-host memory% for Windows hosts |

**Variables:** `$job` (multi-select, filters by node-linux/node-windows), `$instance` (multi-select)

### Node Detail (`uid: node-detail`)

Deep-dive into a single host.

| Panel | Description |
|-------|-------------|
| Status / CPU% / Mem% / Disk% / Uptime / Load / Total RAM / CPU Cores | Stat row at top |
| CPU by Mode | Stacked time-series: user, system, iowait, steal, nice |
| System Load | 1m/5m/15m load averages vs CPU core count |
| Memory Breakdown | Stacked: Used, Cached, Buffers, Free |
| Swap Usage | Swap used vs total |
| Disk Usage by Mount | Horizontal bar gauge per filesystem |
| Disk I/O | Read/Write bytes per device (mirrored positive/negative) |
| Network I/O | In/Out bits per interface (mirrored) |
| Network Packets | Packets in/out per interface |
| Network Errors & Drops | Error and drop rates |
| TCP Connections | ESTABLISHED, TIME_WAIT, sockets used |

**Variable:** `$instance` (single-select, populated from `node_uname_info`)

---

## Ansible Deployment Details

### Role structure

```
ansible/
├── ansible.cfg                          Main config
├── inventory/hosts.yml                  Generated by setup.sh
├── group_vars/
│   ├── all.yml                          Shared vars (loki_server, versions)
│   ├── linux.yml                        Linux connection settings
│   └── windows.yml                      WinRM settings
├── playbooks/
│   ├── deploy-node-exporter.yml         Import linux + windows sub-plays
│   └── deploy-promtail.yml              Import linux + windows sub-plays
└── roles/
    ├── node_exporter_linux/             node_exporter for Linux
    ├── node_exporter_windows/           windows_exporter for Windows
    ├── promtail_linux/                  Promtail for Linux
    └── promtail_windows/               Promtail for Windows
```

### Offline-first logic

Each role checks for the binary in `offline-packages/` before attempting a
download. This is the critical air-gap support:

```yaml
- name: Check if offline tarball exists on control node
  ansible.builtin.stat:
    path: "{{ offline_packages_dir }}/node_exporter/{{ node_exporter_tarball }}"
  register: offline_tarball
  delegate_to: localhost

- name: "[OFFLINE] Copy tarball to target"
  ansible.builtin.copy:
    src: "{{ offline_packages_dir }}/..."
  when: offline_tarball.stat.exists

- name: "[ONLINE] Download from GitHub"
  ansible.builtin.get_url:
    url: "https://github.com/..."
  when: not offline_tarball.stat.exists
```

### Firewall management

Roles automatically configure firewall rules:
- **RHEL/CentOS/Rocky**: `firewalld`
- **Ubuntu/Debian**: `ufw`
- **Other Linux**: `iptables`
- **Windows**: Windows Firewall via `community.windows.win_firewall_rule`

Set `manage_firewall: false` in `group_vars/all.yml` to skip firewall changes.

### WinRM setup on Windows targets

```powershell
# Run in elevated PowerShell on each Windows host
Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
winrm quickconfig -q
winrm set winrm/config/service/auth '@{Negotiate="true"}'
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $true
Restart-Service WinRM

# For workgroup machines (not domain-joined):
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "MONITORING_SERVER_IP"
```

---

## Troubleshooting

### Services won't start

```bash
# Check container status and recent logs
docker compose ps
docker compose logs grafana
docker compose logs prometheus
docker compose logs loki

# Restart a specific service
docker compose restart grafana

# Validate Prometheus config
docker run --rm -v "$(pwd)/config/prometheus:/etc/prometheus" \
  prom/prometheus --config.file=/etc/prometheus/prometheus.yml --check-config
```

### Prometheus targets are DOWN

```bash
# View targets in Prometheus UI
open http://localhost:9090/targets

# Test connectivity from monitoring server
curl http://<host-ip>:9100/metrics | head    # Linux
curl http://<host-ip>:9182/metrics | head    # Windows

# Check firewall on target
# Linux: sudo firewall-cmd --list-ports || sudo ufw status
# Windows: Get-NetFirewallRule -DisplayName "Allow*exporter*"
```

### Grafana shows "No data"

1. Check datasource: Settings → Data Sources → Prometheus → Test
2. Check time range — set to "Last 1 hour" or wider
3. Verify Prometheus has targets: http://localhost:9090/targets
4. Check Prometheus has data: http://localhost:9090/graph?g0.expr=up

### Loki not receiving logs

```bash
# Check Loki is ready
curl http://localhost:3100/ready

# Check Promtail status on a target host
# Linux:
systemctl status promtail
curl http://localhost:9080/ready

# Check Loki has labels
curl http://localhost:3100/loki/api/v1/labels | python3 -m json.tool
```

### Ansible connection failures

```bash
# Test SSH connectivity
ansible linux -m ping -vvv

# Test WinRM connectivity
ansible windows -m ansible.windows.win_ping -vvv

# Check WinRM from Linux control node
python3 -c "import winrm; s = winrm.Session('http://HOST:5985/wsman', auth=('user','pass')); print(s.run_cmd('ipconfig'))"
```

### Out of disk space on monitoring server

```bash
# Check usage
docker system df
du -sh config/ offline-packages/

# Clean unused Docker objects
docker system prune -f

# Reduce Prometheus retention in docker-compose.yml:
#   --storage.tsdb.retention.time=30d

# Reduce Loki retention in config/loki/loki-config.yml:
#   retention_period: 168h  (7 days)
```

---

## Security Considerations

### For production deployments

1. **Change default passwords** — set `GRAFANA_ADMIN_PASSWORD` to a strong password
2. **Use HTTPS** — put Grafana behind a reverse proxy (nginx/Caddy) with TLS
3. **Restrict Prometheus access** — bind to localhost or use firewall rules
4. **WinRM over HTTPS** — use port 5986 with a certificate for Windows targets
5. **Ansible vault** — encrypt WinRM passwords with `ansible-vault`
6. **Network segmentation** — place monitoring server in a dedicated management VLAN
7. **Grafana authentication** — consider LDAP/OAuth integration for multi-user environments

### Encrypt Ansible credentials

```bash
# Encrypt a string
ansible-vault encrypt_string 'MyPassword123' --name 'ansible_password'

# Use vault in playbooks
ansible-playbook playbooks/deploy-node-exporter.yml --ask-vault-pass
```

---

## Version Reference

| Component | Version | Notes |
|-----------|---------|-------|
| Grafana | latest | Pinned in docker-compose.yml |
| Prometheus | latest | Pinned in docker-compose.yml |
| Loki | latest | Pinned in docker-compose.yml |
| Promtail | 3.0.0 | Pinned in group_vars/all.yml |
| node_exporter | 1.8.2 | Pinned in group_vars/all.yml |
| windows_exporter | 0.29.2 | Pinned in group_vars/all.yml |

---

## License

MIT License — see LICENSE file for details.
