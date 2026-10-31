#!/usr/bin/env bash
# End-to-end suite: the socket contract a server-side client is tested against.
# Everything runs in throwaway containers under the compose project `sneek-e2e`; the
# teardown below removes only this project's containers and volumes.
set -uo pipefail
cd "$(dirname "$0")"
cleanup() { docker compose down -v >/dev/null 2>&1; }
trap cleanup EXIT
cleanup
docker compose build sneekd || exit 1
docker compose up -d --wait sneekd || { docker compose logs sneekd; exit 1; }
rc=0

# The entrypoint must never mask a failed config copy or an unreadable secret.
logs="$(docker compose logs sneekd 2>&1)"
if grep -qE 'skipping|cannot read' <<<"$logs"; then
  echo "FAIL entrypoint masked a config/secret failure"; rc=1
else
  echo "PASS entrypoint copied configs and secrets without masking a failure"
fi

# The entrypoint makes the live config unwritable to the daemon's own uid, and the daemon
# must still have come up over it (ConfigStore tolerates an existing read-only dir).
modes="$(docker compose exec -T sneekd sh -c 'cd /var/lib/sneek/.config/sneek && stat -c %a commands commands/pg-ro.json config.json' 2>&1 | tr '\n' ' ')"
if [ "$modes" = "500 400 400 " ]; then
  echo "PASS live config is read-only to the daemon's uid (commands 0500, files 0400)"
else
  echo "FAIL live config modes: $modes"; rc=1
fi

docker compose run --rm client   || rc=1
docker compose run --rm outsider || rc=1
# The audit probes read the daemon's own tmpfs through `docker compose exec`, so they run
# here on the host rather than inside the client container, which has no docker.
python3 probes.py audit || rc=1
docker compose exec -T sneekd healthcheck.sh && echo "PASS healthcheck runs a real select 1" || { echo "FAIL healthcheck"; rc=1; }

# A secret must never reach the daemon's own log, however a client quoted it back at it.
leaks="$(docker compose exec -T sneekd sh -c 'grep -c -e canary -e app_pw /var/lib/sneek/.config/sneek/logs/sneekd.log' 2>/dev/null)"
if [ "$leaks" = "0" ]; then
  echo "PASS no secret in the daemon log"
else
  echo "FAIL secret in the daemon log (grep -c matched ${leaks:-no log})"; rc=1
fi
exit $rc
