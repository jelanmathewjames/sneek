#!/usr/bin/env bash
# Runs a dev-built daemon INSIDE a container (never on the host) and checks
# config reload, SIGTERM handling, and dead-session recovery.
set -euo pipefail
IMAGE="swift@sha256:7060a792f4cd9eaa0d00826d941cec00ab8d252d33b8b28bc8e105f51f2dba73"   # swift:6.3-bookworm
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
docker run --rm --name sneek-check -v "$REPO":/src:ro -v sneek-linux-build:/build -w /work "$IMAGE" bash -euc '
  mkdir -p /work && cp -a /src/. /work/ && rm -rf /work/.build && ln -s /build /work/.build
  swift build --product sneekd
  BIN=$(swift build --product sneekd --show-bin-path)/sneekd
  # corelibs Foundation resolves the home from the passwd entry, not $HOME (hence --config-dir).
  CFG="$(getent passwd "$(id -u)" | cut -d: -f6)/.config/sneek"; mkdir -p "$CFG/commands"
  $BIN start & PID=$!
  for i in $(seq 1 20); do [ -S "$CFG/sneekd.sock" ] && break; sleep 0.5; done

  echo "{\"name\":\"late\",\"description\":\"d\",\"mode\":\"oneshot\",\"command\":\"echo one\"}" > "$CFG/commands/late.json"
  ok=0; for i in $(seq 1 10); do [ "$($BIN run late 2>/dev/null)" = "one" ] && { ok=1; break; }; sleep 1; done
  [ $ok = 1 ] && echo "PASS new file picked up" || { echo "FAIL new file not picked up in 10s"; exit 1; }

  sleep 1.1   # mtime granularity
  echo "{\"name\":\"late\",\"description\":\"d\",\"mode\":\"oneshot\",\"command\":\"echo two\"}" > "$CFG/commands/late.json"
  ok=0; for i in $(seq 1 10); do [ "$($BIN run late 2>/dev/null)" = "two" ] && { ok=1; break; }; sleep 1; done
  [ $ok = 1 ] && echo "PASS edit picked up" || { echo "FAIL edit not picked up in 10s"; exit 1; }

  # --- dead-session recovery ---
  echo "{\"name\":\"sh\",\"description\":\"d\",\"mode\":\"session\",\"command\":\"exec bash --norc --noprofile\",\"sentinel\":\"echo __SNEEK_DONE__\"}" > "$CFG/commands/sh.json"
  sleep 4
  [ "$($BIN run sh "echo alive")" = "alive" ] || { echo "FAIL session"; exit 1; }
  $BIN run sh "kill -9 \$\$" >/dev/null 2>&1 || true        # the child kills itself mid-request
  kill -0 $PID || { echo "FAIL daemon died with its child (SIGPIPE?)"; exit 1; }
  [ "$($BIN run sh "echo back")" = "back" ] && echo "PASS daemon survived a dead session and restarted it" || { echo "FAIL no recovery"; exit 1; }

  kill -TERM $PID
  for i in $(seq 1 10); do kill -0 $PID 2>/dev/null || break; sleep 0.5; done
  kill -0 $PID 2>/dev/null && { echo "FAIL still running 5s after SIGTERM"; exit 1; }
  [ -e "$CFG/sneekd.sock" ] && { echo "FAIL socket left behind"; exit 1; }
  echo "PASS clean SIGTERM"
'

# --- Two-daemon split: checks against the BUILT image (sneekd:dev), not the
# swift toolchain. Rebuild sneekd:dev first so it contains the prctl change:
#   docker build -f docker/Dockerfile -t sneekd:dev .
IMG="sneekd:dev"
rc=0

# Installed before the first container starts: any abort past this point (a failed
# `docker run`, a pipeline under `set -o pipefail` finding no match, etc.) must still
# remove every container this section can create — never leak sneek-split-* containers.
split_cleanup() {
  docker rm -f sneek-split-priv sneek-split-pg sneek-split-mongo sneek-nogate >/dev/null 2>&1 || true
  [ -n "${PRIV_CFG:-}" ] && rm -rf "$PRIV_CFG"
  [ -n "${MONGO_CFG:-}" ] && rm -rf "$MONGO_CFG"
  [ -n "${MONGO_SECRETS:-}" ] && rm -rf "$MONGO_SECRETS"
  [ -n "${T19_CFG:-}" ] && rm -rf "$T19_CFG"
  return 0    # the last `[ -n … ]` must not decide this function's (and the script's) exit status
}
trap split_cleanup EXIT

