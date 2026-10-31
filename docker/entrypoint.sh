#!/usr/bin/env bash
# Each file in /run/secrets becomes one environment variable, named after the file,
# upper-cased, '-' and '.' turned into '_'  (pg_prod_password → PG_PROD_PASSWORD).
# Command configs reference them with {"provider":"env","var":"PG_PROD_PASSWORD"}.
# Values are never echoed.
set -euo pipefail
shopt -s nullglob
loaded=0
for f in /run/secrets/*; do
  [ -f "$f" ] || continue
  name="$(basename "$f" | tr '[:lower:].-' '[:upper:]__')"
  [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "entrypoint: skipping secret with unusable name" >&2; continue; }
  [ -r "$f" ] || { echo "entrypoint: secret file $name is not readable by $(id -un)" >&2; exit 1; }
  # Assign first, then export: `export NAME=$(< "$f")` takes export's exit status and
  # would hide a failed read.
  value="$(< "$f")" || { echo "entrypoint: cannot read secret $name" >&2; exit 1; }
  export "$name=$value"
  loaded=$((loaded + 1))
done
# The container split relies on being able to prove, from the
# outside, that one container's daemon holds only its own database's secrets. Never logs
# names or values — only the count.
echo "entrypoint: loaded $loaded secrets" >&2
# The root filesystem is read-only and /etc/sneek is a read-only mount; sneekd wants a
# writable config dir (logs, pid). Copy the configs onto the tmpfs home.
CONF="$HOME/.config/sneek"
mkdir -p "$CONF/commands"
# A missing or empty commands dir is fine and logged; a real copy failure (EROFS,
# ENOSPC, unreadable mount) must stop the daemon rather than start it half-configured.
copied=0
for f in /etc/sneek/commands/*.json; do
  cp "$f" "$CONF/commands/" || { echo "entrypoint: cannot copy $f into $CONF/commands" >&2; exit 1; }
  copied=$((copied + 1))
done
[ "$copied" -gt 0 ] || echo "entrypoint: no command files in /etc/sneek/commands" >&2
if [ -f /etc/sneek/config.json ]; then
  cp /etc/sneek/config.json "$CONF/config.json" \
    || { echo "entrypoint: cannot copy config.json into $CONF" >&2; exit 1; }
fi
# The daemon only reads its config. Every child it starts runs as the same uid, and a
# client with file I/O (cqlsh SOURCE/COPY/CAPTURE, mongosh) could otherwise rewrite the
# live command files — a change the daemon would pick up within its 3-second poll.
# Read-only for the owner too; the daemon tolerates an existing unwritable commands dir.
chmod 0500 "$CONF/commands"
chmod 0400 "$CONF/commands/"*.json "$CONF/config.json" 2>/dev/null || true
# A server daemon must never come up with the socket unrestricted or with the prod
# read-only check off: either one silently turns a hardened deployment back into the
# permissive Mac one. Both are checked in the config the daemon will actually read
# ($CONF/config.json, the copy made above), so a missing /etc/sneek/config.json fails
# here too rather than starting on defaults. SNEEK_SERVER=1 comes from the Dockerfile,
# so the check is on by default for every container built from this image. The grep is
# line-based: keep each key and its value on one line of config.json.
if [ "${SNEEK_SERVER:-0}" = "1" ]; then
  for key in restrict_socket require_readonly_prod; do
    grep -q "\"$key\"[[:space:]]*:[[:space:]]*true" "$CONF/config.json" 2>/dev/null \
      || { echo "entrypoint: refusing to start a server daemon without $key: true" >&2; exit 1; }
  done
fi
# --config-dir, not $HOME: corelibs Foundation resolves the home directory from the
# passwd entry rather than the environment, so $HOME alone is not authoritative here.
exec /usr/local/bin/sneekd start --config-dir "$CONF"
