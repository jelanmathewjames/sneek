import Foundation
@testable import SneekLib

func runConfigStoreTests() {
    print("\nConfigStore:")

    test("Loads commands from directory") {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sneek-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ConfigStore(baseDir: tempDir)
        check(store.commands.isEmpty, "starts empty")

        let json = """
        {
          "name": "test-cmd",
          "description": "A test command",
          "mode": "oneshot",
          "command": "echo hello"
        }
        """
        let file = tempDir.appendingPathComponent("commands/test-cmd.json")
        try json.data(using: .utf8)!.write(to: file)

        try store.reload()
        check(store.commands.count == 1, "one command loaded")
        check(store.commands["test-cmd"]?.description == "A test command", "description matches")
    }

    test("Save and reload from disk") {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sneek-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ConfigStore(baseDir: tempDir)

        var cmd = CommandConfig(
            name: "saved-cmd",
            description: "Saved command",
            mode: .session,
            command: "psql {{host}}"
        )
        cmd.variables = ["host": "localhost"]

        try store.save(cmd)
        check(store.commands["saved-cmd"]?.command == "psql {{host}}", "in-memory after save")

        let store2 = try ConfigStore(baseDir: tempDir)
        check(store2.commands["saved-cmd"]?.variables?["host"] == "localhost", "reloaded from disk")
    }

    test("Delete command removes file and entry") {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sneek-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ConfigStore(baseDir: tempDir)
        let cmd = CommandConfig(name: "del", description: "x", mode: .oneshot, command: "echo")
        try store.save(cmd)
        check(store.commands["del"] != nil, "exists after save")

        try store.delete("del")
        check(store.commands["del"] == nil, "nil after delete")

        let file = tempDir.appendingPathComponent("commands/del.json")
        check(!FileManager.default.fileExists(atPath: file.path), "file removed")
    }

    test("reload: a malformed command file is skipped with a warning; the good one stays loaded") {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sneek-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ConfigStore(baseDir: tempDir)
        try store.save(CommandConfig(name: "good", description: "x", mode: .oneshot, command: "echo"))
        try Data("{\"name\": \"bad\", \"mode\": \"oneshot\"".utf8).write(to: tempDir.appendingPathComponent("commands/bad.json"))

        // Capture stderr: the skip must be visible in the daemon log, not silent.
        let pipe = Pipe()
        let saved = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        var reloadError: Error?
        do { try store.reload() } catch { reloadError = error }
        dup2(saved, STDERR_FILENO)
        close(saved)
        pipe.fileHandleForWriting.closeFile()
        let err = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        check(reloadError == nil, "reload must not throw for one bad file: \(String(describing: reloadError))")
        check(store.commands.count == 1 && store.commands["good"] != nil, "\(store.commands.keys.sorted())")
        check(err.contains("[WARN]") && err.contains("bad.json"), err)

        // A fresh store over the same directory behaves the same way at start-up.
        let store2 = try ConfigStore(baseDir: tempDir)
        check(store2.commands.count == 1 && store2.commands["good"] != nil, "\(store2.commands.keys.sorted())")
    }

    test("Global config save and load") {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sneek-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ConfigStore(baseDir: tempDir)
        check(store.globalConfig.scriptOutputDir == nil, "default nil")

        let config = SneekConfig(scriptOutputDir: "~/bin", logLevel: "debug")
        try store.saveGlobalConfig(config)

        let store2 = try ConfigStore(baseDir: tempDir)
        check(store2.globalConfig.scriptOutputDir == "~/bin", "script dir")
        check(store2.globalConfig.logLevel == "debug", "log level")
    }
}
