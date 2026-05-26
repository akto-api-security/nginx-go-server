#!/usr/bin/env bash
# One-shot setup: Go, build, systemd backend, nginx :80 -> :9000, smoke curl.
# Supports: Debian/Ubuntu, Amazon Linux 2, Amazon Linux 2023, Rocky/RHEL/Alma (dnf).
# Run: chmod +x install.sh && sudo ./install.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_NAME="json-load-backend"
INSTALL_DIR="/opt/json-load-backend"
SERVICE_NAME="json-load-backend"
GO_VERSION="${GO_VERSION:-1.22.12}"

SERVICE_USER="${SUDO_USER:-${INSTALL_USER:-}}"
if [[ -z "$SERVICE_USER" || "$SERVICE_USER" == "root" ]]; then
  if id ec2-user &>/dev/null; then
    SERVICE_USER="ec2-user"
  else
    SERVICE_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1 || true)"
  fi
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
if [[ -f /etc/os-release ]]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  if [[ "${ID:-}" == "amzn" && "${VERSION_ID:-}" == "2" ]]; then
    PKG_FAMILY="amazonlinux2"
  elif [[ "${ID:-}" == "amzn" ]]; then
    PKG_FAMILY="amazonlinux2023"
  elif [[ -f /etc/debian_version ]]; then
    PKG_FAMILY="debian"
  elif [[ "${ID:-}" =~ ^(rocky|almalinux|centos|rhel|fedora)$ ]] \
    || [[ "${ID_LIKE:-}" == *rhel* ]] \
    || [[ "${ID_LIKE:-}" == *fedora* ]] \
    || [[ -f /etc/redhat-release ]]; then
    PKG_FAMILY="rhel"
  fi
fi

if [[ -z "$PKG_FAMILY" ]]; then
  echo "Unsupported OS. Supported: Debian/Ubuntu, Amazon Linux 2/2023, Rocky/RHEL/Alma."
  exit 1
fi

echo "Detected OS family: ${PKG_FAMILY}"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

pkg_update() {
  case "$PKG_FAMILY" in
  debian) apt-get update -qq ;;
  amazonlinux2) yum makecache -y >/dev/null 2>&1 || true ;;
  amazonlinux2023|rhel)
    dnf -y makecache >/dev/null 2>&1 || true
    ;;
  esac
}

pkg_install() {
  case "$PKG_FAMILY" in
  debian)
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y "$@"
    ;;
  amazonlinux2)
    yum install -y "$@"
    ;;
  amazonlinux2023|rhel)
    dnf install -y "$@"
    ;;
  esac
}

install_go_tarball() {
  local arch="amd64"
  case "$(uname -m)" in
  aarch64|arm64) arch="arm64" ;;
  x86_64) arch="amd64" ;;
  esac
  echo "Installing Go ${GO_VERSION} from go.dev (${arch})…"
  pkg_install curl tar
  local tarball="go${GO_VERSION}.linux-${arch}.tar.gz"
  curl -fsSL "https://go.dev/dl/${tarball}" -o "/tmp/${tarball}"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "/tmp/${tarball}"
  rm -f "/tmp/${tarball}"
  export PATH="/usr/local/go/bin:${PATH}"
  if [[ ! -f /etc/profile.d/golang.sh ]]; then
    echo 'export PATH=$PATH:/usr/local/go/bin' >/etc/profile.d/golang.sh
    chmod 644 /etc/profile.d/golang.sh
  fi
}

install_go() {
  if need_cmd go && go version >/dev/null 2>&1; then
    return 0
  fi
  echo "Installing Go from package manager…"
  case "$PKG_FAMILY" in
  amazonlinux2023)
    pkg_install golang golang-bin || pkg_install golang-bin
    ;;
  amazonlinux2)
    pkg_install golang || true
    ;;
  *)
    pkg_install golang
    ;;
  esac
  if need_cmd go && go version >/dev/null 2>&1; then
    return 0
  fi
  install_go_tarball
}

# EL8 AppStream often defaults to nginx:1.14; enable a newer stream when dnf modules exist.
rhel_enable_best_nginx_stream() {
  [[ "$PKG_FAMILY" == "rhel" ]] || return 0
  need_cmd dnf || return 0
  local vmajor=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    vmajor="${VERSION_ID%%.*}"
  fi
  [[ "$vmajor" == "8" ]] || return 0
  dnf module list nginx >/dev/null 2>&1 || return 0
  dnf module reset -y nginx || true
  local stream
  for stream in 1.26 1.24 1.22 1.20 1.18; do
    if dnf module enable -y "nginx:${stream}" 2>/dev/null; then
      echo "nginx AppStream module enabled: ${stream}"
      return 0
    fi
  done
  echo "Note: could not enable a newer nginx module stream; using default nginx package."
}

