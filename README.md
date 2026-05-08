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

Requirements: [Go](https://go.dev/dl/) 1.21+.

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
| `deploy/nginx.conf` | Sample full `nginx.conf` for high-connection proxying |
| `deploy/json-load-backend.service` | Sample systemd unit |

## License

See [LICENSE](LICENSE).
