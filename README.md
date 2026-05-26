# nginx-go-server

Go HTTP backend that serves precomputed JSON payloads at fixed size tiers, fronted by **Nginx** on port **80** proxying to the app on **127.0.0.1:9000**. Useful for load testing, benchmarking proxies, or verifying throughput with predictable response sizes.

## Architecture

- **Nginx** listens on `:80` and proxies to the Go process on `127.0.0.1:9000`.
- The Go server binds only to localhost; external traffic hits Nginx first.

## Endpoints

| Path      | Response                          |
| --------- | --------------------------------- |
| `/health` | Small JSON: `{"status":"ok"}`     |
| `/small`  | JSON ~5–10 KB (8 variants, round-robin) |
| `/medium` | JSON ~50–100 KB                   |
| `/large`  | JSON ~500 KB–1 MB                 |

Payloads are generated once at startup and reused (no per-request JSON marshaling for body content beyond selecting a variant).

## Local development

Requirements: [Go](https://go.dev/dl/) **1.18+** (module `go 1.18`; distro packages on Rocky 8 / EL8 are fine).

```bash
go build -o json-load-backend .
./json-load-backend
```

Sanity checks (backend directly):

```bash
curl -I http://127.0.0.1:9000/health
curl -I http://127.0.0.1:9000/small
curl -I http://127.0.0.1:9000/medium
curl -I http://127.0.0.1:9000/large

curl -s http://127.0.0.1:9000/small | wc -c
curl -s http://127.0.0.1:9000/medium | wc -c
curl -s http://127.0.0.1:9000/large | wc -c
```

## One-shot install (Ubuntu / Debian / Rocky / RHEL / Amazon Linux 2)

On a **dedicated load-test VM** (this **replaces** `/etc/nginx/nginx.conf`; a timestamped `.bak.*` is kept):

- **Debian / Ubuntu:** `apt-get` installs `golang`, `nginx`, `curl`. Nginx runs as `www-data` (matches `deploy/nginx.conf`).
- **Amazon Linux 2 (EC2):** uses **`yum`** (not `dnf`). Installs **nginx** via **`amazon-linux-extras install nginx1`** (~1.22). Installs **Go** from `yum` when available, otherwise from **go.dev** (`GO_VERSION` env, default `1.22.12`). Works with **`ec2-user`** (`SUDO_USER` or UID 1000).
- **Rocky / Alma / RHEL 8 / Amazon Linux 2023:** `dnf` (or `yum` on older trees) installs `golang`, `nginx`, `curl`. On **EL 8**, enables the newest **nginx** AppStream module when available. Deployed config uses **`user nginx`**.

```bash
chmod +x install.sh
sudo ./install.sh
```

The script builds the binary, installs it under `/opt/json-load-backend`, writes the systemd unit (runs as `SUDO_USER` or UID 1000), installs the sample nginx config, starts both services, and runs quick `curl` checks on port 80.

Override the service account if needed: `INSTALL_USER=myuser sudo ./install.sh`.

**Rocky / RHEL 8 and nginx 1.14:** AppStream often defaults to the **`nginx:1.14`** module, which is very old. The install script runs **`dnf module reset nginx`** then enables the **newest available stream** among `1.26`, `1.24`, `1.22`, `1.20`, `1.18` before **`dnf install nginx`**, so you get a current nginx without adding third-party repos.

To upgrade nginx manually on Rocky / Alma / RHEL **8**:

```bash
sudo dnf module list nginx
sudo dnf module reset -y nginx
sudo dnf module enable -y nginx:1.22
sudo dnf install -y nginx
nginx -v
sudo systemctl restart nginx
```

Use **`nginx:1.24`** or **`nginx:1.26`** instead of `1.22` if `dnf module list nginx` shows them on your minor release.

**Rocky / RHEL and SELinux:** With **Enforcing**, the default policy often blocks nginx from opening outbound TCP to the Go listener, so you get **502** even when `json-load-backend` is healthy. The install script runs `setsebool -P httpd_can_network_connect 1` on RHEL when `getenforce` is Enforcing. If you still see 502, confirm the app answers directly: `curl -sS http://127.0.0.1:9000/health` — if that works but port 80 does not, re-run `sudo setsebool -P httpd_can_network_connect 1` and `sudo systemctl restart nginx`, then check denials with `sudo ausearch -m avc -ts recent | tail`.

## Production-style setup (Linux)

The following matches a typical Ubuntu/VM deploy: install Go, build the binary, run under **systemd**, and put **Nginx** in front.

### 1. Install Go (example: Debian/Ubuntu)

```bash
sudo apt update
sudo apt install -y golang
go version
```

### 2. Build

From this repository:

```bash
go build -o json-load-backend .
```

### 3. Run as a systemd service

Install the binary (paths are examples):

```bash
sudo mkdir -p /opt/json-load-backend
sudo cp json-load-backend /opt/json-load-backend/
```

Copy the unit file from `deploy/json-load-backend.service` to `/etc/systemd/system/json-load-backend.service`. Edit `User=` to match the account that should own the process (the sample uses `azureuser`).

```bash
sudo systemctl daemon-reload
sudo systemctl enable json-load-backend
sudo systemctl start json-load-backend
sudo systemctl status json-load-backend
```

### 4. Configure Nginx

Use `deploy/nginx.conf` as a reference. On many distributions you merge snippets into `/etc/nginx/nginx.conf` or `sites-enabled/` instead of replacing the whole file—adapt to your distro’s layout.

Key points in the sample config:

- High `worker_connections`, `keepalive` to the upstream, and proxy buffering tuned for large JSON responses.
- Upstream `json_backend` → `127.0.0.1:9000`.

Validate and reload:

```bash
sudo nginx -t
sudo systemctl restart nginx
sudo systemctl status nginx
```

### 5. Test through Nginx

```bash
curl -I http://127.0.0.1/health
curl -I http://127.0.0.1/small
curl -I http://127.0.0.1/medium
curl -I http://127.0.0.1/large
```

## Repository layout

| Path | Purpose |
| ---- | ------- |
| `main.go` | Go HTTP server |
| `go.mod` | Go module definition |
| `install.sh` | One-shot install: apt, yum (AL2), or dnf; build, systemd, nginx, smoke checks |
| `deploy/nginx.conf` | Sample full `nginx.conf` for high-connection proxying |
| `deploy/json-load-backend.service` | Sample systemd unit |

## License

See [LICENSE](LICENSE).
