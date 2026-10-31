# Sneek

macOS app + CLI daemon for managing custom commands with secret resolution, SSH tunnels, and Claude Code MCP integration.

## Why This Exists

Managing connections to production infrastructure (databases, APIs, internal services) requires juggling passwords, SSH keys, tunnel configs, and connection strings. These secrets end up in plaintext config files, shell history, or environment variables.

Sneek solves this: define custom commands (like `pg-prod`) in a GUI, configure secrets (pulled from Keychain/1Password/Bitwarden at runtime — never stored), optional SSH tunnels, and expose them to Claude Code as MCP tools or to the terminal as shell scripts.

The core requirement: **give Claude Code access to prod databases without exposing secrets** (passwords, IPs, SSH tunnel options) in the conversation or config files.

## Architecture

**GUI + CLI Daemon** pattern (chosen over monolith or generated-scripts-only):
- The daemon runs without the GUI open — Claude Code can use commands even when the app isn't visible
- The GUI is just a config editor — no runtime logic
- Both share `SneekLib`

```
┌──────────────┐     ┌─────────────────────────────────────────┐     ┌──────────────┐
│  Sneek.app   │     │              sneekd                     │     │  Claude Code  │
│  (SwiftUI)   │────▶│  Tunnel Manager  │  Session Manager     │◀────│  (MCP stdio)  │
│  config only │ IPC │  Secret Resolver │  MCP Server          │     │              │
└──────────────┘     │  Script Generator│  IPC Server           │     └──────────────┘
                     └─────────────────────────────────────────┘
                              ▲                                        ┌──────────────┐
                              │ IPC                                    │   Terminal    │
                              └────────────────────────────────────────│ sneekd run   │
                                                                      └──────────────┘
```

**Why this over alternatives:**
- **Not a monolith** — daemon can run headless, MCP server doesn't need the GUI
- **Not generated scripts only** — persistent sessions need a long-running process; tunnel health monitoring needs a daemon
- **Not native DB drivers** — chose persistent CLI sessions (generic, works with any tool) over native drivers (would need per-DB Swift drivers, not generic)

## Project Structure

```
Sources/
  SneekLib/                  # Core library (shared by app and daemon)
    Models.swift             # CommandConfig, SecretRef, TunnelConfig, MCPConfig, SneekConfig
    ConfigStore.swift        # JSON config loading/saving from ~/.config/sneek/
    SecretResolver.swift     # SecretProvider protocol + Keychain/1Password/Bitwarden/Env
    TemplateEngine.swift     # {{variable}} interpolation
    TunnelManager.swift      # SSH tunnel spawn/health check/teardown (actor)
    SessionManager.swift     # Persistent subprocess sessions with sentinel parsing (actor)
    IPCProtocol.swift        # Unix domain socket IPC client/server
    MCPServer.swift          # stdio JSON-RPC MCP server for Claude Code
    ScriptGenerator.swift    # Shell script + Claude MCP config generation
    RunPipeline.swift        # Preflight shared by the daemon and MCP: resolve → render → plan → redaction set
    Daemon.swift             # Orchestrates all components, handles IPC requests
  sneekd/
    Sneekd.swift             # CLI entry point (swift-argument-parser subcommands)
  SneekApp/
    SneekApp.swift           # App entry point (menubar + window scenes)
    AppState.swift           # Observable state, config loading, daemon status
    MenuBarView.swift        # Menubar popover (search, command list, badges)
    CommandEditorView.swift  # Full command editor form
Tests/
  SneekLibTests/             # 434 checks on macOS, 424 on Linux
    TestRunner.swift         # Custom test harness (no XCTest — see note below)
    Main.swift               # Test entry point
    ModelsTests.swift        # JSON round-trip, all secret providers, edge cases
    ConfigStoreTests.swift   # Load, save, delete, reload, global config
    SecretResolverTests.swift # Real env, mock providers, merge logic
    TemplateEngineTests.swift # Substitution, missing vars, edge cases
    TunnelManagerTests.swift  # Mock tunnel lifecycle
    SessionManagerTests.swift # Oneshot, blocked patterns
    MCPServerTests.swift      # JSON-RPC protocol, tool list, filtering
    ScriptGeneratorTests.swift # Script content, permissions, install-mcp
    IntegrationTests.swift    # Real stack: keychain, sessions, read-only, MCP
docs/
  superpowers/specs/
    2026-04-02-sneek-design.md  # Full design spec
```

## Build & Test

```bash
# Xcode is NOT required — CommandLineTools alone is enough.
# Recent CLT SDKs (Swift 6.3+) include SwiftUI, and the custom test runner
# avoids XCTest (which CLT still lacks). Verified: full build + all tests
# pass with only /Library/Developer/CommandLineTools.

swift build              # Build all 3 targets (sneekd, Sneek, SneekTests)
swift run SneekTests     # Run tests (custom runner — NOT swift test)
swift run Sneek          # Launch GUI — auto-starts the daemon (one command, dev + prod)
swift run sneekd --help  # CLI help (daemon ops only — GUI handles start/stop)
```

