#!/usr/bin/env bash
# Don't use set -e: we handle failures ourselves via check()
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

green()  { printf "\033[32m%s\033[0m\n" "$*"; }
red()    { printf "\033[31m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }

check() {
    local desc="$1"; shift
    if "$@"; then
        green "  ✓ $desc"
        ((PASS++))
    else
        red "  ✗ $desc"
        ((FAIL++))
    fi
}

wait_for_gateway() {
    local i=0
    while ! curl -sf http://localhost/gateway/health >/dev/null 2>&1; do
        sleep 1
        ((i++)) || true
        if [ "$i" -ge 30 ]; then
            red "Gateway did not become ready in 30s"
            return 1
        fi
    done
}

wait_for_backends() {
    local host="$1"
    local max_wait="${2:-15}"
    local i=0
    while true; do
        local code
        code=$(curl -sf -o /dev/null -w "%{http_code}" -H "Host: $host" http://localhost/ 2>/dev/null) || true
        if [ "$code" = "200" ]; then
            return 0
        fi
        sleep 1
        ((i++)) || true
        if [ "$i" -ge "$max_wait" ]; then
            return 1
        fi
    done
}

cleanup() {
    bold "Cleaning up..."
    (cd "$ROOT/apps/web" && docker compose down --remove-orphans 2>/dev/null) || true
    (cd "$ROOT/apps/api" && docker compose down --remove-orphans 2>/dev/null) || true
    (cd "$ROOT/gateway" && docker compose down --remove-orphans 2>/dev/null) || true
    docker network rm gateway_net 2>/dev/null || true
}

# --- Start ---
bold "=== OpenResty Rolling Update Tests ==="
echo

cleanup
echo

# -------------------------------------------------------
bold "1. Setup: Start gateway"
# -------------------------------------------------------
(cd "$ROOT/gateway" && docker compose up -d --build 2>&1)
wait_for_gateway
check "Gateway is healthy" curl -sf http://localhost/gateway/health >/dev/null
echo

# -------------------------------------------------------
bold "2. No backends: requesting unknown host returns error"
# -------------------------------------------------------
status=$(curl -sf -o /dev/null -w "%{http_code}" -H "Host: web.localhost" http://localhost/ 2>/dev/null) || true
check "Returns 502 when no backends" [ "$status" = "502" ]
echo

# -------------------------------------------------------
bold "3. Start app-web (3 replicas)"
# -------------------------------------------------------
(cd "$ROOT/apps/web" && docker compose up -d --build 2>&1)
check "web backends discovered" wait_for_backends "web.localhost" 20

# Verify round-robin across replicas.
declare -A WEB_HOSTS=()
for i in $(seq 1 12); do
    resp=$(curl -sf -H "Host: web.localhost" http://localhost/ 2>/dev/null) || true
    host=$(echo "$resp" | grep -oP 'host=\K[^\s|]+') || true
    if [ -n "$host" ]; then
        WEB_HOSTS["$host"]=1
    fi
done
unique_hosts=${#WEB_HOSTS[@]}
check "Traffic reaches multiple replicas (got $unique_hosts)" [ "$unique_hosts" -ge 2 ]
echo

# -------------------------------------------------------
bold "4. Start app-api (2 replicas) — new service"
# -------------------------------------------------------
(cd "$ROOT/apps/api" && docker compose up -d --build 2>&1)
check "api backends discovered" wait_for_backends "api.localhost" 20

api_resp=$(curl -sf -H "Host: api.localhost" http://localhost/ 2>/dev/null) || true
check "api returns JSON with service=api" grep -q '"service"' <<< "$api_resp"

web_resp=$(curl -sf -H "Host: web.localhost" http://localhost/ 2>/dev/null) || true
check "web still works after api started" grep -q "web" <<< "$web_resp"
echo

# -------------------------------------------------------
bold "5. Rolling update: change web to v2"
# -------------------------------------------------------
(cd "$ROOT/apps/web" && APP_VERSION=v2 docker compose up -d --build --force-recreate 2>&1)
sleep 5

found_v2=false
for i in $(seq 1 15); do
    resp=$(curl -sf -H "Host: web.localhost" http://localhost/ 2>/dev/null) || true
    if echo "$resp" | grep -q "v2"; then
        found_v2=true
        break
    fi
    sleep 1
done
check "web v2 is being served after rolling update" [ "$found_v2" = "true" ]

api_resp=$(curl -sf -H "Host: api.localhost" http://localhost/ 2>/dev/null) || true
check "api unaffected by web rolling update" grep -q '"service"' <<< "$api_resp"
echo

# -------------------------------------------------------
bold "6. Scale up: increase web replicas to 5"
# -------------------------------------------------------
(cd "$ROOT/apps/web" && docker compose up -d --scale web=5 2>&1)
sleep 5

declare -A SCALED_HOSTS=()
for i in $(seq 1 20); do
    resp=$(curl -sf -H "Host: web.localhost" http://localhost/ 2>/dev/null) || true
    host=$(echo "$resp" | grep -oP 'host=\K[^\s|]+') || true
    if [ -n "$host" ]; then
        SCALED_HOSTS["$host"]=1
    fi
done
scaled_unique=${#SCALED_HOSTS[@]}
check "After scale-up, traffic reaches more replicas (got $scaled_unique)" [ "$scaled_unique" -ge 3 ]
echo

# -------------------------------------------------------
bold "7. Service down: stop app-web, api keeps working"
# -------------------------------------------------------
(cd "$ROOT/apps/web" && docker compose down 2>&1)
sleep 4

web_status=$(curl -sf -o /dev/null -w "%{http_code}" -H "Host: web.localhost" http://localhost/ 2>/dev/null) || true
check "web returns 502 after compose down" [ "$web_status" = "502" ]

api_resp=$(curl -sf -H "Host: api.localhost" http://localhost/ 2>/dev/null) || true
check "api still works after web down" grep -q '"service"' <<< "$api_resp"

check "Gateway still healthy" curl -sf http://localhost/gateway/health >/dev/null
echo

# -------------------------------------------------------
bold "8. Bring web back up"
# -------------------------------------------------------
(cd "$ROOT/apps/web" && docker compose up -d 2>&1)
check "web backends rediscovered" wait_for_backends "web.localhost" 20

web_resp=$(curl -sf -H "Host: web.localhost" http://localhost/ 2>/dev/null) || true
check "web responds again after restart" grep -q "web" <<< "$web_resp"
echo

# -------------------------------------------------------
bold "9. Gateway status endpoint"
# -------------------------------------------------------
status_resp=$(curl -sf http://localhost/gateway/status 2>/dev/null) || true
check "Status endpoint returns JSON" python3 -m json.tool <<< "$status_resp" >/dev/null 2>&1
check "Status shows app-web service" grep -q "app-web" <<< "$status_resp"
check "Status shows app-api service" grep -q "app-api" <<< "$status_resp"
echo

# --- Summary ---
bold "=== Results ==="
green "Passed: $PASS"
if [ "$FAIL" -gt 0 ]; then
    red "Failed: $FAIL"
else
    green "Failed: $FAIL"
fi
echo

bold "Cleaning up..."
cleanup

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
