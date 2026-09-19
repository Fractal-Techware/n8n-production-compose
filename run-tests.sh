#!/usr/bin/env bash
# Run every check CI runs against this stack:
#
#   ./run-tests.sh              # everything, including the end-to-end stack test (~4 minutes)
#   ./run-tests.sh --static     # skip the end-to-end test (no images pulled, ~10 seconds)
#
#   1. shellcheck                 every shell script (skipped with a note when not installed)
#   2. tests/scripts_test.sh      init-secrets.sh and check-config.sh behaviour
#   3. tests/check_stack.py       assertions on the resolved `docker compose config`
#   4. tests/e2e.sh               starts the real stack and asserts on HTTPS, hardening, restart
#
# Needs Docker with Compose v2 (`docker compose`) or the standalone `docker-compose`,
# python3 (stdlib only) and curl.
set -euo pipefail
cd "$(dirname "$0")"

static_only=""
[ "${1:-}" = "--static" ] && static_only=1

SHELLCHECK_IMAGE="koalaman/shellcheck:v0.11.0"
SCRIPTS=(run-tests.sh scripts/init-secrets.sh scripts/check-config.sh tests/scripts_test.sh tests/e2e.sh)

echo "==> shellcheck (${#SCRIPTS[@]} scripts)"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=style "${SCRIPTS[@]}"
elif command -v docker >/dev/null 2>&1; then
  docker run --rm -v "$PWD:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" --severity=style "${SCRIPTS[@]}"
else
  echo "  -- shellcheck and Docker are both missing, skipped"
fi
echo "  ok  no shellcheck findings"

echo
echo "==> scripts (tests/scripts_test.sh)"
bash tests/scripts_test.sh

echo
echo "==> compose stack (tests/check_stack.py)"
WORK="$PWD/.check-config"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
cp .env.example "$WORK/.env.example"
cp -R scripts "$WORK/scripts"
ENV_FILE="$WORK/.env" "$WORK/scripts/init-secrets.sh" >/dev/null
sed -i.tmp \
  -e 's#^N8N_DOMAIN=.*#N8N_DOMAIN=n8n.test.invalid#' \
  -e 's#^N8N_PUBLIC_URL=.*#N8N_PUBLIC_URL=https://n8n.test.invalid#' \
  -e 's#^CADDY_TLS=.*#CADDY_TLS=ops@test.invalid#' \
  "$WORK/.env"
rm -f "$WORK/.env.tmp"
ENV_FILE="$WORK/.env" python3 tests/check_stack.py

if [ -n "$static_only" ]; then
  echo
  echo "Static checks passed (end-to-end test skipped)."
  exit 0
fi

echo
echo "==> end to end (tests/e2e.sh)"
bash tests/e2e.sh

echo
echo "All checks passed."
