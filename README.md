# OpenResty Dynamic Upstream Discovery

Zero-downtime rolling updates for Docker Compose services using OpenResty and the Docker socket.

A Lua timer queries the Docker API every few seconds, discovers containers by label, and adds/removes them from native nginx upstreams via [ngx_dynamic_upstream](https://github.com/ZigzagAK/ngx_dynamic_upstream). No per-request Lua runs in the proxy path — nginx handles all balancing in C.

## How it works

```
┌─────────────────────────────────────────────────┐
│                   OpenResty                     │
│                                                 │
│  init_worker_by_lua (worker 0 only)             │
│    └─ timer every 2s:                           │
│         1. GET /containers/json via docker.sock  │
│         2. Filter by upstream.enable=true label  │
│         3. Compare with current upstream peers   │
│         4. add_primary_peer() / remove_peer()   │
│                                                 │
│  upstream app-web { zone app-web 256k; ... }    │
│  upstream app-api { zone app-api 256k; ... }    │
│                                                 │
│  proxy_pass http://app-web;  ← native balancing │
└───────────────┬─────────────────────────────────┘
                │ docker.sock (read-only)
┌───────────────▼─────────────────────────────────┐
│              Docker Engine                      │
│                                                 │
│  app-web-1  app-web-2  app-web-3  app-api-1 .. │
│  (upstream.enable=true, upstream.name=app-web)  │
└─────────────────────────────────────────────────┘
```

## Quick start

```bash
# Start the gateway (creates the shared network)
cd gateway && docker compose up -d --build

# Start backend services (can be in separate compose projects)
cd apps/web && docker compose up -d --build
cd apps/api && docker compose up -d --build

# Test
curl -H "Host: web.localhost" http://localhost/
curl -H "Host: api.localhost" http://localhost/

# Check discovered backends
curl http://localhost/gateway/status
```

## Container labels

Backend containers opt in via Docker labels:

```yaml
labels:
  upstream.enable: "true"       # required — discovery filter
  upstream.name: "app-web"      # required — maps to an upstream block in nginx.conf
  upstream.port: "8080"         # required — container port to proxy to
```

Containers must be on the same Docker network as the gateway (default: `gateway_net`).

## Gateway configuration

All configuration is via environment variables:

| Variable | Default | Description |
|---|---|---|
| `DISCOVERY_INTERVAL` | `2` | Seconds between Docker API polls |
| `NETWORK_NAME` | `gateway_net` | Docker network to read container IPs from |
| `UPSTREAMS` | `app-web,app-api` | Comma-separated list of upstream names |

Each upstream name must have a matching `upstream` block and `server` block in `nginx.conf`.

## Adding a new service

1. Add an `upstream` block and `server` block in `nginx.conf`:

```nginx
upstream my-service {
    zone my-service 256k;
    server 0.0.0.1 down;  # placeholder
}

server {
    listen 80;
    listen [::]:80;
    server_name my-service.localhost;

    location / {
        proxy_pass http://my-service;
        # ...
    }
}
```

2. Add the upstream name to the `UPSTREAMS` environment variable:

```yaml
environment:
  - UPSTREAMS=app-web,app-api,my-service
```

3. Label your containers:

```yaml
labels:
  upstream.enable: "true"
  upstream.name: "my-service"
  upstream.port: "3000"
```

## Rolling update scenarios

**Update with new image:**
```bash
docker compose pull && docker compose up -d
```
New containers start, discovery adds them within 2s, old containers stop, discovery removes them. `proxy_next_upstream` retries handle the brief overlap.

**Scale replicas:**
```bash
docker compose up -d --scale web=5
```
New containers are discovered and added automatically.

**Service down:**
```bash
docker compose down
```
Containers disappear from Docker API, discovery removes them from the upstream. Other services are unaffected.

**New service:**
```bash
docker compose up -d
```
Containers with the right labels are discovered and added within 2s.

## Health checks

Health checks are handled by Docker, not the gateway. Configure them in your compose file:

```yaml
healthcheck:
  test: ["CMD", "wget", "-q", "--spider", "http://localhost:8080/healthz"]
  interval: 3s
  timeout: 2s
  retries: 3
  start_period: 2s
```

Discovery skips containers that Docker reports as `(unhealthy)`.

## Status endpoint

```bash
curl http://localhost/gateway/status
```

```json
{
  "services": {
    "app-web": [
      {"name": "172.28.0.3:8080", "weight": 1, "max_fails": 1},
      {"name": "172.28.0.4:8080", "weight": 1, "max_fails": 1},
      {"name": "172.28.0.5:8080", "weight": 1, "max_fails": 1}
    ],
    "app-api": [
      {"name": "172.28.0.6:9090", "weight": 1, "max_fails": 1}
    ]
  }
}
```

## Tests

```bash
./test.sh
```

Runs 18 integration tests covering: gateway health, no-backend handling, service discovery, round-robin distribution, multi-service isolation, rolling updates, scaling, service down/up, and the status endpoint.

## Project structure

```
├── gateway/
│   ├── Dockerfile           # Builds OpenResty with ngx_dynamic_upstream
│   ├── docker-compose.yml
│   ├── nginx.conf           # Upstream blocks + server blocks
│   └── lua/
│       ├── config.lua       # Env-driven configuration
│       ├── docker.lua       # Docker socket API client
│       ├── discovery.lua    # Sync Docker containers → nginx upstreams
│       └── init.lua         # Timer setup
├── apps/
│   ├── web/                 # Example app (3 replicas)
│   └── api/                 # Example app (2 replicas)
└── test.sh
```

## Limitations

- **IPv6 upstream peers**: `ngx_dynamic_upstream` does not support IPv6 addresses as upstream peers. The gateway itself listens on both IPv4 and IPv6, and the Docker network supports dual-stack, but container-to-container proxying uses IPv4.
- **Upstream list in nginx.conf**: Each upstream must be declared statically in `nginx.conf`. The discovery timer populates them dynamically, but the blocks themselves require a reload to add or remove.

## Dependencies

- [OpenResty](https://openresty.org/) 1.27.1.2
- [ngx_dynamic_upstream](https://github.com/ZigzagAK/ngx_dynamic_upstream) — native C module for runtime upstream peer management
- [ngx_dynamic_upstream_lua](https://github.com/ZigzagAK/ngx_dynamic_upstream_lua) — Lua bindings for the above
- [lua-resty-http](https://github.com/ledgetech/lua-resty-http) — HTTP client for Docker socket communication
