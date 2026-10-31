import Foundation

/// The MCP-enabled commands, as both `sneekd mcp-serve` and the `tools` IPC action expose them.
public enum ToolCatalog {
    public static func enabledTools(
        in commands: [String: CommandConfig],
        tags: Set<String>? = nil,
        commands commandFilter: Set<String>? = nil
    ) -> [ToolInfo] {
        var tools: [ToolInfo] = []
        for (_, cmd) in commands {
            if cmd.enabled == false { continue }
            guard let mcp = cmd.mcp, mcp.enabled else { continue }
            if let tags, tags.isDisjoint(with: Set(cmd.tags ?? [])) { continue }
            if let commandFilter, !commandFilter.contains(cmd.name) { continue }

            var description = mcp.toolDescription
            if cmd.readonly == true { description += " [read-only]" }
            tools.append(ToolInfo(name: "sneek_\(mcp.toolName)", command: cmd.name,
                                  description: description, readonly: cmd.readonly == true))
        }
        return tools.sorted { $0.name < $1.name }
    }
}
