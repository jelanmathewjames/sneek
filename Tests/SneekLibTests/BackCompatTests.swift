import Foundation
@testable import SneekLib

func runBackCompatTests() {
    print("\nBackward compatibility:")

    test("run responses encode exactly as before (no new keys)") {
        let ok = try JSONSerialization.jsonObject(with: JSONEncoder().encode(IPCResponse.ok("1"))) as! [String: Any]
        check(Set(ok.keys) == ["success", "output"], "\(ok.keys)")
        let fail = try JSONSerialization.jsonObject(with: JSONEncoder().encode(IPCResponse.fail("x"))) as! [String: Any]
        check(Set(fail.keys) == ["success", "error"], "\(fail.keys)")
    }

    test("a client's run request decodes") {
        let req = try JSONDecoder().decode(IPCRequest.self, from: Data(#"{"action":"run","command":"pg-prod","input":"select 1"}"#.utf8))
        check(req.action == .run && req.command == "pg-prod" && req.input == "select 1")
    }

    test("a config dir with no new keys still listens on <baseDir>/sneekd.sock with no mode") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snk-bc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"log_level":"info"}"#.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let store = try ConfigStore(baseDir: dir)
        let global = store.globalConfig
        check(global.socketPath == nil && global.socketMode == nil && global.restrictSocket == nil)
        check(Daemon.resolveSocketPath(explicit: nil, config: global, baseDir: dir)
              == dir.appendingPathComponent("sneekd.sock").path)
        check(global.socketMode.flatMap(Daemon.parseMode) == nil)
    }

    test("a command config without the new keys round-trips byte-for-byte") {
        let json = #"{"blocked_patterns":["DROP"],"command":"psql {{u}}","description":"d","mode":"session","name":"pg","readonly":true,"variables":{"u":"x"}}"#
        let cfg = try JSONDecoder().decode(CommandConfig.self, from: Data(json.utf8))
        check(cfg.rejectBackslash == nil && cfg.secretEnv == nil && cfg.secretFiles == nil
              && cfg.statementTimeout == nil && cfg.replyTimeout == nil && cfg.rowCap == nil && cfg.readonlyProbe == nil
              && cfg.maxSessions == nil && cfg.queryLimit == nil)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        check(String(data: try enc.encode(cfg), encoding: .utf8) == json)
    }

    test("the new keys decode from snake_case") {
        let json = #"{"name":"pg","description":"d","mode":"session","command":"psql","reject_backslash":true,"secret_env":{"PGUSER":"{{u}}"},"secret_files":{"PGPASSFILE":{"content":"*:*:*:*:{{password}}","escape":"pgpass"}},"statement_timeout":30,"reply_timeout":40,"row_cap":500,"readonly_probe":{"input":"select 'ok'","expect":"ok","reject":["MODIFY","ALTER"]},"max_sessions":3,"query_limit":true}"#
        let cfg = try JSONDecoder().decode(CommandConfig.self, from: Data(json.utf8))
        check(cfg.rejectBackslash == true && cfg.secretEnv == ["PGUSER": "{{u}}"] && cfg.statementTimeout == 30
              && cfg.replyTimeout == 40 && cfg.rowCap == 500 && cfg.readonlyProbe?.expect == "ok" && cfg.maxSessions == 3
              && cfg.queryLimit == true && cfg.readonlyProbe?.reject == ["MODIFY", "ALTER"])
        check(cfg.secretFiles?["PGPASSFILE"] == SecretFileSpec(content: "*:*:*:*:{{password}}", escape: "pgpass"))
    }

    test("keepingUneditedKeys: form fields win, keys the editor has no field for survive") {
        var original = CommandConfig(name: "pg", description: "old", mode: .session, idleTimeout: 120,
                                     command: "psql old", sentinel: #"\echo __SNEEK_DONE__"#)
        original.rejectBackslash = true; original.secretEnv = ["A": "{{a}}"]
        original.secretFiles = ["PGPASSFILE": SecretFileSpec(content: "x", escape: "pgpass")]
        original.statementTimeout = 30; original.replyTimeout = 40; original.rowCap = 500
        original.readonlyProbe = ReadonlyProbe(input: "select 'ok'", expect: "ok"); original.maxSessions = 3; original.queryLimit = true
        let fromForm = CommandConfig(name: "pg", description: "new", mode: .oneshot, readonly: true, command: "psql new",
                                     blockedPatterns: ["DROP"])   // what the editor builds: no idle_timeout, no sentinel, no new keys
        let merged = fromForm.keepingUneditedKeys(from: original)
        check(merged.description == "new" && merged.mode == .oneshot && merged.command == "psql new"
              && merged.readonly == true && merged.blockedPatterns == ["DROP"], "form fields must win")
        check(merged.idleTimeout == 120 && merged.sentinel == original.sentinel, "existing unedited keys survive")
        check(merged.rejectBackslash == true && merged.secretEnv == ["A": "{{a}}"] && merged.secretFiles == original.secretFiles
              && merged.statementTimeout == 30 && merged.replyTimeout == 40 && merged.rowCap == 500
              && merged.readonlyProbe == original.readonlyProbe && merged.maxSessions == 3 && merged.queryLimit == true, "new keys survive")
        let untouched = fromForm.keepingUneditedKeys(from: fromForm)
        check(untouched == fromForm, "no unedited keys → identical")
    }
}