install_nginx() {
  if need_cmd nginx; then
    return 0
  fi
  case "$PKG_FAMILY" in
  amazonlinux2)
    echo "Installing nginx (amazon-linux-extras nginx1)…"
    if need_cmd amazon-linux-extras; then
      amazon-linux-extras install -y nginx1
    else
      pkg_install nginx
    fi
    ;;
  *)
    pkg_install nginx
    ;;
  esac
}

configure_selinux_nginx() {
  [[ "$PKG_FAMILY" == "debian" ]] && return 0
  if ! need_cmd getenforce; then
    return 0
  fi
  local enforce
  enforce="$(getenforce 2>/dev/null || true)"
  [[ "$enforce" == "Enforcing" ]] || return 0

  if ! need_cmd setsebool; then
    echo "Installing SELinux tools for setsebool…"
    pkg_install policycoreutils-python-utils 2>/dev/null \
      || pkg_install python3-policycoreutils 2>/dev/null \
      || true
  fi

  echo "SELinux Enforcing: allowing nginx/httpd outbound connections to upstream (fixes 502)…"
  setsebool -P httpd_can_network_connect 1 2>/dev/null \
    || setsebool -P httpd_can_network_connect on 2>/dev/null \
    || true
}

install_deps() {
  case "$PKG_FAMILY" in
  debian)
    pkg_update
    need_cmd go || install_go
    need_cmd nginx || install_nginx
    need_cmd curl || pkg_install curl
    ;;
  amazonlinux2)
    pkg_update
    pkg_install curl tar
    install_go
    install_nginx
    ;;
  amazonlinux2023)
    pkg_update
    echo "Installing golang, nginx, curl (dnf)…"
    pkg_install golang golang-bin nginx curl tar
    install_go
    install_nginx
    ;;
  rhel)
    pkg_update
    rhel_enable_best_nginx_stream
    echo "Installing / updating golang, nginx, curl…"
    pkg_install golang nginx curl tar
    install_go
    install_nginx
    ;;
  esac
}

ensure_go_on_path() {
  if need_cmd go; then
    return 0
  fi
  if [[ -x /usr/local/go/bin/go ]]; then
    export PATH="/usr/local/go/bin:${PATH}"
  fi
  # AL2023 RPM often installs go under /usr/bin/go via golang-bin
  if [[ -x /usr/bin/go ]]; then
    export PATH="/usr/bin:${PATH}"
  fi
  need_cmd go || {
    echo "go not found on PATH after install"
    exit 1
  }
}

install_deps
ensure_go_on_path

echo "Using: $(go version)"
need_cmd nginx && echo "Using: $(nginx -v 2>&1)"

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
if [[ "$PKG_FAMILY" != "debian" ]]; then
  sed 's/^user www-data;/user nginx;/' "$REPO_ROOT/deploy/nginx.conf" >"$TMP_NGINX"
else
  cp -a "$REPO_ROOT/deploy/nginx.conf" "$TMP_NGINX"
fi
install -m 0644 "$TMP_NGINX" "$NGINX_MAIN"
rm -f "$TMP_NGINX"

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"

sleep 1
if ! curl -fsS -o /dev/null --connect-timeout 3 "http://127.0.0.1:9000/health" 2>/dev/null; then
  echo "WARNING: backend not responding on 127.0.0.1:9000"
  echo "  journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
else
  echo "Backend OK on 127.0.0.1:9000"
fi

configure_selinux_nginx

need_cmd nginx || {
  echo "nginx binary not found after install"
  exit 1
}

if ! nginx -t 2>&1; then
  echo "nginx -t failed. Restore backup from ${NGINX_MAIN}.bak.* if needed."
  exit 1
fi

systemctl enable nginx 2>/dev/null || true
systemctl restart nginx

echo "Smoke tests (via nginx on :80)…"
ok=0
for path in /health /small /medium /large; do
  code="$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://127.0.0.1${path}" 2>/dev/null || echo "000")"
  echo "${code} ${path}"
  [[ "$code" == "200" ]] && ok=$((ok + 1)) || true
done

if [[ "$ok" -lt 4 ]]; then
  echo ""
  echo "Some checks failed. Debug:"
  echo "  curl -sS http://127.0.0.1:9000/health"
  echo "  systemctl status ${SERVICE_NAME} nginx --no-pager"
  echo "  getenforce && sudo setsebool -P httpd_can_network_connect 1 && sudo systemctl restart nginx"
  echo "  sudo tail -20 /var/log/nginx/error.log"
fi

echo "Done. Backend: systemctl status ${SERVICE_NAME} | Nginx: systemctl status nginx"
