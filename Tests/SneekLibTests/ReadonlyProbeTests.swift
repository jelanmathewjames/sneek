import Foundation
@testable import SneekLib

func runReadonlyProbeTests() {
    print("\nRead-only prod check:")
    let on = SneekConfig(requireReadonlyProd: true)
    func cfg(_ command: String, tags: [String]?, mode: ExecutionMode = .session, probe: ReadonlyProbe? = nil) -> CommandConfig {
        CommandConfig(name: "c", description: "d", tags: tags, mode: mode, command: command, readonlyProbe: probe)
    }

    test("required only when the setting is on and the command is tagged prod") {
        check(ReadonlyCheck.required(cfg("psql x", tags: ["Prod"]), global: on))
        check(!ReadonlyCheck.required(cfg("psql x", tags: ["dev"]), global: on))
        check(!ReadonlyCheck.required(cfg("psql x", tags: ["prod"]), global: SneekConfig()), "OFF by default")
    }

    test("built-in probes exist for psql and mongosh, not for cqlsh") {
        check(ReadonlyCheck.builtinProbe(for: cfg("psql x", tags: nil))?.expect == "SNEEK_RO_OK")
        check(ReadonlyCheck.builtinProbe(for: cfg("mongosh x", tags: nil))?.expect == "SNEEK_RO_OK")
        check(ReadonlyCheck.builtinProbe(for: cfg("cqlsh x", tags: nil)) == nil)
        check(!(ReadonlyCheck.builtinProbe(for: cfg("psql x", tags: nil))!.input.contains("\n")), "one line: the session protocol is line-based")
        check(!(ReadonlyCheck.builtinProbe(for: cfg("mongosh x", tags: nil))!.input.contains("\n")), "one line: the session protocol is line-based")
    }

    // The SQL and the JS cannot be executed here — no database may be contacted — so these pin the
    // fragments the privilege reasoning rests on. The E2E suite runs the Postgres probe for real.
    test("the postgres probe covers column grants and every role the account can SET ROLE to") {
        let sql = ReadonlyCheck.builtinProbe(for: cfg("psql x", tags: nil))!.input
        check(sql.contains("has_any_column_privilege(r.oid, c.oid, 'INSERT')"), "column-level INSERT grant")
        check(sql.contains("has_any_column_privilege(r.oid, c.oid, 'UPDATE')"), "column-level UPDATE grant")
        check(sql.contains("pg_has_role(current_user, r.oid, 'MEMBER')"), "the SET ROLE reachable role set")
        // Every check evaluated over that role set, not for current_user alone.
        check(sql.contains("has_table_privilege(r.oid, c.oid, 'INSERT')"), "table privileges per role")
        check(sql.contains("has_database_privilege(r.oid, current_database(), 'CREATE')"), "database CREATE per role")
        check(sql.contains("has_schema_privilege(r.oid, n.oid, 'CREATE')"), "schema CREATE per role")
        check(sql.contains("r.rolsuper or r.rolcreatedb or r.rolcreaterole or r.rolreplication or r.rolbypassrls"),
              "role attributes per role")
        check(sql.contains("'SNEEK_RO_FAIL:table-write'"), "the E2E expects the table-write token")
        check(!sql.contains("\n"), "still one line")
    }

    test("the mongo probe rejects privilege escalation, not just data writes") {
        let js = ReadonlyCheck.builtinProbe(for: cfg("mongosh x", tags: nil))!.input
        for action in ["grantRole", "createUser", "createRole", "changePassword", "revokeRole",
                       "dropUser", "dropRole", "collMod", "convertToCapped", "setParameter",
                       "applyOps", "bypassWriteBlockingMode", "internal"] {
            check(js.contains("'\(action)'"), "missing write action \(action)")
        }
        check(!js.contains("\n"), "still one line")
    }

    test("evaluate: expect found in a line passes, everything else refuses") {
        let p = ReadonlyProbe(input: "q", expect: "SNEEK_RO_OK")
        check(ReadonlyCheck.evaluate(output: "case\nSNEEK_RO_OK", probe: p) == nil)
        check(ReadonlyCheck.evaluate(output: " SNEEK_RO_OK \n(1 row)", probe: p) == nil)
        // cqlsh prints a table: the expected token sits in a cell, never on a line of its own.
        let table = ReadonlyProbe(input: "LIST ALL PERMISSIONS OF ro;", expect: "SELECT", reject: ["MODIFY"])
        check(ReadonlyCheck.evaluate(output: " role | username | resource | permission\n------+----------+----------+------------\n   ro |       ro | <all keyspaces> |     SELECT \n\n(1 rows)", probe: table) == nil,
              "expect is a substring of a trimmed line")
        check(ReadonlyCheck.evaluate(output: "the built-in FAIL token never contains the OK token\nSNEEK_RO_FAIL:table-write", probe: p)?.code == "prod_not_readonly")
        check(ReadonlyCheck.evaluate(output: "case\nSNEEK_RO_FAIL:table-write", probe: p)?.code == "prod_not_readonly")
        check(ReadonlyCheck.evaluate(output: "case\nSNEEK_RO_FAIL:table-write", probe: p)?.message.contains("SNEEK_RO_FAIL:table-write") == true)
        check(ReadonlyCheck.evaluate(output: "ERROR:  role \"pg_write_all_data\" does not exist", probe: p)?.code == "prod_readonly_unverified")
        check(ReadonlyCheck.evaluate(output: "", probe: p)?.code == "prod_readonly_unverified")
    }

    test("evaluate: a reject pattern wins over a matching expect") {
        // A Cassandra permission listing contains SELECT (expected) *and* MODIFY for a read-write role.
        let p = ReadonlyProbe(input: "LIST ALL PERMISSIONS;", expect: "SELECT", reject: ["MODIFY"])
        let both = ReadonlyCheck.evaluate(output: "role | permission\napp | SELECT\napp | MODIFY", probe: p)
        check(both?.code == "prod_not_readonly", both?.code ?? "nil")
        check(both?.message == "its database account can write (probe output contains 'MODIFY')", both?.message ?? "nil")
        check(ReadonlyCheck.evaluate(output: "role | permission\nSELECT", probe: p) == nil, "SELECT alone passes")
    }

    test("plan: prod without a usable probe is refused; with one, the probe is attached") {
        let env: [String: String] = [:]
        let c = cfg("cqlsh h", tags: ["prod"])
        do { _ = try LaunchPlanner.plan(config: c, global: on, resolved: [:], daemonEnvironment: env); check(false, "must throw") }
        catch let r as Refusal { check(r.code == "prod_readonly_unverified" && r.message.contains("no readonly_probe defined")) }
        let one = cfg("psql x", tags: ["prod"], mode: .oneshot)
        do { _ = try LaunchPlanner.plan(config: one, global: on, resolved: [:], daemonEnvironment: env); check(false, "must throw") }
        catch let r as Refusal { check(r.code == "prod_readonly_unverified" && r.message.contains("session mode")) }
        let custom = ReadonlyProbe(input: "LIST ALL;", expect: "ok")
        check(try LaunchPlanner.plan(config: cfg("cqlsh h", tags: ["prod"], probe: custom), global: on, resolved: [:], daemonEnvironment: env).probe == custom)
        check(try LaunchPlanner.plan(config: cfg("psql x", tags: ["prod"]), global: SneekConfig(), resolved: [:], daemonEnvironment: env).probe == nil)
    }

    test("the refusal conjunction follows the code, so a code always reads the same way") {
        check(SessionManager.refusal(code: "prod_not_readonly", name: "pg-prod",
                                     detail: "its database account can write (SNEEK_RO_FAIL:table-write)").message
              == "command 'pg-prod' is tagged prod but its database account can write (SNEEK_RO_FAIL:table-write)")
        check(SessionManager.refusal(code: "prod_readonly_unverified", name: "cass-prod",
                                     detail: "its read-only check could not run: unexpected probe output").message
              == "command 'cass-prod' is tagged prod and its read-only check could not run: unexpected probe output",
              "same conjunction as LaunchPlanner uses for this code")
    }

    test("session start: a failing probe refuses and leaves no session") {
        let failing = LaunchContext(probe: ReadonlyProbe(input: "echo SNEEK_RO_FAIL:table-write", expect: "SNEEK_RO_OK"))
        let passing = LaunchContext(probe: ReadonlyProbe(input: "echo SNEEK_RO_OK", expect: "SNEEK_RO_OK"))
        let bashCfg = CommandConfig(name: "rp", description: "t", mode: .session, command: "exec bash --norc --noprofile", sentinel: "echo __SNEEK_DONE__")
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var code: String?; nonisolated(unsafe) var active: [String] = ["?"]; nonisolated(unsafe) var ok: String?
        Task {
            let m = SessionManager()
            do { _ = try await m.send(input: "echo hi", to: "rp", config: bashCfg, resolvedCommand: bashCfg.command, launch: failing) }
            catch let e as SessionError { if case .readonlyCheckFailed(let r) = e { code = r.code } } catch {}
            active = await m.activeSessions()
            ok = try? await m.send(input: "echo hi", to: "rp", config: bashCfg, resolvedCommand: bashCfg.command, launch: passing)
            await m.reapAll(); sem.signal()
        }
        check(sem.wait(timeout: .now() + 15) == .success, "timed out")
        check(code == "prod_not_readonly" && active.isEmpty && ok == "hi", "code=\(code ?? "nil") active=\(active) ok=\(ok ?? "nil")")
    }

    test("daemon: the wire format for both refusal codes") {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sneek-ro-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try ConfigStore(baseDir: tempDir)
        try store.saveGlobalConfig(SneekConfig(requireReadonlyProd: true))
        try store.save(CommandConfig(name: "cass-prod", description: "t", tags: ["prod"], mode: .session,
                                     command: "cqlsh host"))
        try store.save(CommandConfig(name: "pg-prod", description: "t", tags: ["prod"], mode: .session,
                                     command: "exec bash --norc --noprofile", sentinel: "echo __SNEEK_DONE__",
                                     readonlyProbe: ReadonlyProbe(input: "echo SNEEK_RO_FAIL:table-write", expect: "SNEEK_RO_OK")))

        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var cass: IPCResponse?
        nonisolated(unsafe) var pg: IPCResponse?
        Task {
            let m = SessionManager()
            cass = await Daemon.runCommand(name: "cass-prod", input: "select 1", configStore: store,
                                           sessionManager: m, tunnelManager: SSHTunnelManager())
            pg = await Daemon.runCommand(name: "pg-prod", input: "echo hi", configStore: store,
                                         sessionManager: m, tunnelManager: SSHTunnelManager())
            await m.reapAll(); sem.signal()
        }
        check(sem.wait(timeout: .now() + 20) == .success, "timed out")
        check(cass?.code == "prod_readonly_unverified", cass?.code ?? "nil")
        check(cass?.error == "refused: command 'cass-prod' is tagged prod and its read-only check could not run: no readonly_probe defined",
              cass?.error ?? "nil")
        check(pg?.code == "prod_not_readonly", pg?.code ?? "nil")
        check(pg?.error == "refused: command 'pg-prod' is tagged prod but its database account can write (SNEEK_RO_FAIL:table-write)",
              pg?.error ?? "nil")
    }
}
