#!/usr/bin/env bash
# /etc/sneek/health.tsv: one line per database, "<command name><TAB><query>", e.g.
#   pg-prod<TAB>select 1;
# Terminate the query the way the client expects (';' for psql/cqlsh): sessions are
# persistent, so an unterminated statement stays in the client's buffer and corrupts
# the next caller's query.
#   cass-prod<TAB>select now() from system.local;
#   prod-app-mongo<TAB>db.runCommand({ping:1}).ok
# Goes through the daemon's socket, so it proves secrets, client, network and login together.
set -euo pipefail
[ -f /etc/sneek/health.tsv ] || { echo "no /etc/sneek/health.tsv" >&2; exit 1; }
# `|| [ -n "$cmd" ]` so a final line without a trailing newline is still checked.
# `timeout 15` per query keeps N databases inside the Dockerfile's HEALTHCHECK --timeout=90s,
# so the per-database error line below survives instead of being cut off mid-run.
while IFS=$'\t' read -r cmd query || [ -n "$cmd" ]; do
  [ -z "$cmd" ] && continue
  # </dev/null: the child must never consume the rest of the TSV from this loop's stdin.
  timeout 15 /usr/local/bin/sneekd run "$cmd" "$query" </dev/null >/dev/null \
    || { echo "health: $cmd failed" >&2; exit 1; }
done < /etc/sneek/health.tsv
