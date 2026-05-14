#!/usr/bin/env bash
# One-shot setup: Go, build, systemd backend, nginx :80 -> :9000, smoke curl.
# Supports Debian/Ubuntu (apt) and Rocky/RHEL/Alma/CentOS 8+ (dnf).
# Run: chmod +x install.sh && sudo ./install.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_NAME="json-load-backend"
INSTALL_DIR="/opt/json-load-backend"
SERVICE_NAME="json-load-backend"
SERVICE_USER="${SUDO_USER:-${INSTALL_USER:-}}"
if [[ -z "$SERVICE_USER" || "$SERVICE_USER" == "root" ]]; then
  SERVICE_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1 || true)"
fi
if [[ -z "$SERVICE_USER" ]]; then
  echo "Could not pick a non-root user for systemd. Set INSTALL_USER=youruser sudo ./install.sh"
  exit 1
fi

if [[ "${EUID:-0}" -ne 0 ]]; then
  echo "This script installs system files. Run: sudo $0"
  exit 1
fi

PKG_FAMILY=""
if [[ -f /etc/debian_version ]]; then
  PKG_FAMILY="debian"
elif [[ -f /etc/redhat-release ]]; then
  PKG_FAMILY="rhel"
else
  # shellcheck source=/dev/null
  [[ -f /etc/os-release ]] && . /etc/os-release
  if [[ "${ID:-}" =~ ^(rocky|almalinux|centos|rhel|fedora)$ ]] || [[ "${ID_LIKE:-}" == *rhel* ]] || [[ "${ID_LIKE:-}" == *fedora* ]]; then
    PKG_FAMILY="rhel"
  fi
fi

if [[ -z "$PKG_FAMILY" ]]; then
  echo "Unsupported OS (need apt or dnf). Install Go and nginx manually, then follow the README."
  exit 1
fi

need_cmd() { command -v "$1" >/dev/null 2>&1; }

install_deps() {
  case "$PKG_FAMILY" in
  debian)
    export DEBIAN_FRONTEND=noninteractive
    if ! need_cmd go || ! need_cmd nginx; then
      apt-get update -qq
    fi
    if ! need_cmd go; then
      echo "Installing golang…"
      apt-get install -y golang
    fi
    if ! need_cmd nginx; then
      echo "Installing nginx…"
      apt-get install -y nginx
    fi
    if ! need_cmd curl; then
      apt-get install -y curl
    fi
    ;;
  rhel)
    if ! need_cmd go || ! need_cmd nginx || ! need_cmd curl; then
      echo "Installing golang, nginx, curl (dnf)…"
      dnf install -y golang nginx curl
    fi
    ;;
  esac
}

install_deps

echo "Building ${BIN_NAME}…"
(
  cd "$REPO_ROOT"
  go build -o "$BIN_NAME" .
)

echo "Installing binary to ${INSTALL_DIR}…"
install -d -m 0755 "$INSTALL_DIR"
install -m 0755 "$REPO_ROOT/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"

echo "Writing systemd unit (User=${SERVICE_USER})…"
cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=JSON Load Backend
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${BIN_NAME}
Restart=always
RestartSec=2
User=${SERVICE_USER}
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

if [[ ! -f "$REPO_ROOT/deploy/nginx.conf" ]]; then
  echo "Missing $REPO_ROOT/deploy/nginx.conf"
  exit 1
fi

NGINX_MAIN="/etc/nginx/nginx.conf"
if [[ -f "$NGINX_MAIN" ]]; then
  cp -a "$NGINX_MAIN" "${NGINX_MAIN}.bak.$(date +%Y%m%d%H%M%S)"
  echo "Backed up existing ${NGINX_MAIN}"
fi
echo "Installing nginx config (replaces ${NGINX_MAIN}; use backup to restore)…"
TMP_NGINX="$(mktemp)"
if [[ "$PKG_FAMILY" == "rhel" ]]; then
  # RHEL-family packages run nginx as user 'nginx', not 'www-data'.
  sed 's/^user www-data;/user nginx;/' "$REPO_ROOT/deploy/nginx.conf" >"$TMP_NGINX"
else
  cp -a "$REPO_ROOT/deploy/nginx.conf" "$TMP_NGINX"
fi
install -m 0644 "$TMP_NGINX" "$NGINX_MAIN"
rm -f "$TMP_NGINX"

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"

# Brief wait for Listen; then confirm backend (bypasses nginx / SELinux).
sleep 0.5
if ! curl -fsS -o /dev/null --connect-timeout 2 "http://127.0.0.1:9000/health" 2>/dev/null; then
  echo "WARNING: backend not responding on 127.0.0.1:9000 — check: journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
else
  echo "Backend OK on 127.0.0.1:9000"
fi

# With SELinux Enforcing, stock policy often denies nginx from connecting to upstream TCP (502).
if [[ "$PKG_FAMILY" == "rhel" ]] && need_cmd getenforce; then
  enforce="$(getenforce 2>/dev/null || true)"
  if [[ "$enforce" == "Enforcing" ]]; then
    echo "SELinux Enforcing: allowing web server to connect to upstream backends (fixes typical 502 to localhost)…"
    setsebool -P httpd_can_network_connect 1
  fi
fi

nginx -t
systemctl restart nginx

echo "Smoke tests (via nginx on :80)…"
for path in /health /small /medium /large; do
  curl -fsS -o /dev/null -w "%{http_code} ${path}\n" "http://127.0.0.1${path}" || true
done

echo "Done. Backend: systemctl status ${SERVICE_NAME} | Nginx: systemctl status nginx"
