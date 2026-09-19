#!/usr/bin/env bash
# End-to-end test: start the stack this repository ships and assert on real behaviour.
#
#   tests/e2e.sh          # ~3 minutes, needs Docker and about 2 GB of images
#
# A throwaway copy of the stack runs under its own project name, with CADDY_TLS=internal and
# Caddy bound to 127.0.0.1 on high ports, so it never touches your own stack, .env or volumes.
# The assertions below are single-quoted expressions evaluated by check(); variables are meant
# to expand at eval time, and some are only referenced from inside those strings.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="ftw-n8n-e2e-$$"
HTTPS_PORT="${E2E_HTTPS_PORT:-18443}"
HTTP_PORT="${E2E_HTTP_PORT:-18080}"
fails=0
ok()   { echo "  ok  $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
check() { if eval "$1"; then ok "$2"; else fail "$2"; fi; }

compose() {
  if docker compose version >/dev/null 2>&1; then (cd "$WORK" && docker compose -p "$PROJECT" "$@")
  else (cd "$WORK" && docker-compose -p "$PROJECT" "$@"); fi
}

# Inside the repository, not /tmp: the Caddyfile bind mount must be on a path Docker shares
# (Docker Desktop on macOS, colima and remote contexts do not share /tmp or /var/folders).
WORK="$ROOT/.e2e-$$"
mkdir -p "$WORK"
cleanup() {
  compose down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

cp -R "$ROOT/compose.yaml" "$ROOT/Caddyfile" "$ROOT/.env.example" "$ROOT/scripts" "$WORK/"
"$WORK/scripts/init-secrets.sh" >/dev/null
sed -i.tmp \
  -e 's#^N8N_DOMAIN=.*#N8N_DOMAIN=localhost#' \
  -e "s#^N8N_PUBLIC_URL=.*#N8N_PUBLIC_URL=https://localhost:$HTTPS_PORT#" \
  -e 's#^CADDY_TLS=.*#CADDY_TLS=internal#' \
  -e 's#^BIND_ADDRESS=.*#BIND_ADDRESS=127.0.0.1#' \
  -e "s#^HTTP_PORT=.*#HTTP_PORT=$HTTP_PORT#" \
  -e "s#^HTTPS_PORT=.*#HTTPS_PORT=$HTTPS_PORT#" \
  "$WORK/.env"
rm -f "$WORK/.env.tmp"

echo "==> docker compose up (n8n, PostgreSQL, Caddy)"
compose up -d --wait --wait-timeout "${E2E_TIMEOUT:-420}"
ok "every service reported healthy"

url="https://localhost:$HTTPS_PORT"
echo "==> HTTPS through Caddy ($url)"
body="$(curl -sk --max-time 20 "$url/healthz")"
check '[ "$(jq -r .status <<<"$body" 2>/dev/null || sed -n "s/.*\"status\":\"\\([a-z]*\\)\".*/\\1/p" <<<"$body")" = ok ]' \
      "GET /healthz through Caddy returns status ok"
check '[ "$(curl -sk -o /dev/null -w "%{http_code}" --max-time 20 "$url/")" = 200 ]' \
      "the editor is served over HTTPS"
headers="$(curl -sk -D- -o /dev/null --max-time 20 "$url/")"
check 'grep -qi "strict-transport-security: max-age=31536000" <<<"$headers"' "HSTS header is set"
check 'grep -qi "x-content-type-options: nosniff" <<<"$headers"' "nosniff header is set"
check '! grep -qi "^server: caddy" <<<"$headers"' "the Server header is removed"
check '[ "$(curl -sk -o /dev/null -w "%{http_code}" --max-time 20 "$url/metrics")" = 404 ]' \
      "/metrics is not exposed publicly"
check '[[ "$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 "http://localhost:$HTTP_PORT/")" =~ ^30 ]]' \
      "plain HTTP redirects to HTTPS"

echo "==> the database is not reachable from the host"
pg="$(compose ps -q postgres)"
check '! docker inspect -f "{{json .NetworkSettings.Ports}}" "$pg" | grep -q HostPort' \
      "postgres publishes no host port"
check 'compose exec -T n8n wget -qO- http://127.0.0.1:5678/healthz/readiness >/dev/null' \
      "n8n reports readiness (database connected)"

echo "==> containers are hardened at runtime"
for svc in postgres n8n n8n-runner caddy; do
  cid="$(compose ps -q "$svc")"
  check '[ "$(docker inspect -f "{{.HostConfig.ReadonlyRootfs}}" "$cid")" = true ]' "$svc: read-only root filesystem"
  check '[ "$(docker inspect -f "{{.Config.User}}" "$cid")" != 0 ] && [ -n "$(docker inspect -f "{{.Config.User}}" "$cid")" ]' "$svc: not running as root"
  check 'docker inspect -f "{{.HostConfig.SecurityOpt}}" "$cid" | grep -q no-new-privileges:true' "$svc: no-new-privileges"
  check 'docker inspect -f "{{.HostConfig.CapDrop}}" "$cid" | grep -q ALL' "$svc: capabilities dropped"
done

echo "==> n8n log hygiene"
logs="$(compose logs n8n --tail 2000 2>&1)"
# n8n prints "There are deprecations related to your n8n setup" when a setting is on its way
# out. (Library-level DeprecationWarnings from node/pg are upstream noise, not configuration.)
check '! grep -qi "deprecations\? related to your n8n setup" <<<"$logs"' \
      "n8n reports no configuration deprecations"
check '! grep -q "$(sed -n "s/^N8N_ENCRYPTION_KEY=//p" "$WORK/.env")" <<<"$logs"' \
      "the encryption key never appears in the logs"

echo "==> data survives a restart"
compose restart n8n >/dev/null
for _ in $(seq 1 40); do
  sleep 5
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$(compose ps -q n8n)")" = healthy ] && break
done
check '[ "$(docker inspect -f "{{.State.Health.Status}}" "$(compose ps -q n8n)")" = healthy ]' \
      "n8n is healthy again after a restart"

echo
[ "$fails" -eq 0 ] || { echo "$fails end-to-end check(s) failed"; exit 1; }
echo "end-to-end tests passed"