The GUI auto-spawns `sneekd` on launch if one isn't already running. Binary lookup order: sibling to the running `Sneek` executable (covers `.build/.../sneekd` in dev and `Sneek.app/Contents/MacOS/sneekd` if bundled) → `/usr/local/bin/sneekd` → `/opt/homebrew/bin/sneekd` → `PATH`. App logs go to `~/.config/sneek/logs/sneek-app.log` (and stderr in dev) — `tail -f` to debug spawn issues. Daemon logs are separate at `~/.config/sneek/logs/sneekd.log`.

Note: in dev, `Ctrl-C`'ing `swift run Sneek` also kills the spawned daemon (shared process group). In prod, Cmd-Q does not — the daemon survives and continues serving Claude Code.

**Why not `swift test`?** The project uses a custom executable test runner (`SneekTests` target) instead of XCTest because the CommandLineTools-only Swift toolchain doesn't include XCTest or Swift Testing. The test target is an `.executableTarget` in Package.swift, not a `.testTarget`. Tests use `check()` / `test()` / `report()` from `TestRunner.swift`.

**To install binaries** (the production `sneekd` lives at `/opt/homebrew/bin/sneekd`):
```bash
swift build -c release --product sneekd && cp .build/arm64-apple-macosx/release/sneekd /opt/homebrew/bin/sneekd && codesign --force --sign - /opt/homebrew/bin/sneekd && launchctl kickstart -k gui/$(id -u)/com.sneek.daemon
```

A stale installed binary fails subtly — e.g. an old default-sentinel table makes every mongosh session hang forever while the query itself succeeds (seen 30 Jul 2026). After any `swift build -c release`, always reinstall AND kickstart; the running daemon never picks up a new binary on its own.

### Daemon lifecycle — launchd owns sneekd