# --- 1. PR_SET_DUMPABLE: a same-uid child cannot read the daemon's own /proc/<pid>/environ ---
PRIV_CFG="$(mktemp -d)"; mkdir -p "$PRIV_CFG/commands"
echo '{"socket_path":"/run/sneek/sneekd.sock","socket_mode":"0660","restrict_socket":true,"require_readonly_prod":true}' > "$PRIV_CFG/config.json"
echo '{"name":"sh","description":"split","mode":"session","command":"exec bash --norc --noprofile","sentinel":"echo __SNEEK_DONE__"}' > "$PRIV_CFG/commands/sh.json"

docker rm -f sneek-split-priv >/dev/null 2>&1 || true
docker run -d --rm --name sneek-split-priv \
  --security-opt no-new-privileges:true --read-only --cap-drop ALL --init \
  --tmpfs /var/lib/sneek:uid=2001,gid=2001,mode=0700 --tmpfs /tmp:uid=2001,gid=2001,mode=0700 \
  --tmpfs /run/sneek:uid=2001,gid=2100,mode=2770 \
  -v "$PRIV_CFG:/etc/sneek:ro" \
  "$IMG" >/dev/null || { echo "FAIL sneek-split-priv did not start"; exit 1; }

for i in $(seq 1 30); do docker exec sneek-split-priv test -S /run/sneek/sneekd.sock 2>/dev/null && break; sleep 0.5; done
out="$(docker exec sneek-split-priv sneekd run sh 'cat /proc/$PPID/environ | tr "\0" "\n" | grep -c PASSWORD; echo rc=$?' 2>&1 || true)"
docker logs sneek-split-priv 2>&1 | grep -q "process memory hidden from same-user processes" \
  && echo "PASS daemon logged PR_SET_DUMPABLE applied" || { echo "FAIL no PR_SET_DUMPABLE log line"; rc=1; }
if echo "$out" | grep -q "Permission denied" && echo "$out" | grep -q "rc=1"; then
  echo "PASS child cannot read the daemon's /proc/<ppid>/environ: $out"
else
  echo "FAIL expected Permission denied + rc=1, got: $out"; rc=1
fi
docker rm -f sneek-split-priv >/dev/null 2>&1 || true

# --- 2. Two-container split: a Mongo-only daemon holds only Mongo secrets and lists
# only Mongo tools. "sneekd" reuses Tests/e2e's real Postgres config/secrets; "sneekd-mongo"
# gets a separate, throwaway Mongo-only config/secrets pair built here (no production
# Mongo, no VPN — the command is never actually run, only listed). ---
E2E="$REPO/Tests/e2e"
MONGO_CFG="$(mktemp -d)"; mkdir -p "$MONGO_CFG/commands"
MONGO_SECRETS="$(mktemp -d)"
echo '{"socket_path":"/run/sneek/sneekd.sock","socket_mode":"0660","restrict_socket":true,"require_readonly_prod":true}' > "$MONGO_CFG/config.json"
cat > "$MONGO_CFG/commands/mongo-ro.json" <<'JSON'
{"name":"mongo-ro","description":"split Mongo read-only role","tags":["prod"],"mode":"oneshot","readonly":true,
 "command":"mongosh --quiet --eval \"db.runCommand({ping:1})\" \"mongodb://ro:{{password}}@mongo:27017/app\"",
 "secrets":{"password":{"provider":"env","var":"MONGO_RO_PASSWORD"}},
 "mcp":{"enabled":true,"tool_name":"mongo_ro","tool_description":"split Mongo"}}
JSON
echo -n "not-a-real-password-split" > "$MONGO_SECRETS/mongo_ro_password"

docker rm -f sneek-split-pg sneek-split-mongo >/dev/null 2>&1 || true
docker run -d --rm --name sneek-split-pg \
  --security-opt no-new-privileges:true --read-only --cap-drop ALL --init \
  --tmpfs /var/lib/sneek:uid=2001,gid=2001,mode=0700 --tmpfs /tmp:uid=2001,gid=2001,mode=0700 \
  --tmpfs /run/sneek:uid=2001,gid=2100,mode=2770 \
  -v "$E2E/config:/etc/sneek:ro" -v "$E2E/secrets:/run/secrets:ro" \
  "$IMG" >/dev/null || { echo "FAIL sneek-split-pg did not start"; exit 1; }
