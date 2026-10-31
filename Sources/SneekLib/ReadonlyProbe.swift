import Foundation

/// Verifies that the database account behind a prod command cannot write.
/// Spike check 11: a session-level read-only setting can be switched off by the session itself;
/// only the account's privileges are a real barrier.
///
/// Not detected by the Postgres probe: a write done *for* the role by a `SECURITY DEFINER`
/// function it may `EXECUTE` (the function writes with its owner's privileges, and the probe
/// asks about the role's own table grants), and membership of `pg_read_server_files` (a read
/// of the server's filesystem, not a write, but not what a read-only *database* role should
/// have either). Review function grants and predefined-role membership by hand.
public enum ReadonlyCheck {
    static func isProd(_ config: CommandConfig) -> Bool {
        (config.tags ?? []).contains { $0.lowercased() == "prod" }
    }

    static func required(_ config: CommandConfig, global: SneekConfig) -> Bool {
        global.requireReadonlyProd == true && isProd(config)
    }

    /// Catalog questions only — nothing is written. Postgres 14+ (pg_write_all_data).
    ///
    /// Every check is evaluated for *any role the account can SET ROLE to*, not for `current_user`
    /// alone: a NOINHERIT member of a writer or a superuser role holds no privilege directly but can
    /// become one at will. `pg_has_role(current_user, r.oid, 'MEMBER')` is that role set, and it
    /// covers `current_user` itself, since a role is a MEMBER of itself.
    ///
    /// Column-level grants are checked as well (`has_any_column_privilege`): `GRANT UPDATE (note)
    /// ON tickets` is a write that `has_table_privilege` does not report.
    private static let postgres = """
        select case \
        when exists (select 1 from pg_roles r where pg_has_role(current_user, r.oid, 'MEMBER') and (r.rolsuper or r.rolcreatedb or r.rolcreaterole or r.rolreplication or r.rolbypassrls)) then 'SNEEK_RO_FAIL:role-attributes' \
        when pg_has_role(current_user, 'pg_write_all_data', 'MEMBER') or pg_has_role(current_user, 'pg_write_server_files', 'MEMBER') or pg_has_role(current_user, 'pg_execute_server_program', 'MEMBER') then 'SNEEK_RO_FAIL:predefined-write-role' \
        when exists (select 1 from pg_roles r where pg_has_role(current_user, r.oid, 'MEMBER') and has_database_privilege(r.oid, current_database(), 'CREATE')) then 'SNEEK_RO_FAIL:database-create' \
        when exists (select 1 from pg_namespace n cross join pg_roles r where pg_has_role(current_user, r.oid, 'MEMBER') and n.nspname !~ '^pg_' and n.nspname <> 'information_schema' and has_schema_privilege(r.oid, n.oid, 'CREATE')) then 'SNEEK_RO_FAIL:schema-create' \
        when exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace cross join pg_roles r where pg_has_role(current_user, r.oid, 'MEMBER') and c.relkind in ('r','p','v','m','f') and n.nspname !~ '^pg_' and n.nspname <> 'information_schema' and (has_table_privilege(r.oid, c.oid, 'INSERT') or has_table_privilege(r.oid, c.oid, 'UPDATE') or has_table_privilege(r.oid, c.oid, 'DELETE') or has_table_privilege(r.oid, c.oid, 'TRUNCATE') or has_any_column_privilege(r.oid, c.oid, 'INSERT') or has_any_column_privilege(r.oid, c.oid, 'UPDATE'))) then 'SNEEK_RO_FAIL:table-write' \
        else 'SNEEK_RO_OK' end;
        """

    /// An unauthenticated connection has no privileges listed and must not pass. The action list
    /// covers data writes, structural changes and privilege escalation alike: a `userAdmin` can
    /// grant itself any write, so it is not a read-only account either.
    private static let mongo = """
        (function(){const w=['insert','update','remove','createCollection','createIndex','dropCollection','dropDatabase','dropIndex','renameCollectionSameDB','anyAction',\
        'grantRole','createUser','createRole','changePassword','revokeRole','dropUser','dropRole','collMod','convertToCapped','setParameter','applyOps','bypassWriteBlockingMode','internal'];\
        const a=db.runCommand({connectionStatus:1,showPrivileges:true}).authInfo;\
        if(!a.authenticatedUsers.length){print('SNEEK_RO_FAIL:not-authenticated');return}\
        print(a.authenticatedUserPrivileges.some(p=>p.actions.some(x=>w.includes(x)))?'SNEEK_RO_FAIL:write-privilege':'SNEEK_RO_OK')})()
        """

    static func builtinProbe(for config: CommandConfig) -> ReadonlyProbe? {
        let lower = config.command.lowercased()
        if lower.contains("psql") { return ReadonlyProbe(input: postgres, expect: "SNEEK_RO_OK") }
        if lower.contains("mongosh") { return ReadonlyProbe(input: mongo, expect: "SNEEK_RO_OK") }
        return nil
    }

    static func evaluate(output: String, probe: ReadonlyProbe) -> Refusal? {
        // A configured `reject` pattern wins over `expect`: a Cassandra permission listing contains
        // SELECT (expected) *and* MODIFY (rejected) for a read-write role.
        if let hit = (probe.reject ?? []).first(where: { output.contains($0) }) {
            return Refusal(code: "prod_not_readonly", message: "its database account can write (probe output contains '\(hit)')")
        }
        // `expect` is a substring of some trimmed line, not a whole line: cqlsh prints a table and
        // the token sits in a cell. The built-ins are unaffected — `SNEEK_RO_FAIL:…` never
        // contains `SNEEK_RO_OK` — and `reject` above still wins.
        let lines = output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.contains(probe.expect) }) { return nil }
        if let reason = lines.first(where: { $0.hasPrefix("SNEEK_RO_FAIL") }) {
            return Refusal(code: "prod_not_readonly", message: "its database account can write (\(reason))")
        }
        return Refusal(code: "prod_readonly_unverified", message: "its read-only check could not run: unexpected probe output")
    }
}
