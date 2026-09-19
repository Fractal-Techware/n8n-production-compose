#!/usr/bin/env sh
# Check .env and the stack for the mistakes that break a self-hosted n8n in production.
#
#   ./scripts/check-config.sh            # checks <stack>/.env
#   ENV_FILE=/path/to/.env ./scripts/check-config.sh
#
# Exit code 0 = ready to start. Errors must be fixed; warnings are judgement calls.
set -eu

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$STACK_DIR/.env}"
errors=0
warnings=0

err()  { echo "ERROR:   $*" >&2; errors=$((errors + 1)); }
warn() { echo "WARNING: $*" >&2; warnings=$((warnings + 1)); }
ok()   { echo "  ok  $*"; }

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found. Run ./scripts/init-secrets.sh first." >&2; exit 1; }

# Read the file without executing it: only NAME=value lines, last one wins.
get() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1; }

# --- file permissions ---------------------------------------------------------
# GNU stat first: on Linux `stat -f` succeeds but prints filesystem info, so trying the
# BSD form first would silently return the wrong string instead of falling through.
mode="$(stat -c "%A" "$ENV_FILE" 2>/dev/null || stat -f "%Sp" "$ENV_FILE")"
case "$mode" in
  -rw-------) ok ".env is not readable by other users" ;;
  *) err ".env is $mode; it holds your encryption key and database password. Run: chmod 600 $ENV_FILE" ;;
esac

# --- required values ----------------------------------------------------------
for name in N8N_DOMAIN N8N_PUBLIC_URL CADDY_TLS N8N_ENCRYPTION_KEY POSTGRES_PASSWORD N8N_RUNNERS_AUTH_TOKEN; do
  value="$(get "$name")"
  [ -n "$value" ] || err "$name is empty in .env"
done

domain="$(get N8N_DOMAIN)"
public_url="$(get N8N_PUBLIC_URL)"
tls="$(get CADDY_TLS)"
key="$(get N8N_ENCRYPTION_KEY)"
pgpass="$(get POSTGRES_PASSWORD)"
runner_token="$(get N8N_RUNNERS_AUTH_TOKEN)"

# --- domain and URL -----------------------------------------------------------
case "$domain" in
  ""|n8n.example.com|*.example.com|example.com) err "N8N_DOMAIN is still the example value ($domain). Set your own DNS name." ;;
  *.*) ok "N8N_DOMAIN=$domain" ;;
  localhost) warn "N8N_DOMAIN=localhost: fine for a local trial, not for a real deployment." ;;
  *) err "N8N_DOMAIN=$domain does not look like a DNS name." ;;
esac

case "$public_url" in
  https://*) : ;;
  "") : ;;
  *) err "N8N_PUBLIC_URL must start with https:// (got $public_url). n8n builds webhook URLs from it." ;;
esac
case "$public_url" in
  */) err "N8N_PUBLIC_URL must not end with a slash (got $public_url)." ;;
esac
if [ -n "$public_url" ] && [ -n "$domain" ]; then
  host="$(printf '%s' "$public_url" | sed -e 's#^https\{0,1\}://##' -e 's#[:/].*$##')"
  if [ "$host" = "$domain" ]; then
    ok "N8N_PUBLIC_URL matches N8N_DOMAIN"
  else
    err "N8N_PUBLIC_URL host ($host) does not match N8N_DOMAIN ($domain). OAuth callbacks and webhooks will point at the wrong host."
  fi
fi

# --- TLS ----------------------------------------------------------------------
case "$tls" in
  internal) warn "CADDY_TLS=internal: Caddy issues its own certificate. Browsers will warn. Use your email address for a public deployment." ;;
  ""|admin@example.com|*@example.com) err "CADDY_TLS is still the example value ($tls). Use your real email (ACME) or the word 'internal'." ;;
  *@*.*) ok "CADDY_TLS=$tls (automatic HTTPS via ACME)" ;;
  *) err "CADDY_TLS must be an email address or 'internal' (got $tls)." ;;
esac

# --- secrets ------------------------------------------------------------------
check_secret() { # name value
  len=$(printf '%s' "$2" | wc -c | tr -d ' ')
  case "$2" in
    ""|changeme*|password*|n8n|admin|secret*|test*) err "$1 is empty or a placeholder. Generate it with ./scripts/init-secrets.sh." ; return ;;
  esac
  if [ "$len" -lt 32 ]; then
    err "$1 is only $len characters. Use at least 32 random characters (init-secrets.sh generates 64 hex)."
  else
    ok "$1 is $len characters"
  fi
}
check_secret N8N_ENCRYPTION_KEY "$key"
check_secret POSTGRES_PASSWORD "$pgpass"
check_secret N8N_RUNNERS_AUTH_TOKEN "$runner_token"
if [ -n "$key" ] && [ "$key" = "$pgpass" ]; then
  err "N8N_ENCRYPTION_KEY and POSTGRES_PASSWORD are identical. Generate separate values."
fi

# --- the stack itself ---------------------------------------------------------
[ -f "$STACK_DIR/Caddyfile" ] || err "Caddyfile is missing from $STACK_DIR"
if grep -rInq "^N8N_ENCRYPTION_KEY=[^[:space:]]" "$STACK_DIR/.env.example" 2>/dev/null; then
  err ".env.example contains a filled-in secret. It must ship empty."
fi
if [ -d "$STACK_DIR/.git" ] && command -v git >/dev/null 2>&1; then
  if git -C "$STACK_DIR" ls-files --error-unmatch .env >/dev/null 2>&1; then
    err ".env is tracked by git. Remove it from the repository and rotate the secrets."
  else
    ok ".env is not tracked by git"
  fi
fi
# `docker compose` (v2 plugin) or the standalone `docker-compose` binary.
compose() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then docker-compose "$@"
  else return 127; fi
}
if command -v docker >/dev/null 2>&1 && compose version >/dev/null 2>&1; then
  if (cd "$STACK_DIR" && compose --env-file "$ENV_FILE" config -q 2>/dev/null); then
    ok "docker compose config is valid"
  else
    err "docker compose config failed. Run: docker compose config"
  fi
fi

echo
if [ "$errors" -gt 0 ]; then
  echo "$errors error(s), $warnings warning(s). Fix the errors before starting the stack." >&2
  exit 1
fi
echo "Configuration looks good ($warnings warning(s)). Start it with: docker compose up -d"