docker run -d --rm --name sneek-split-mongo \
  --security-opt no-new-privileges:true --read-only --cap-drop ALL --init \
  --tmpfs /var/lib/sneek:uid=2001,gid=2001,mode=0700 --tmpfs /tmp:uid=2001,gid=2001,mode=0700 \
  --tmpfs /run/sneek:uid=2001,gid=2100,mode=2770 \
  -v "$MONGO_CFG:/etc/sneek:ro" -v "$MONGO_SECRETS:/run/secrets:ro" \
  "$IMG" >/dev/null || { echo "FAIL sneek-split-mongo did not start"; exit 1; }

for c in sneek-split-pg sneek-split-mongo; do
  for i in $(seq 1 30); do docker exec "$c" test -S /run/sneek/sneekd.sock 2>/dev/null && break; sleep 0.5; done
done

# Speaks the socket directly (as an MCP client would; "tools" is the IPC action),
# via python3 which the runtime image already carries for cqlsh.
TOOLS_PY='import json,socket
s=socket.socket(socket.AF_UNIX); s.connect("/run/sneek/sneekd.sock")
s.sendall(json.dumps({"action":"tools"}).encode()+b"\n")
buf=b""
while not buf.endswith(b"\n"):
    chunk=s.recv(65536)
    if not chunk: break
    buf+=chunk
print(buf.decode())'
tools_json="$(docker exec sneek-split-mongo python3 -c "$TOOLS_PY" 2>&1 || true)"
if echo "$tools_json" | grep -q "mongo_ro" && ! echo "$tools_json" | grep -qE "pg_ro|pg_app"; then
  echo "PASS sneekd-mongo lists only Mongo tools: $tools_json"
else
  echo "FAIL sneekd-mongo tools list is not Mongo-only: $tools_json"; rc=1
fi

# `grep -o` with no match exits 1; under pipefail that would abort the whole script
# (skipping the FAIL message below and, before split_cleanup existed, the teardown too).
# `|| true` makes a miss an empty string instead, so the comparison below reports it.
pg_secrets="$(docker logs sneek-split-pg 2>&1 | grep -o 'loaded [0-9]* secrets' | tail -1 || true)"
mongo_secrets="$(docker logs sneek-split-mongo 2>&1 | grep -o 'loaded [0-9]* secrets' | tail -1 || true)"
# The Postgres daemon mounts Tests/e2e/secrets, whose file count changes as the E2E suite
# grows — count the directory rather than hard-coding it.
# The point of the check is the *split*: each daemon sees its own secrets and only those.
pg_expected="$(find "$E2E/secrets" -maxdepth 1 -type f | wc -l | tr -d ' ')"
if [ "$pg_secrets" = "loaded $pg_expected secrets" ] && [ "$mongo_secrets" = "loaded 1 secrets" ]; then
  echo "PASS each daemon loaded only its own secrets (pg: $pg_secrets, mongo: $mongo_secrets)"
else
  echo "FAIL secret counts wrong (pg: '$pg_secrets', expected $pg_expected; mongo: '$mongo_secrets')"; rc=1
fi

# --- 3. The image refuses to start a server daemon whose config is
# missing one of the two keys a server must never run without. SNEEK_SERVER=1 comes
# from the image, so no -e flag is needed to arm the check. The container must exit 1
# with the entrypoint's message; a daemon coming up at all is the failure. ---
T19_CFG="$(mktemp -d)"; mkdir -p "$T19_CFG/commands"
# restrict_socket is present and true; require_readonly_prod is absent entirely.
echo '{"socket_path":"/run/sneek/sneekd.sock","socket_mode":"0660","restrict_socket":true}' > "$T19_CFG/config.json"
echo '{"name":"sh","description":"nogate","mode":"oneshot","command":"echo hi"}' > "$T19_CFG/commands/sh.json"

docker rm -f sneek-nogate >/dev/null 2>&1 || true
nogate_out="$(docker run --rm --name sneek-nogate \
  --security-opt no-new-privileges:true --read-only --cap-drop ALL --init \
  --tmpfs /var/lib/sneek:uid=2001,gid=2001,mode=0700 --tmpfs /tmp:uid=2001,gid=2001,mode=0700 \
  --tmpfs /run/sneek:uid=2001,gid=2100,mode=2770 \
  -v "$T19_CFG:/etc/sneek:ro" \
  "$IMG" 2>&1)" && nogate_rc=0 || nogate_rc=$?
if [ "$nogate_rc" = "1" ] && echo "$nogate_out" | grep -q "refusing to start a server daemon without require_readonly_prod: true"; then
  echo "PASS image refuses a server config without require_readonly_prod (exit 1)"
else
  echo "FAIL expected exit 1 + refusal message, got rc=$nogate_rc: $nogate_out"; rc=1
fi

exit $rc
