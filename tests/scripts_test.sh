#!/usr/bin/env bash
# Behavioural tests for scripts/init-secrets.sh and scripts/check-config.sh.
# Everything runs in a temporary copy of the stack; nothing touches your own .env.
# The assertions below are single-quoted expressions evaluated by check(); variables are meant
# to expand at eval time, and some are only referenced from inside those strings.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
ok()   { echo "  ok  $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
check() { if eval "$1"; then ok "$2"; else fail "$2"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R "$ROOT/scripts" "$ROOT/.env.example" "$ROOT/compose.yaml" "$ROOT/Caddyfile" "$WORK/"

echo "==> scripts/init-secrets.sh"
"$WORK/scripts/init-secrets.sh" >/dev/null
ENV="$WORK/.env"
check '[ -f "$ENV" ]' ".env created"
check '[ "$(stat -c %a "$ENV" 2>/dev/null || stat -f %Lp "$ENV")" = 600 ]' ".env is mode 600"

key="$(sed -n 's/^N8N_ENCRYPTION_KEY=//p' "$ENV")"
pass="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$ENV")"
check '[ ${#key} -eq 64 ]' "N8N_ENCRYPTION_KEY is 64 hex characters"
check '[ ${#pass} -eq 64 ]' "POSTGRES_PASSWORD is 64 hex characters"
check '[[ "$key" =~ ^[0-9a-f]{64}$ ]]' "N8N_ENCRYPTION_KEY is hex"
check '[ "$key" != "$pass" ]' "the two secrets differ"

# A second run against a fresh target must produce different values.
ENV_FILE="$WORK/.env2" "$WORK/scripts/init-secrets.sh" >/dev/null
check '[ "$(sed -n "s/^N8N_ENCRYPTION_KEY=//p" "$WORK/.env2")" != "$key" ]' "secrets are random per run"
rm -f "$WORK/.env2"

# Never overwrite: rotating the encryption key would orphan every stored credential.
if "$WORK/scripts/init-secrets.sh" >/dev/null 2>&1; then
  fail "init-secrets.sh overwrote an existing .env"
else
  ok "init-secrets.sh refuses to overwrite an existing .env"
fi
check '[ "$(sed -n "s/^N8N_ENCRYPTION_KEY=//p" "$ENV")" = "$key" ]' "the existing key is untouched"

echo "==> scripts/check-config.sh"
# Straight after init-secrets.sh the placeholders are still in place: it must fail.
out="$("$WORK/scripts/check-config.sh" 2>&1 || true)"
check 'grep -q "N8N_DOMAIN is still the example value" <<<"$out"' "rejects the example domain"
check 'grep -q "CADDY_TLS is still the example value" <<<"$out"' "rejects the example ACME email"

configure() { # sed expressions applied to .env
  cp "$ENV" "$WORK/.env.bak"
  for e in "$@"; do sed -i.tmp "$e" "$ENV"; done
  rm -f "$ENV.tmp"
}

configure 's#^N8N_DOMAIN=.*#N8N_DOMAIN=n8n.acme.io#' \
          's#^N8N_PUBLIC_URL=.*#N8N_PUBLIC_URL=https://n8n.acme.io#' \
          's#^CADDY_TLS=.*#CADDY_TLS=ops@acme.io#'
if out="$("$WORK/scripts/check-config.sh" 2>&1)"; then
  ok "accepts a correctly configured .env"
else
  fail "rejected a correct .env: $out"
fi
cp "$ENV" "$WORK/.env.good"

expect_error() { # description pattern sed-expression...
  local desc=$1 pattern=$2; shift 2
  cp "$WORK/.env.good" "$ENV"
  for e in "$@"; do sed -i.tmp "$e" "$ENV"; done
  rm -f "$ENV.tmp"
  local out
  if out="$("$WORK/scripts/check-config.sh" 2>&1)"; then
    fail "$desc (accepted)"
  elif grep -q "$pattern" <<<"$out"; then
    ok "$desc"
  else
    fail "$desc (wrong error: $(grep ERROR <<<"$out" | head -1))"
  fi
}

expect_error "catches a public URL that does not match the domain" "does not match N8N_DOMAIN" \
  's#^N8N_PUBLIC_URL=.*#N8N_PUBLIC_URL=https://other.acme.io#'
expect_error "catches a plain-http public URL" "must start with https" \
  's#^N8N_PUBLIC_URL=.*#N8N_PUBLIC_URL=http://n8n.acme.io#'
expect_error "catches a trailing slash in the public URL" "must not end with a slash" \
  's#^N8N_PUBLIC_URL=.*#N8N_PUBLIC_URL=https://n8n.acme.io/#'
expect_error "catches a weak database password" "at least 32 random characters" \
  's#^POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=hunter2hunter2#'
expect_error "catches a placeholder encryption key" "placeholder" \
  's#^N8N_ENCRYPTION_KEY=.*#N8N_ENCRYPTION_KEY=changeme#'
expect_error "catches an empty encryption key" "N8N_ENCRYPTION_KEY is empty" \
  's#^N8N_ENCRYPTION_KEY=.*#N8N_ENCRYPTION_KEY=#'
expect_error "catches reusing one secret for both" "identical" \
  "s#^POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=$key#" \
  "s#^N8N_ENCRYPTION_KEY=.*#N8N_ENCRYPTION_KEY=$key#"
expect_error "catches a nonsensical CADDY_TLS" "must be an email address or 'internal'" \
  's#^CADDY_TLS=.*#CADDY_TLS=yes-please#'

cp "$WORK/.env.good" "$ENV"
chmod 644 "$ENV"
if out="$("$WORK/scripts/check-config.sh" 2>&1)"; then
  fail "catches a world-readable .env (accepted)"
else
  check 'grep -q "chmod 600" <<<"$out"' "catches a world-readable .env"
fi
chmod 600 "$ENV"

# CADDY_TLS=internal is valid but must be called out as a test-only setting.
cp "$WORK/.env.good" "$ENV"
sed -i.tmp 's#^CADDY_TLS=.*#CADDY_TLS=internal#' "$ENV"; rm -f "$ENV.tmp"
out="$("$WORK/scripts/check-config.sh" 2>&1)"
check 'grep -q "WARNING.*internal" <<<"$out"' "warns about CADDY_TLS=internal"

echo
[ "$fails" -eq 0 ] || { echo "$fails script check(s) failed"; exit 1; }
echo "script tests passed"
