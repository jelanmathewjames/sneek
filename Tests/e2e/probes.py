"""E2E probes for sneekd. Speaks the socket exactly as a server-side client does:
one JSON line out, one JSON line back, one request per connection."""
import concurrent.futures, json, socket, subprocess, sys, time

SOCK = "/run/sneek/sneekd.sock"
FAILED = []

def call(req, timeout=60):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(timeout)
    s.connect(SOCK)
    s.sendall(json.dumps(req).encode() + b"\n")
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk: break
        buf += chunk
    s.close()
    return json.loads(buf)

def run(command, query, **kw):
    return call({"action": "run", "command": command, "input": query}, **kw)

def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  -> {detail}"), flush=True)
    if not ok: FAILED.append(name)

def note(name, value):
    """Recorded, not asserted: a measurement the report quotes."""
    print(f"NOTE {name}: {value}", flush=True)

def member():
    r = call({"action": "tools"})
    check("tools: lists every command with its command name",
          r.get("success") and [(t["name"], t["command"], t["readonly"]) for t in r["tools"]]
          == [("sneek_cql_guard", "cql-guard", True), ("sneek_envdump", "envdump", False),
              ("sneek_pg_app", "pg-app", True), ("sneek_pg_ro", "pg-ro", True)], r)
    check("tools: description carries [read-only]", r["tools"][2]["description"] == "E2E Postgres [read-only]", r)

    t = time.time(); r = run("pg-ro", "select id, note from tickets;"); note("first pg-ro call (s)", round(time.time() - t, 3))
    check("run: a query through the socket succeeds", r == {"success": True, "output": "id,note\n1,original"}, r)

    r = run("pg-ro", "SET default_transaction_read_only = off; create table pwn(i int);")
    check("write refused by the database for the read-only role", "permission denied" in (r.get("output") or ""), r)
    r = run("pg-ro", "begin read write; create table pwn2(i int); commit;")
    check("BEGIN READ WRITE write refused by the database", "permission denied" in (r.get("output") or ""), r)
    r = run("pg-ro", "select token from access_tokens;")
    check("a table the role was not granted is refused by the database",
          "permission denied for table access_tokens" in (r.get("output") or "")
          and "canary-denied-table-token" not in json.dumps(r), r)

    for action, extra in [("shutdown", {}), ("tunnel", {"command": "pg-ro", "operation": "down"}), ("list", {})]:
        r = call({"action": action, **extra})
        check(f"restricted: {action} refused", r.get("success") is False and r.get("code") == "action_restricted", r)
    check("restricted: status still served", call({"action": "status"}).get("success") is True)
    check("daemon still up after the refused shutdown", run("pg-ro", "select 1;").get("success") is True)

    guards()

def outsider():
    try:
        call({"action": "status"})
        check("a client outside the socket's group cannot connect", False, "connected")
    except PermissionError:
        check("a client outside the socket's group cannot connect", True)