The daemon is managed by LaunchAgent `com.sneek.daemon` (`~/Library/LaunchAgents/com.sneek.daemon.plist`) with `KeepAlive: true` and `RunAtLoad: true`, running `/opt/homebrew/bin/sneekd start`. It captures stdout/stderr to `~/.config/sneek/logs/sneekd.log` / `sneekd.err` and sets `PATH` explicitly (secrets CLIs and DB clients must be reachable from that PATH, not your shell's).

**Restart with `launchctl kickstart -k gui/$(id -u)/com.sneek.daemon` — never `kill` + manual `sneekd start`.** Killing the daemon makes launchd respawn it instantly, and a manually started daemon then races it: each new daemon binds the Unix socket by unlinking the previous socket file, and a dying daemon's shutdown cleanup unlinks the path even when a *newer* daemon owns it. The end state is a live daemon nobody can reach — `sneekd status` and MCP fail with `connect() failed: No such file or directory` while `pgrep sneekd` shows a running process. If you see that state, one kickstart fixes it.

## Config

All config lives in `~/.config/sneek/`:
```
~/.config/sneek/
├── config.json              # Global settings (script_output_dir, log_level)
├── commands/
│   ├── pg-prod.json         # One JSON file per command
│   └── echo-demo.json
├── sneekd.sock              # Unix socket (daemon ↔ clients)
└── logs/
    └── sneekd.log
```

## Server mode (Linux)

sneek was written for one Mac. It also runs as a hardened container daemon on a Linux
server, where the client is not Claude Code on a laptop but a service in
another container on the same host. Everything below is Linux/server-only; none of it
changes what the Mac does.

### The rule about running daemons

**Never run a dev-built daemon on this Mac.** On the Mac the only two commands are
`swift build` and `swift run SneekTests`. Never `sneekd start`, `swift run sneekd start`,
`swift run Sneek`, or any `launchctl` command: `/opt/homebrew/bin/sneekd` is a live service
and a second daemon unlinks its socket (see *Daemon lifecycle — launchd owns sneekd*).
A daemon under development runs **only in a container** — `scripts/linux/check-daemon.sh`
or `Tests/e2e/`. If one ever has to run outside a container, it runs with
`--config-dir <temp dir>` so it cannot bind over or rewrite `~/.config/sneek`.

**Signals on Linux.** `Sys.launch` resets an ignored SIGTERM/SIGINT/SIGPIPE/SIGHUP to the
default around `Process.run()` (so a child can be terminated) and restores it after. That
restore is an **index loop on purpose**: with it written as `for (sig, var previous) in
ignored`, 2 of 40 launches in one Linux test run left SIGPIPE at default until the next EPIPE
killed the process. The index form has not reproduced that, but the mechanism was never
established — treat the loop form as an unexplained correlation rather than a known compiler
or runtime defect. What is pinned is the invariant, not the theory: `PlatformTests` checks
that SIGPIPE is still ignored after each of 40 launches. Every write to a child's stdin goes
through `Sys.write`, which cannot raise a fatal SIGPIPE even inside that window
(thread mask + drain on Linux, `F_SETNOSIGPIPE` on Darwin, where a pipe's SIGPIPE is
process-wide).

`--config-dir` (or `SNEEK_CONFIG_DIR`) is also the only reliable way to place the config
dir in a container: **corelibs Foundation resolves the home directory from the passwd
entry, not from `$HOME`**, so `ENV HOME=…` alone does not move it — the image's
`useradd -d /var/lib/sneek` is what actually decides, and the entrypoint passes
`--config-dir` explicitly anyway.

### Global settings (`config.json`)

| Key | Effect | Default |
|---|---|---|
| `socket_path` | Where the daemon binds. | `<config dir>/sneekd.sock` |
| `socket_mode` | Octal mode (`"0660"`) applied to the socket file. An unparseable value refuses to bind rather than falling back to a world-accessible socket. | umask |
| `restrict_socket` | Serve only `run`, `tools`, `status`. `list`, `tunnel` and `shutdown` are refused with code `action_restricted`. | `false` |
| `scrub_child_env` | Child processes start from an allowlist only — `PATH`, `HOME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `TZ`, `TMPDIR` — plus that command's own `secret_env`/`secret_files`. | `false` |
| `reject_backslash` | Daemon-wide default for psql-type commands (a per-command `reject_backslash` always wins). | `false` |
| `require_readonly_prod` | A command tagged `prod` is refused unless a read-only probe passes at session start. | `false` |
| `audit_log` | Path to the JSON-lines audit file (`"-"` = stderr). A path that cannot be opened is a **start-up error**: a server that cannot audit does not serve. | absent (no audit) |

### Per-command settings

| Key | Effect |
|---|---|
| `tags: ["prod"]` | What `require_readonly_prod` keys off (case-insensitive). |
| `secret_env` | `{"VAR": "{{password}}"}` — rendered from resolved secrets, given only to this command's children. |
| `secret_files` | `{"PGPASSFILE": {"content": "…{{password}}", "escape": "pgpass"}}` — written `0600` into a private `0700` directory; the env var named by the key holds the file's *path*. `escape` is `pgpass` or absent. |
| `reject_backslash` | Per-command override of the global default. |
| `statement_timeout` (s) | psql: prepended `SET statement_timeout = <n*1000>;` at session start. Also exposed to the command template as `{{statement_timeout}}` / `{{statement_timeout_ms}}` for clients that take it on the command line (cqlsh's `--request-timeout=`). |
| `reply_timeout` (s) | The daemon's own wall clock per call. Defaults to `statement_timeout + 5`. This is the limit that actually holds — a session can switch a database-side timeout off. On expiry the client gets SIGINT (psql sends a server-side cancel; mongosh and cqlsh cancel the in-flight operation), SIGTERM 1 s later and SIGKILL 2 s after that, each only if it is still running. |
| `row_cap` | Lines kept from a reply; the rest is replaced with a `[sneek] output truncated: …` line. Counts **lines**, not database rows. |
| `query_limit` | Cap the result in the database at `row_cap + 1`: psql wraps a single read statement in `SELECT * FROM (…) AS sneek_q LIMIT n`, cqlsh gets `LIMIT n` appended, mongosh gets a `config.set("displayBatchSize", n)` setup command. |
| `max_sessions` | Concurrent client processes for this command. Each call takes an exclusive lease on one; further calls wait. |
| `readonly_probe` | `{"input": …, "expect": …, "reject": [...]}` — overrides the built-in probe. `reject` is checked first (`output.contains`), then `expect` must appear in some trimmed output line (substring, so a token in a cqlsh table cell counts). |

### Wire formats

One newline-terminated JSON object each way on the Unix socket.

```
→ {"action":"run","command":"pg-prod","input":"select 1"}
← {"success":true,"output":"?column?\n1"}

→ {"action":"tools"}
← {"success":true,"tools":[{"name":"sneek_pg_prod","command":"pg-prod",
                           "description":"Read-only SQL … [read-only]","readonly":true}]}

→ {"action":"status"}                     ← {"success":true,"output":"daemon: running\n…"}
```

Actions: `run`, `tools`, `status`, `list`, `tunnel`, `shutdown`. A refusal is
`{"success":false,"error":"refused: …","code":"<code>"}`; the codes a server client must
handle are `action_restricted`, `backslash_rejected`, `input_too_large` (a `run` input over
64 KiB — the pipe buffer; nothing is started), `prod_not_readonly` and
`prod_readonly_unverified`. A connection that sends more than 1 MiB without a newline gets
the plain `invalid request` failure and is closed. `tools` names are the MCP tool names
(`sneek_` + `tool_name`), with `[read-only]` appended to the description for read-only
commands.

### Two daemons, one image

mongosh is a full JavaScript/Node shell: input to a Mongo command can execute programs and
read files inside the sneekd container. A read-only database user limits what it can do to
the database; the container (read-only root, non-root, no capabilities, no internet), the
scrubbed child environment, and secret files that exist only for the owning session limit
what it can do to everything else.

On the server, Mongo commands therefore run in their own sneekd container (`sneekd-mongo`)
holding only Mongo secrets, and every daemon is non-dumpable, so a mongosh payload can read
no credential other than its own read-only user's; replies are redacted for secret values.

So the server runs **two containers from the same image**: `sneekd` (Postgres + Cassandra)
and `sneekd-mongo` (the Mongo commands), each with its own config dir, its own secrets, its
own socket volume and its own audit volume. The client reads both sockets
(`SNEEK_SOCKETS=/run/sneek/sneekd.sock,/run/sneek-mongo/sneekd.sock`); **tool names must be
unique across daemons**. A worked example with every hardening flag is in
[`docker/example/compose-snippet.yml`](docker/example/compose-snippet.yml), with the config
dirs beside it in `docker/example/sneekd/` and `docker/example/sneekd-mongo/` (placeholder
hosts and names written `REPLACE_*`, no secrets).

**What the isolation is, precisely.** Every command inside one daemon runs as the same uid
(2001), so the boundary between two commands in the same container is thin:

- `/run/secrets/*` is readable to every child for the container's lifetime, not only to the
  command that references a secret. Any client that can open a path (cqlsh `SOURCE`,
  mongosh `fs.readFileSync`) reaches every credential in its container.
- mongosh takes `--password "$VAR"` on argv, and `/proc/<pid>/cmdline` is world-readable —
  `PR_SET_DUMPABLE` covers the daemon's memory and environment, not a child's command line.
- Sibling children are dumpable: one child can `ptrace` or read `/proc/<sibling>/environ`
  of another child of the same uid. Only the daemon itself is non-dumpable.

**The container is the boundary.** One daemon per credential (per trust group) is what
makes the claim — "a mongosh payload can read no credential other than its own
read-only user's" — literally true. The entrypoint also makes the live config unwritable to
the daemon's own uid (`commands/` 0500, every JSON file 0400): a child that could rewrite a
command file would otherwise have its change picked up within the 3-second poll.
`ConfigStore` tolerates the read-only directory at start-up and, on reload, skips a
command file that does not decode (with a warning) rather than emptying the daemon.

`hidepid` is **not** a compose option — compose cannot remount `/proc` inside a container.
`hidepid=2` is host-level hardening (`mount -o remount,hidepid=2 /proc`, or
`ProtectProc=invisible` on the systemd unit that runs compose). Inside the container the
protection that holds is `PR_SET_DUMPABLE=0`, which the daemon applies to itself at start-up
(via the Linux-only `Sources/CPrctl` shim — `prctl(2)` is variadic and Swift cannot call it).

The image sets `SNEEK_LOG_STDERR=1` (every log level goes to stderr, so `docker logs` is the
log; unset on the Mac) and `SNEEK_SERVER=1`, which makes `docker/entrypoint.sh` refuse to
start unless the config it is about to hand the daemon has **both** `restrict_socket: true`
and `require_readonly_prod: true`.

### Secrets on the server

Secrets arrive as **files** in `/run/secrets` (compose `secrets:`, never `environment:`).
The entrypoint turns each file into one variable named after it — `pg_prod_password` →
`PG_PROD_PASSWORD` — which command configs reference as
`{"provider":"env","var":"PG_PROD_PASSWORD"}`. Only the count is logged, never a name or a
value.

From there a secret should reach the client through `secret_files` (psql `PGPASSFILE`,
cqlsh `CQLSH_CREDS`) so it never appears in the command text; mongosh has no password-file
option, so it uses `secret_env` plus `--password "$SNEEK_SECRET_PASSWORD"` inside double
quotes.

A `secret_files` directory lives for the **lifetime of the session**, not the call: a
rotated secret takes effect at the next session start (after an idle reap or a config
change), not immediately. `sneek-secrets-*` directories under `/tmp` can only be orphaned by
a `SIGKILL` of the daemon, and the container's `/tmp` is a tmpfs that is wiped on restart.

Replies are scanned for every resolved secret value 8 characters or longer and those are
replaced with `[sneek: redacted secret]`, so a client that prints its own credential back
(`print(process.env.X)`, an error quoting a connection string) does not leak it through the
socket or into the audit log. The set scanned for is the union of **every enabled command's**
secrets resolved since boot (`SecretCache`), not the calling command's alone: the commands
in one daemon share a uid, so a client under B can be made to print A's credential. A
command whose secrets have never been resolved (never called, and not warmed at boot by the
prod check) is not yet in the set — one more reason to keep one daemon per credential.

### Audit log

One JSON object per IPC request, appended as a line. Fields (alphabetical in the file —
the encoder uses `.sortedKeys`):

```json
{"action":"run","code":"backslash_rejected","command":"pg-prod","duration_ms":3,
 "error":"refused: input contains a backslash, …","input":"\\! id",
 "outcome":"refused","peer":{"gid":1001,"pid":0,"uid":1001},
 "output_lines":null,"output_sha256":null,"ts":"2026-09-21T10:15:02.123Z"}
```

`outcome` is `ok`, `refused` (a policy refusal, with `code`) or `error`. The reply text is
never stored — only `output_lines` and `output_sha256`, so two replies can be compared
without the log becoming a copy of the database. `input` is recorded for `run` only, with
secret values redacted; `error` is redacted and truncated to 200 characters.

Reading it:

```bash
jq -c 'select(.outcome != "ok")' audit.jsonl                 # every refusal and error
jq -c 'select(.command == "pg-prod") | {ts, input}' audit.jsonl   # every query against prod
```

Operational facts:

- `peer` carries the connecting process's **primary** gid — not the socket group it used to
  get in — and `pid: 0` for a client in another pid namespace (i.e. any other container).
  **Identify callers by `uid`.**
- The file is opened `O_APPEND` and forced to `0600` (an existing wider file is narrowed on
  open). Rotate it on the host with `logrotate` + **`copytruncate`**, because the daemon
  holds the descriptor open; it is not rotated by sneek.
- `0600` protects only against **other uids**. The daemon's children run as the same uid,
  so a mongosh payload could open the file and append to or truncate it. The stronger
  options: `audit_log: "-"` (stderr → the docker json-file log; children cannot reach the
  daemon's fd 2) or `chattr +a` on the host file (append-only, which breaks `copytruncate`
  rotation — use `create` mode with a new file name instead).
- A path that cannot be opened at start-up is fatal. A write error **after** start-up (a full
  volume) is logged as one `WARN` in the daemon log and then swallowed — later lines are
  lost silently. Monitor free space on the audit volume.
- On the server the log lives on a named volume mounted at `/var/lib/sneek-audit`, which
  the image creates owned by uid 2001, so a fresh named volume inherits that ownership and
  no manual chown is needed.

### Read-only enforcement on prod

With `require_readonly_prod: true`, a command tagged `prod` must be `mode: "session"` and
must have a probe — its own `readonly_probe` or the built-in one for psql/mongosh — or it is
refused with `prod_readonly_unverified`. The probe runs at every session start; nothing is
cached, so a grant change is caught at the next session.

The Postgres probe is catalog-only (no writes). It evaluates every role the account can
`SET ROLE` to, not just `current_user`, because a NOINHERIT member of a writer role can
become one at will, and it checks column-level grants as well as table grants. Cost: ~2–3 ms
on a small catalog, O(tables × reachable roles) — measure it before pointing it at a large
catalog. Caveats:

- On PostgreSQL ≤ 14 the default `CREATE ON SCHEMA public TO PUBLIC` makes **every** role
  fail `schema-create`; revoke it (`REVOKE CREATE ON SCHEMA public FROM PUBLIC`) or the
  probe refuses every prod command.
- Sequences are not checked.
- Writes the role makes *through* a `SECURITY DEFINER` function it may `EXECUTE` are not
  detected: the function writes with its owner's privileges and the probe asks only about
  the role's own grants. Nor is membership of `pg_read_server_files` (a filesystem read,
  not a database write). Review function grants and predefined-role membership by hand.
- A refused prod command re-runs connect + probe on every call (~40 ms). There is no
  negative cache yet.

Cassandra has no built-in probe: `docker/example/sneekd/commands/cass-prod.json` carries a
hand-filled `readonly_probe` with a `LIST ALL PERMISSIONS OF <role>` placeholder,
`expect: "SELECT"` and `reject: ["MODIFY","ALTER","DROP","CREATE","AUTHORIZE"]`. Replace the
role name (it appears twice: credentials and probe); if that role may not list its own
permissions, ask the Cassandra admin for a probe statement that fails for a writer and
succeeds for a reader.

**DBA-side backstops.** A killed client does not always mean a cancelled query: if the
cancel is lost, the server keeps running it until it notices the dead connection. Two
settings on the Postgres side bound that: `ALTER ROLE <ro> CONNECTION LIMIT n` (with `n` at
or just above the sum of `max_sessions` for that role, so a run of restarted sessions cannot
pile up) and `client_connection_check_interval = 10s` (PostgreSQL 14+, so a long query whose
client is gone is aborted within 10 s instead of running to completion).

**Dev databases may connect as an ordinary user**; then the read-only setup command and the
blocked patterns are the only barrier to a write, and neither is a guarantee. Say so
per database in the deployment notes.

### Client behaviour worth knowing

- **psql** — every psql-type input gets `\n;` appended (backslash commands and empty input
  excluded), on a line of its own so a trailing `--` comment cannot swallow it, and
  **unconditionally**: there is no "already terminated" check, because telling a real `;`
  from one in a comment or a string needs a parser, and the surplus `;` is an empty
  statement for which psql under `--csv --quiet -X` prints nothing (verified in the E2E).
  Without it psql keeps the statement in its buffer, the sentinel still runs, the reply
  comes back empty and the *next* query fails on the leftover text.
  `reject_backslash` exists because `\!`, `\o |cmd` and `\copy … program` all run shell
  commands and all need a backslash.
- **mongosh** — there is no `timeoutMS`-style flag, so **the daemon wall clock
  (`reply_timeout`) is the Mongo limit**. `displayBatchSize` caps only bare cursor printing;
  `.toArray()` / `.forEach()` / `.map()` fall back to `row_cap`. Patching `Cursor.prototype`
  could not be verified — those classes are `undefined` without a live server. Use `--quiet`,
  or mongosh's banner prefixes every reply.
- **cqlsh** — takes its timeout on the command line (`--request-timeout={{statement_timeout}}`)
  and its credentials from a `--credentials` file (`CQLSH_CREDS` via `secret_files`). Its
  meta-commands `SOURCE`, `COPY`, `CAPTURE` and `LOGIN` do **client-side file I/O** as the
  daemon's uid (`SOURCE '/run/secrets/x'` reads a secret; `CAPTURE` writes a file), so
  `cass-prod.json` lists them in `blocked_patterns`. Like every blocked pattern they are
  substring-matched, case-insensitively: a column called `login_count` is refused too.

### Tests

| Command | What it does |
|---|---|
| `swift build && swift run SneekTests` | The Mac suite. **453 checks.** |
| `RUNS=5 scripts/linux/test.sh` | Builds and runs the same suite in the pinned Linux Swift image, `RUNS` times. **443 checks** (the Mac count minus the macOS-only branches, plus the Linux-only ones). Never run two at once — they share the `sneek-linux-build` volume. |
| `scripts/linux/check-daemon.sh` | Runs a real daemon in a container: config reload, SIGTERM, dead-session recovery, `PR_SET_DUMPABLE`, the two-daemon secret split, and that the image refuses a server config missing `require_readonly_prod`. Needs `docker build -f docker/Dockerfile -t sneekd:dev .` first. |
| `Tests/e2e/run.sh` | The full socket contract against a throwaway Postgres in compose (`sneek-e2e`): socket group gating, every guard, the read-only live config, the cqlsh meta-command refusal, the audit log, the healthcheck. **47 PASS lines.** |

### Deployment

`docker/healthcheck.sh` runs one query per database from `/etc/sneek/health.tsv`
(`<command name><TAB><query>`) through the daemon's own socket, so it proves secrets,
client, network and login together. Terminate each query the way the client expects — a
session is persistent, and an unterminated statement corrupts the next caller's query.

Three things that look like problems and are not:

- `docker compose config` fails on the example until the `image:` digest placeholder is
  filled in.
- The entrypoint's `restrict_socket` / `require_readonly_prod` check is a **line** grep:
  keep each key and its value on one line of `config.json`.
- Until the Cassandra probe in `cass-prod.json` is configured, the `sneekd` container
  reports **unhealthy**: `health.tsv` runs `cass-prod`, and the prod read-only check refuses
  it. That is the placeholder, not the VPN.

### Upgrading an existing install

Two things in an already-installed config are fixed by the server work but need the operator
to act; neither happens on its own.

- **A command that passes a password in its command text** (an older `cass-prod` with
  `cqlsh -u … -p {{password}}`) leaks it to anything that can read the process table in that
  container, and to `sneekd status`. Move it to `--credentials` plus a `secret_files` entry,
  as `docker/example/sneekd/commands/cass-prod.json` shows: the file is written `0600` in a
  private `0700` dir and the env var holds its *path*. The same applies to `mongosh`, which
  has no password-file option — there the value lives in `secret_env` and is referenced as
  `--password "$SNEEK_SECRET_PASSWORD"`, quoted.
- **The psql terminator is in the binary, not the config.** An install running an older
  `sneekd` still corrupts a session on an input without a trailing `;` (empty reply with
  `success: true`, then a syntax error on the *next* query). Rebuilding and reinstalling the
  daemon is the fix; no config key turns it on.

### Local branch workflow

The three server branches — `server/linux-port` → `server/bridge-support` → `server/guards`
— are **never pushed**; push is disabled and there are no PRs, issues or remote tags. To
take upstream changes:

```bash
git fetch origin                                   # fetch works; push is DISABLED
git checkout main && git merge --ff-only origin/main
git tag pre-rebase-$(date +%Y%m%d) server/guards   # recovery point
git checkout server/guards
git rebase --update-refs main                      # moves all three branch refs at once
swift build && swift run SneekTests && RUNS=3 scripts/linux/test.sh && Tests/e2e/run.sh
```

Conflicts concentrate in `IPCProtocol.swift`, `SessionManager.swift`, `Daemon.swift` and
`Sneekd.swift`; most new logic lives in new files (`Platform`, `ToolCatalog`, `Guards`,
`LaunchPlanner`, `ReadonlyProbe`, `AuditLog`, `RunPipeline`, `CPrctl`) precisely to keep that small. If a
rebase becomes unmanageable, merge `origin/main` into each branch bottom-up instead — it
costs the clean series but never loses work. Image tags (`server-YYYYMMDD`) are local only.

## Key Design Decisions

### Secrets are never stored
Config holds only provider references. Resolved at runtime by the daemon.
```json
"secrets": { "password": { "provider": "keychain", "key": "db-prod" } }
```
Supported providers: macOS Keychain (`find-generic-password`, falls back to `find-internet-password`), 1Password (`op read`), Bitwarden (`bw get password`), environment variables.

### Persistent sessions over native drivers
Commands with `mode: "session"` keep a subprocess alive (like an open psql connection). A **sentinel command** marks end-of-output — the daemon sends the sentinel after each user input and reads stdout until `__SNEEK_DONE__` appears.

**Critical implementation detail:** The sentinel detection matches the *output* of the sentinel command (`__SNEEK_DONE__`), not the command itself (`echo __SNEEK_DONE__`). This was a bug that was caught and fixed during integration testing.

Default sentinels per known type:
- Postgres: `\echo __SNEEK_DONE__`
- MySQL: `SELECT '__SNEEK_DONE__';`
- Redis: `ECHO __SNEEK_DONE__`
- Generic/bash: `echo __SNEEK_DONE__`

Custom sentinel via the `sentinel` field in command config.

### Read-only mode — two layers
1. **Setup commands** — run at session start (e.g., `SET default_transaction_read_only = on;`). The database itself enforces read-only.
2. **Blocked patterns** — daemon rejects input containing patterns (DROP, DELETE, etc.) *before* it reaches the session. Case-insensitive. Safety net, not a guarantee.

### One MCP server for all commands
`sneekd mcp-serve` is a single stdio JSON-RPC process. Claude's config points to it once. All MCP-enabled commands appear as tools. Per-project scoping via `--tags` or `--commands` flags.

### GUI is a config editor only
The SwiftUI app (menubar + detachable window) reads/writes JSON config files. It does not run commands, manage tunnels, or serve MCP. All runtime is in the daemon. The app auto-spawns the daemon on launch (see Build & Test for the binary lookup order) and exposes a start/stop toggle in the menubar; the daemon survives the app quitting in prod.

The app shows in the Dock (`NSApplication.shared.setActivationPolicy(.regular)`) and activates properly when "Open Window" is clicked (`NSApplication.shared.activate(ignoringOtherApps: true)`).

### AppState is the shared source of truth for both GUI views
`SneekApp` owns a single `@StateObject AppState`, passed via `.environmentObject` to both `MenuBarView` (menubar popover) and `CommandEditorView` (main window). Both views read `appState.filteredCommands` — there is no second AppState instance. If a GUI bug shows different data in the two views, the cause is rendering/layout, not state divergence.

AppState is a **snapshot cache**, not live state: `loadConfig()` runs only on app-activation events (`MenuBarView.onAppear`, window `didBecomeActiveNotification`). It constructs a fresh `ConfigStore` each call and does not wire up `onChange` or call `startWatching()`. External JSON edits won't appear in the GUI until the app is re-activated. The daemon keeps its own watched `ConfigStore` — a separate cache.

## What Works

- Config CRUD (create, save, delete, reload with file watching)
- Secret resolution from real macOS Keychain (tested in integration tests)
- Template interpolation with `{{variable}}` syntax
- Persistent sessions with sentinel-based output parsing
- Setup commands at session start
- Read-only enforcement (blocked patterns + setup commands)
- SSH tunnel spawn, health check (TCP connect), teardown
- MCP stdio server (initialize, tools/list, tools/call)
- Per-project MCP scoping (tags, command names)
- Shell script generation with correct permissions
- Claude Code config installation (`install-mcp`)
- Full CLI with all subcommands
- GUI with menubar popover + detachable editor window

## Backlog

See [`TODO.md`](TODO.md).

## Testing

434 checks, 0 failures on macOS (`swift run SneekTests`); 424 on Linux
(`scripts/linux/test.sh`); 47 end-to-end checks (`Tests/e2e/run.sh`). See
*Server mode (Linux) → Tests* for what each suite covers.

**Unit tests** (no external dependencies):
- Models: JSON round-trip, all 4 secret providers, unknown provider throws, minimal config
- ConfigStore: load, save, delete, reload, global config
- TemplateEngine: substitution, multiple vars, missing var throws, edge cases
- MCP: JSON-RPC protocol, tool list filtering (enabled/disabled/tags/commands)
- ScriptGenerator: content, permissions, install-mcp create/preserve

**Integration tests** (real stack, no mocks):
- **Real Keychain**: stores a password via `security add-generic-password`, resolves via `KeychainProvider`, cleans up
- **Persistent bash session**: sends multiple commands to a live bash process, verifies output, confirms session reuse
- **Setup commands**: sets env vars at session start, verifies they persist for subsequent commands
- **Read-only enforcement**: 6 dangerous SQL patterns blocked (DROP, DELETE, UPDATE, INSERT, ALTER, TRUNCATE), 5 safe queries allowed (SELECT, SHOW, EXPLAIN, \dt)
- **Full pipeline**: Keychain secret → SecretResolver → TemplateEngine → SessionManager → output verified
- **SSH tunnel**: localhost port forward, TCP health check, teardown (skipped if Remote Login disabled)
- **MCP tools/call**: real command execution via JSON-RPC handleMessage
- **Script generation**: verifies shebang, exec delegation, 755 permissions
- **Daemon handler**: full resolve → render → execute pipeline

All integration tests have a 10-second timeout to prevent hangs. Cleanup uses 3-second timeouts.

## CLI Reference

```
sneekd start                              # Start daemon (foreground, blocks)
sneekd stop                               # Stop daemon via IPC
sneekd status                             # Show daemon/tunnel/session status

sneekd run <name> [input]                 # Execute a command
sneekd tunnel <name> up|down|status       # Manage tunnels

sneekd list                               # List all configured commands
sneekd mcp-serve [--tags x] [--commands y] # Run as MCP stdio server
sneekd generate-scripts [--output-dir p]  # Generate shell wrapper scripts
sneekd install-mcp                        # Add sneek to Claude MCP config
```

## MCP Integration

One-time setup via CLI:
```bash
claude mcp add sneek -- sneekd mcp-serve
```

Or programmatically: `sneekd install-mcp` adds to `~/.claude/settings.json`:
```json
{ "mcpServers": { "sneek": { "command": "sneekd", "args": ["mcp-serve"] } } }
```

Per-project override in `.claude/settings.json`:
```json
{ "mcpServers": { "sneek": { "command": "sneekd", "args": ["mcp-serve", "--tags", "prod"] } } }
```

Each MCP-enabled command becomes a tool named `sneek_<tool_name>` with a single `input` string parameter. Read-only commands get `[read-only]` appended to the description.

## Command Config Schema

```json
{
  "name": "pg-prod",
  "description": "Production Postgres via bastion",
  "tags": ["prod", "database"],
  "mode": "session",
  "idle_timeout": 300,
  "readonly": true,
  "command": "psql --csv --quiet postgresql://{{user}}:{{password}}@localhost:{{local_port}}/{{database}}",
  "secrets": {
    "password": { "provider": "keychain", "key": "db-prod" }
  },
  "variables": {
    "user": "app",
    "database": "myapp_prod"
  },
  "tunnel": {
    "host": "bastion.example.com",
    "user": "deploy",
    "identity_key": "~/.ssh/prod_key",
    "local_port": 15432,
    "remote_host": "prod-db.internal",
    "remote_port": 5432,
    "auto_connect": false
  },
  "setup_commands": ["SET default_transaction_read_only = on;"],
  "blocked_patterns": ["DROP", "DELETE", "UPDATE", "INSERT", "ALTER", "TRUNCATE"],
  "sentinel": "\\echo __SNEEK_DONE__",
  "mcp": {
    "enabled": true,
    "tool_name": "pg_prod",
    "tool_description": "Run SQL against production Postgres"
  }
}
```

## Concurrency Model

Swift 6 strict concurrency. Key actors:
- `SessionManager` — actor. Routes by command name; each `SessionPool` owns its own processes,
  its waiters and its one idle timer (`WeakRef` wrapper, to avoid `self` capture issues in
  `DispatchSource` closures). Four rules in that lifecycle are easy to undo by accident, and
  `SessionLifecycleTests` pins each one:
  - **A `LiveSession` carries a back-reference to its pool**, and release and discard follow it
    rather than looking the name up again — a `reap` may have replaced the pool underneath, and
    a late release must not wake the replacement's waiters. Resolve the pool *before* calling
    `terminate`, which clears that reference: a session left in `busy` because its pool could
    not be found holds a slot for ever.
  - **`terminate` is idempotent** (`state == .gone`). A reap and the failing call that held the
    lease both let the same process go.
  - **Kills are addressed to the child's process group**, which Foundation already creates
    (`pgid == pid`; no `setpgid` needed), and the SIGINT → SIGTERM → SIGKILL escalation tests the
    *group*, not the direct child. A command that does not `exec` leaves bash as the child with
    the real work in a grandchild, and it is the grandchild that holds the stdout pipe — and so
    the reader thread — open. bash also ignores SIGINT in a background job, so the child can
    outlive the first signal while the grandchild outlives all of them.
  - **A reply's wall clock is a cancellable `DispatchSourceTimer`**, disarmed on every exit path.
    `reply_timeout: 600` with an answered query a second otherwise left ten minutes of live
    closures on a global queue.
  - An emptied pool is removed, and an idle re-arm runs for the time *remaining*, not another
    full `idle_timeout` (which let a session live for nearly twice it).
- `SSHTunnelManager` — actor. Owns all SSH tunnel processes. Protocol methods are `async` (required by Swift 6 — actor-isolated methods can't satisfy sync protocol requirements).
- `ConfigStore` — `@unchecked Sendable` class (immutable after init in practice, but has mutable `commands` dict for reload).
- `MCPServer` — `@unchecked Sendable` class (all stored properties are set once in init).
- `SecretResolver` — `@unchecked Sendable` class (all stored properties are `let`).
- All model structs and enums conform to `Sendable`.

## Spec

Full design spec: `docs/superpowers/specs/2026-04-02-sneek-design.md`
