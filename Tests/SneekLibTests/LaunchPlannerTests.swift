import Foundation
@testable import SneekLib

func runLaunchPlannerTests() {
    print("\nLaunchPlanner:")
    let daemonEnv = ["PATH": "/usr/bin", "HOME": "/h", "PG_PROD_PASSWORD": "canary-pg", "MONGO_PASSWORD": "canary-mongo", "LANG": "C.UTF-8"]
    let base = CommandConfig(name: "pg", description: "d", mode: .session, command: "psql -h db -U ro app")

    test("no settings → inherit, exactly as today") {
        let ctx = try LaunchPlanner.plan(config: base, global: SneekConfig(), resolved: ["password": "p"], daemonEnvironment: daemonEnv)
        check(ctx == .inherit && ctx.isInherit)
    }

    test("scrub: only allowlisted variables survive; other databases' secrets do not") {
        let ctx = try LaunchPlanner.plan(config: base, global: SneekConfig(scrubChildEnv: true), resolved: [:], daemonEnvironment: daemonEnv)
        check(ctx.baseEnvironment == ["PATH": "/usr/bin", "HOME": "/h", "LANG": "C.UTF-8"], "\(String(describing: ctx.baseEnvironment))")
    }

    test("secret_env is rendered from resolved values") {
        var c = base; c.secretEnv = ["PGPASSWORD": "{{password}}", "PGUSER": "{{user}}"]
        let ctx = try LaunchPlanner.plan(config: c, global: SneekConfig(), resolved: ["password": "p$\"' @/#%", "user": "ro"], daemonEnvironment: daemonEnv)
        check(ctx.extraEnvironment == ["PGPASSWORD": "p$\"' @/#%", "PGUSER": "ro"])
        check(ctx.baseEnvironment == nil, "without scrub the rest is still inherited")
    }

    test("secret_files with pgpass escaping escapes ':' and '\\' in values only") {
        var c = base
        c.secretFiles = ["PGPASSFILE": SecretFileSpec(content: "{{host}}:5432:*:{{user}}:{{password}}", escape: "pgpass")]
        let ctx = try LaunchPlanner.plan(config: c, global: SneekConfig(), resolved: ["host": "db", "user": "ro", "password": #"a:b\c"#], daemonEnvironment: daemonEnv)
        check(ctx.secretFiles["PGPASSFILE"] == #"db:5432:*:ro:a\:b\\c"#, ctx.secretFiles["PGPASSFILE"] ?? "nil")
    }

    test("unknown escape and unresolved placeholder are errors") {
        var c = base; c.secretFiles = ["F": SecretFileSpec(content: "x", escape: "yaml")]
        checkThrows({ try LaunchPlanner.plan(config: c, global: SneekConfig(), resolved: [:], daemonEnvironment: [:]) })
        var d = base; d.secretEnv = ["X": "{{missing}}"]
        checkThrows({ try LaunchPlanner.plan(config: d, global: SneekConfig(), resolved: [:], daemonEnvironment: [:]) })
    }
}