def guards():
    for name, probe in [
        ("\\! shell escape", r"\! id; echo LEAK=$PG_APP_PASSWORD"),
        ("\\o |cmd", "\\o | cat > /tmp/pwned.txt\nselect 'written by psql';\n\\o"),
        ("\\copy ... program", r"\copy (select 1) to program 'echo COPY_PROGRAM_RAN >&2'"),
    ]:
        r = run("pg-ro", probe)
        check(f"refused: {name}", r.get("success") is False and r.get("code") == "backslash_rejected"
              and "LEAK" not in json.dumps(r) and "COPY_PROGRAM_RAN" not in json.dumps(r), r)

    r = run("pg-ro", "select 1 as ok;")
    check("password with : \\ space $ quotes @ / # % works through PGPASSFILE", r == {"success": True, "output": "ok\n1"}, r)

    # The psql terminator: a statement with no ';' would otherwise sit in psql's buffer and
    # corrupt the *next* caller's query. Both halves are checked — this reply, and the next.
    r = run("pg-ro", "select 1 as ok")
    check("unterminated statement gets its own ';' line", r == {"success": True, "output": "ok\n1"}, r)
    check("the query after an unterminated one is unaffected",
          run("pg-ro", "select 2 as ok;") == {"success": True, "output": "ok\n2"})
    # Recorded for the controller, not asserted: what psql replies to an empty statement.
    note("psql reply to 'select 1 as ok;'", json.dumps(run("pg-ro", "select 1 as ok;")))
    note("psql reply to ';' alone", json.dumps(run("pg-ro", ";")))
    check("the query after an empty statement is unaffected",
          run("pg-ro", "select 3 as ok;") == {"success": True, "output": "ok\n3"})

    t = time.time(); r = run("pg-ro", "select pg_sleep(30);"); dt = time.time() - t
    check("pg_sleep cut off by statement_timeout", dt < 5 and "statement timeout" in (r.get("output") or ""), (dt, r))

    t = time.time(); r = run("pg-ro", "SET statement_timeout = 0; select pg_sleep(30);"); dt = time.time() - t
    check("session lifts its own timeout -> daemon wall clock cuts it off", dt < 10 and r.get("code") == "timeout", (dt, r))
    check("session is restarted after the wall-clock kill",
          run("pg-ro", "select 1 as ok;") == {"success": True, "output": "ok\n1"})

    # query_limit: the database returns row_cap + 1 rows (header + 51 = 52 lines), so the surplus never crosses the pipe;
    # RowCap then trims to 50 lines and adds its note. Without the limit this query would stream 1,000,000 rows.
    t = time.time(); r = run("pg-ro", "select g from generate_series(1,1000000) g;"); dt = time.time() - t
    check("query limit caps in the database (fast) and row cap notes it",
          dt < 2 and (r.get("output") or "").endswith("[sneek] output truncated: showing first 50 of 52 lines (row_cap)"), (round(dt, 2), (r.get("output") or "")[-120:]))
    r = run("pg-ro", "select g from generate_series(1,10) g order by g desc;")
    check("query limit keeps the statement's ORDER BY", (r.get("output") or "").startswith("g\n10\n9\n"), r)
    r = run("pg-ro", "select 1; select g from generate_series(1,1000000) g;")
    out = r.get("output") or ""
    # psql quotes the offending line back in its error context, so the literal 1000000 is in
    # the reply; what must never appear is a *row* of the series (a line that is just a number).
    rows = [l for l in out.split("\n") if l.strip().isdigit()]
    check("two statements under query_limit fail in the database, nothing runs",
          r.get("success") is True and "syntax error" in out and not rows, r)
    r = run("pg-ro", "explain select 1;")
    check("non-SELECT statements pass through the query limit", r.get("success") is True and "Result" in (r.get("output") or ""), r)

    r = run("envdump", "env")
    env = r.get("output") or ""
    check("scrubbed env: own secret present, and redacted in the reply",
          "SNEEK_SECRET_OWN=[sneek: redacted secret]" in env and "canary-envdump-own" not in env, env)
    check("scrubbed env: another command's secret is NOT in the client's environment",
          "PG_RO_PASSWORD" not in env and "PG_APP_PASSWORD" not in env and "app_pw" not in env, env)
    # Blocked patterns are substring matches: a harmless query naming updated_at is still refused by the substring match
    r = run("pg-ro", "select updated_at from tickets;")
    check("blocked patterns unchanged (substring match)", r.get("success") is False and "blockedByReadonly" in (r.get("error") or ""), r)
    # cqlsh meta-commands do client-side file I/O as the daemon's uid: SOURCE would read any
    # path the child can open, /run/secrets included. The refusal happens before anything runs.
    r = run("cql-guard", "SOURCE '/run/secrets/pg_ro_password'")
    check("cqlsh SOURCE of a secret file is refused by blocked_patterns",
          r.get("success") is False and "blockedByReadonly" in (r.get("error") or "") and "r:o" not in json.dumps(r), r)
    r = run("cql-guard", "select 1 as ok;")
    check("the same command still answers an ordinary statement", r == {"success": True, "output": "select 1 as ok;"}, r)

    # pg-app never keeps a session (the probe refuses it), so this call is always a cold start:
    # psql connect + setup commands + the read-only probe over every reachable role.
    t = time.time(); r = run("pg-app", "select 1;")
    note("pg-app cold start + read-only probe (s)", round(time.time() - t, 3))
    check("prod command whose account can write is refused",
          r.get("success") is False and r.get("code") == "prod_not_readonly"
          and "role-attributes" in (r.get("error") or ""), r)

    # Session pool: with max_sessions 2 a fast query is not queued behind a slow one,
    # and each caller gets its own result. Two threads = two socket connections, as a real client does.
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
        t0 = time.time()
        slow = ex.submit(run, "pg-ro", "select 'slow' as tag from pg_sleep(1.5);")
        time.sleep(0.2)
        fast = ex.submit(run, "pg-ro", "select 'fast' as tag;")
        rf = fast.result(); tf = time.time() - t0
        rs = slow.result()
    check("pool: fast query returns before the slow one finishes", tf < 1.0 and rf == {"success": True, "output": "tag\nfast"}, (round(tf, 2), rf))
    check("pool: the slow caller gets its own result", rs == {"success": True, "output": "tag\nslow"}, rs)
    r = run("pg-ro", "select '__SNEEK_DONE__' as tag;")
    check("marker text in data does not end the reply early", r == {"success": True, "output": "tag\n__SNEEK_DONE__"}, r)
    check("session still in step afterwards", run("pg-ro", "select 1 as ok;") == {"success": True, "output": "ok\n1"})

