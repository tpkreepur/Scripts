#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] ${0##*/} failed near line ${LINENO}" >&2' ERR

: "${PVE_API_USER:?Set PVE_API_USER, e.g. pve-exporter@pve}"
: "${PVE_TOKEN_NAME:?Set PVE_TOKEN_NAME, e.g. prometheus-pve-exporter}"
: "${PVE_TOKEN_SECRET:?Set PVE_TOKEN_SECRET, the UUID secret from Proxmox API token creation}"

PVE_VERIFY_SSL="${PVE_VERIFY_SSL:-false}"
LISTEN_ADDRESS="${LISTEN_ADDRESS:-0.0.0.0}"
LISTEN_PORT="${LISTEN_PORT:-9221}"
SERVICE_USER="${SERVICE_USER:-prometheus-pve-exporter}"
INSTALL_DIR="${INSTALL_DIR:-/opt/prometheus-pve-exporter}"
CONFIG_FILE="${CONFIG_FILE:-/etc/prometheus/pve-exporter.yml}"
UNIT_NAME="prometheus-pve-exporter.service"
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root or with sudo." >&2
  exit 1
fi

if [[ "$PVE_VERIFY_SSL" != "true" && "$PVE_VERIFY_SSL" != "false" ]]; then
  echo "PVE_VERIFY_SSL must be true or false." >&2
  exit 1
fi

if ! [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]]; then
  echo "LISTEN_PORT must be numeric." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update -y || echo "[WARN] apt-get update reported an error; continuing."
apt-get install -y --no-install-recommends python3 python3-venv ca-certificates curl

if ! getent group "$SERVICE_USER" >/dev/null; then
  groupadd --system "$SERVICE_USER"
fi

if ! getent passwd "$SERVICE_USER" >/dev/null; then
  useradd \
    --system \
    --gid "$SERVICE_USER" \
    --home-dir /nonexistent \
    --no-create-home \
    --shell /usr/sbin/nologin \
    "$SERVICE_USER"
fi

install -d -o root -g root "$INSTALL_DIR"
install -d -o root -g root "$(dirname "$CONFIG_FILE")"

python3 -m venv "${INSTALL_DIR}/venv"
"${INSTALL_DIR}/venv/bin/pip" install --upgrade pip
"${INSTALL_DIR}/venv/bin/pip" install --upgrade prometheus-pve-exporter

umask 077

cat > "$CONFIG_FILE" <<EOF
default:
  user: ${PVE_API_USER}
  token_name: ${PVE_TOKEN_NAME}
  token_value: ${PVE_TOKEN_SECRET}
  verify_ssl: ${PVE_VERIFY_SSL}
EOF

chmod 0640 "$CONFIG_FILE"
chown root:"$SERVICE_USER" "$CONFIG_FILE"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Prometheus Proxmox VE Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_USER}
Environment=PYTHONUNBUFFERED=1
ExecStart=${INSTALL_DIR}/venv/bin/pve_exporter --config.file=${CONFIG_FILE} --web.listen-address=${LISTEN_ADDRESS}:${LISTEN_PORT}
Restart=always
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$UNIT_NAME"
systemctl restart "$UNIT_NAME"

if ! systemctl is-active --quiet "$UNIT_NAME"; then
  echo "Service failed to start." >&2
  journalctl -u "$UNIT_NAME" -n 80 --no-pager || true
  exit 1
fi

ready=0
for _ in {1..30}; do
  if curl -fsS "http://127.0.0.1:${LISTEN_PORT}/metrics" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

if [[ "$ready" -eq 1 ]]; then
  echo "prometheus-pve-exporter is running on ${LISTEN_ADDRESS}:${LISTEN_PORT}"
  echo "Local test: curl 'http://127.0.0.1:${LISTEN_PORT}/pve?module=default&target=127.0.0.1:8006&cluster=1&node=1'"
else
  echo "Exporter service is active, but /metrics did not respond." >&2
  journalctl -u "$UNIT_NAME" -n 80 --no-pager || true
  exit 1
fi