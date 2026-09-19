#!/usr/bin/env sh
# Create .env from .env.example with freshly generated secrets.
#
#   ./scripts/init-secrets.sh            # run from anywhere; writes <stack>/.env
#
# Every empty variable in .env.example whose name ends in _KEY, _PASSWORD or _TOKEN
# gets a random value (openssl, or /dev/urandom as a fallback). The script REFUSES to
# overwrite an existing .env: rotating N8N_ENCRYPTION_KEY makes every stored credential
# unreadable, so that must always be a deliberate, manual step.
set -eu

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$STACK_DIR/.env.example"
TARGET="${ENV_FILE:-$STACK_DIR/.env}"

if [ -e "$TARGET" ]; then
  echo "ERROR: $TARGET already exists. Refusing to overwrite it (this would replace N8N_ENCRYPTION_KEY)." >&2
  echo "       Delete it yourself only if this is a brand-new installation with no data." >&2
  exit 1
fi
[ -f "$EXAMPLE" ] || { echo "ERROR: $EXAMPLE not found" >&2; exit 1; }

random_hex() { # bytes
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$1"
  else
    od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
  fi
}

umask 077
tmp="$TARGET.tmp.$$"
generated=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    *_KEY= | *_PASSWORD= | *_TOKEN=)
      name="${line%=}"
      case "$name" in
        *[!A-Z0-9_]*) printf '%s\n' "$line" ;;
        *)
          printf '%s=%s\n' "$name" "$(random_hex 32)"
          generated="$generated $name"
          ;;
      esac
      ;;
    *) printf '%s\n' "$line" ;;
  esac
done <"$EXAMPLE" >"$tmp"
mv "$tmp" "$TARGET"
chmod 600 "$TARGET"

echo "Created $TARGET (mode 600) with generated:$generated"
echo
echo "Next:"
echo "  1. Edit N8N_DOMAIN, N8N_PUBLIC_URL and CADDY_TLS in $TARGET"
echo "  2. Store N8N_ENCRYPTION_KEY in your password manager NOW. Backups are useless without it."
echo "  3. docker compose up -d"
