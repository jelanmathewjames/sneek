import Foundation
@testable import SneekLib

private func psql(_ reject: Bool? = nil) -> CommandConfig {
    CommandConfig(name: "pg", description: "d", mode: .session, command: "psql --csv postgresql://u@h/db", rejectBackslash: reject)
}
private let on = SneekConfig(rejectBackslash: true)

func runGuardsTests() {
    print("\nGuards:")

    test("backslash: the three shell escapes from spike check 11 are refused") {
        for probe in [#"\! id; echo LEAK=$OTHER_DB_PASSWORD"#,
                      "\\o | cat > /tmp/pwned.txt\nselect 'written by psql';\n\\o",
                      #"\copy (select 1) to program 'echo COPY_PROGRAM_RAN >&2'"#] {
            let r = InputGuard.check(input: probe, config: psql(), global: on)
            check(r?.code == "backslash_rejected", "not refused: \(probe)")
        }
        check(InputGuard.check(input: "select 1", config: psql(), global: on) == nil)
        check(InputGuard.check(input: nil, config: psql(), global: on) == nil)
    }

    test("backslash: refusal text names the command") {
        let r = InputGuard.check(input: #"\dt"#, config: psql(), global: on)
        check(r?.message == "input contains a backslash, which is not allowed for command 'pg'", r?.message ?? "nil")
    }

    test("backslash: OFF by default — \\dt still passes with no settings") {
        check(InputGuard.check(input: #"\dt"#, config: psql(), global: SneekConfig()) == nil)
    }

    test("backslash: global default applies to psql-type commands only") {
        let mongo = CommandConfig(name: "m", description: "d", mode: .session, command: "mongosh mongodb://h/db")
        check(InputGuard.check(input: #"db.c.find({a:/\d+/})"#, config: mongo, global: on) == nil)
    }

    test("redaction: resolved secret values never appear in a reply") {
        let secrets = ["canary-mongo-pw-1", "r:o\\p w$\"'@/#%", "short"]
        let out = "uri=mongodb://u:canary-mongo-pw-1@h/db\npw=r:o\\p w$\"'@/#%\nshort stays"
        check(Redaction.apply(out, secrets: secrets) == "uri=mongodb://u:[sneek: redacted secret]@h/db\npw=[sneek: redacted secret]\nshort stays")
        check(Redaction.apply("clean", secrets: secrets) == "clean" && Redaction.apply(out, secrets: []) == out)
    }

    test("backslash: the per-command key overrides the global default either way") {
        check(InputGuard.check(input: #"\dt"#, config: psql(false), global: on) == nil)
        let bash = CommandConfig(name: "b", description: "d", mode: .session, command: "bash", rejectBackslash: true)
        check(InputGuard.check(input: #"echo \n"#, config: bash, global: SneekConfig())?.code == "backslash_rejected")
    }

    test("row cap: truncates by lines and says so") {
        let out = (1...10).map(String.init).joined(separator: "\n")
        check(RowCap.apply(out, cap: 3) == "1\n2\n3\n[sneek] output truncated: showing first 3 of 10 lines (row_cap)")
        check(RowCap.apply(out, cap: 10) == out && RowCap.apply(out, cap: nil) == out && RowCap.apply("", cap: 1) == "")
    }

    test("timeouts: defaults and Postgres setup command") {
        var c = CommandConfig(name: "pg", description: "d", mode: .session, command: "psql x", setupCommands: ["SET a = 1;"])
        check(SessionManager.effectiveReplyTimeout(c) == nil && SessionManager.effectiveSetupCommands(c) == ["SET a = 1;"])
        c.statementTimeout = 30
        check(SessionManager.effectiveReplyTimeout(c) == 35)
        check(SessionManager.effectiveSetupCommands(c) == ["SET statement_timeout = 30000;", "SET a = 1;"])
        c.replyTimeout = 60
        check(SessionManager.effectiveReplyTimeout(c) == 60)
        let mongo = CommandConfig(name: "m", description: "d", mode: .session, command: "mongosh x", statementTimeout: 30)
        check(SessionManager.effectiveSetupCommands(mongo) == nil, "only psql-type gets a SET")
    }

    test("query limit: Postgres single read statements are wrapped; everything else passes through") {
        var c = CommandConfig(name: "pg", description: "d", mode: .session, command: "psql x"); c.rowCap = 500; c.queryLimit = true
        check(QueryLimit.limit(c) == 501)
        check(QueryLimit.apply("select * from t;", config: c) == "SELECT * FROM (\nselect * from t\n) AS sneek_q LIMIT 501")
        check(QueryLimit.apply("  WITH a AS (select 1) select * from a -- newest\n", config: c)
              == "SELECT * FROM (\nWITH a AS (select 1) select * from a -- newest\n) AS sneek_q LIMIT 501", "trailing comment needs the newline before ')'")
        check(QueryLimit.apply("/* c */ values (1)", config: c) == "SELECT * FROM (\n/* c */ values (1)\n) AS sneek_q LIMIT 501")
        check(QueryLimit.apply("TABLE t", config: c) == "SELECT * FROM (\nTABLE t\n) AS sneek_q LIMIT 501")
        check(QueryLimit.apply("select 1;;  ", config: c) == "SELECT * FROM (\nselect 1\n) AS sneek_q LIMIT 501")
        for s in ["explain select 1", "SET x = 1", "show all", "begin", "selection_x()", "tables"] {
            check(QueryLimit.apply(s, config: c) == s, "pass-through: \(s)")
        }
        check(QueryLimit.apply("select 1; select * from big", config: c) == "SELECT * FROM (\nselect 1; select * from big\n) AS sneek_q LIMIT 501",
              "two statements are wrapped as one → Postgres syntax error, nothing runs")
        c.queryLimit = nil; check(QueryLimit.apply("select 1", config: c) == "select 1" && QueryLimit.limit(c) == nil, "off by default")
        c.queryLimit = true; c.rowCap = nil; check(QueryLimit.apply("select 1", config: c) == "select 1", "needs row_cap")
    }

    test("query limit: CQL SELECTs get LIMIT before ALLOW FILTERING unless one is present") {
        var c = CommandConfig(name: "c", description: "d", mode: .session, command: "cqlsh x"); c.rowCap = 100; c.queryLimit = true
        check(QueryLimit.apply("select * from ks.t;", config: c) == "select * from ks.t LIMIT 101;")
        check(QueryLimit.apply("select * from ks.t", config: c) == "select * from ks.t LIMIT 101")
        check(QueryLimit.apply("select * from ks.t where a = 1 allow filtering;", config: c) == "select * from ks.t where a = 1 LIMIT 101 allow filtering;")
        check(QueryLimit.apply("select * from ks.t limit 5", config: c) == "select * from ks.t limit 5", "an explicit LIMIT is kept")
        check(QueryLimit.apply("describe tables", config: c) == "describe tables")
        check(QueryLimit.apply("select * from ks.t where n = 'straße'", config: c) == "select * from ks.t where n = 'straße'",
              "a value whose upper-casing changes length is left alone rather than mis-spliced")
    }

    test("query limit: mongosh gets a displayBatchSize setup command; the input is untouched") {
        var m = CommandConfig(name: "m", description: "d", mode: .session, command: "mongosh x", setupCommands: ["use app"])
        m.rowCap = 100; m.queryLimit = true
        check(QueryLimit.apply("db.t.find()", config: m) == "db.t.find()")
        check(SessionManager.effectiveSetupCommands(m) == [#"config.set("displayBatchSize", 101)"#, "use app"])
        m.queryLimit = nil
        check(SessionManager.effectiveSetupCommands(m) == ["use app"], "off by default")
    }

    test("psql terminator: every statement gets a ';' line of its own, terminated already or not") {
        let c = psql()
        check(Terminator.psqlTerminated("select 1", config: c) == "select 1\n;")
        check(Terminator.psqlTerminated("select 1;", config: c) == "select 1;\n;", "psql prints nothing for the empty statement")
        check(Terminator.psqlTerminated("select 1;\n", config: c) == "select 1;\n\n;")
        check(Terminator.psqlTerminated(#"\dt"#, config: c) == #"\dt"#, "a backslash command takes no semicolon")
        check(Terminator.psqlTerminated("   ", config: c) == "   ", "empty input is left alone")
        let mongo = CommandConfig(name: "m", description: "d", mode: .session, command: "mongosh x")
        check(Terminator.psqlTerminated("db.t.find()", config: mongo) == "db.t.find()", "psql-type only")
    }

    test("psql terminator: a trailing line comment cannot swallow the semicolon") {
        let c = psql()
        check(Terminator.psqlTerminated("select * from t -- note", config: c) == "select * from t -- note\n;",
              "a ';' appended to the comment line would never reach the parser")
        check(Terminator.psqlTerminated("select 1\n-- ;", config: c) == "select 1\n-- ;\n;",
              "a commented-out ';' does not terminate the statement")
        check(Terminator.psqlTerminated("select 1 /* ; */", config: c) == "select 1 /* ; */\n;",
              "no heuristic about what counts as terminated: the ';' is always added")
    }

    test("psql terminator: a query-limited statement still ends with a semicolon") {
        var c = CommandConfig(name: "pg", description: "d", mode: .session, command: "psql x"); c.rowCap = 500; c.queryLimit = true
        let wrapped = Terminator.psqlTerminated(QueryLimit.apply("select * from t", config: c), config: c)
        check(wrapped == "SELECT * FROM (\nselect * from t\n) AS sneek_q LIMIT 501\n;", wrapped)
    }
}