def audit():
    """Audit log. Runs on the host, not in the client container: the log lives on the daemon's
    tmpfs and the client image has no docker. Every other probe has already run by now, so
    the log is populated."""
    raw = subprocess.run(["docker", "compose", "exec", "-T", "sneekd", "cat", "/var/lib/sneek/audit.jsonl"],
                         capture_output=True, text=True, check=True).stdout
    entries = [json.loads(l) for l in raw.splitlines() if l.strip()]
    check("audit: one entry per request, all JSON", len(entries) >= 20 and all("ts" in e and "action" in e for e in entries), len(entries))
    runs = [e for e in entries if e["action"] == "run" and e["command"] == "pg-ro"]
    check("audit: run entries carry the input and a size, never the output",
          any(e["input"].startswith("select pg_sleep(30)") for e in runs) and all("output" not in e for e in runs), runs[:2])
    check("audit: refusals carry their code", any(e["outcome"] == "refused" and e["code"] == "backslash_rejected" for e in entries)
          and any(e["outcome"] == "refused" and e["code"] == "action_restricted" for e in entries))
    # Two peers reach the socket: the member client (uid 1001, another container) and the
    # container's own healthcheck (the daemon's user, 2001). SO_PEERCRED reports the peer's
    # *primary* gid — 1001 for the client, whose membership of the socket group 2100 is a
    # supplementary group — and translates the pid into the reader's pid namespace, which
    # leaves 0 for a peer in another container. Both are the kernel's behaviour, not a gap.
    member_runs = [e for e in runs if e["peer"].get("uid") == 1001]
    health_runs = [e for e in runs if e["peer"].get("uid") != 1001]
    check("audit: the client's peer is recorded (uid 1001, primary gid 1001, pid 0 across pid namespaces)",
          member_runs and all(e["peer"].get("gid") == 1001 and e["peer"].get("pid") == 0 for e in member_runs),
          member_runs[0]["peer"] if member_runs else "no member run recorded")
    check("audit: the container's own healthcheck is a distinct peer, with a real pid (uid 2001)",
          health_runs and all(e["peer"].get("uid") == 2001 and e["peer"].get("gid") == 2001 and e["peer"].get("pid")
                              for e in health_runs),
          [e["peer"] for e in health_runs[:2]])
    check("audit: no secret in the log", "canary" not in raw and "app_pw" not in raw and "r:o" not in raw)
    check("audit: queries are ordered and timestamped", [e["ts"] for e in entries] == sorted(e["ts"] for e in entries))

if __name__ == "__main__":
    {"member": member, "outsider": outsider, "audit": audit}[sys.argv[1]]()
    sys.exit(1 if FAILED else 0)
