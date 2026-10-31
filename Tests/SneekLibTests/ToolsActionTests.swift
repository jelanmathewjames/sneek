import Foundation
@testable import SneekLib

private func cmd(_ name: String, tool: String?, enabled: Bool? = nil, readonly: Bool? = nil, mcpEnabled: Bool = true) -> CommandConfig {
    CommandConfig(name: name, description: "d", enabled: enabled, mode: .session, readonly: readonly, command: "cat",
                  mcp: tool.map { MCPConfig(enabled: mcpEnabled, toolName: $0, toolDescription: "Desc \($0)") })
}

func runToolsActionTests() {
    print("\nTools action:")

    test("enabledTools lists enabled MCP commands, sorted, with command name and read-only flag") {
        let all = ["pg-prod": cmd("pg-prod", tool: "pg_prod", readonly: true),
                   "a-dev": cmd("a-dev", tool: "a_dev"),
                   "off": cmd("off", tool: "off", enabled: false),
                   "nomcp": cmd("nomcp", tool: nil),
                   "mcpoff": cmd("mcpoff", tool: "mcpoff", mcpEnabled: false)]
        let tools = ToolCatalog.enabledTools(in: all)
        check(tools.map(\.name) == ["sneek_a_dev", "sneek_pg_prod"], "\(tools.map(\.name))")
        check(tools[1] == ToolInfo(name: "sneek_pg_prod", command: "pg-prod", description: "Desc pg_prod [read-only]", readonly: true))
        check(tools[0].readonly == false && tools[0].description == "Desc a_dev")
    }

    test("tools response JSON has exactly the agreed keys") {
        let resp = IPCResponse(success: true, tools: [ToolInfo(name: "sneek_x", command: "x", description: "D", readonly: false)])
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(resp)) as! [String: Any]
        check(Set(obj.keys) == ["success", "tools"], "\(obj.keys)")
        let t = (obj["tools"] as! [[String: Any]])[0]
        check(Set(t.keys) == ["name", "command", "description", "readonly"], "\(t.keys)")
    }

    test("refused() carries a code and the 'refused: ' prefix") {
        let r = IPCResponse.refused(code: "action_restricted", "action 'shutdown' is not allowed on this socket")
        check(r.success == false && r.code == "action_restricted")
        check(r.error == "refused: action 'shutdown' is not allowed on this socket")
    }

    test("{\"action\":\"tools\"} decodes") {
        let req = try JSONDecoder().decode(IPCRequest.self, from: Data(#"{"action":"tools"}"#.utf8))
        check(req.action == .tools)
    }
}
