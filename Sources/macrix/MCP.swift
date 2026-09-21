import Foundation

public let mcpServerName = "macrix"
public let mcpServerVersion = "0.15.0"

public struct Tool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let run: @Sendable (JSONValue) async -> JSONValue
    public init(name: String, description: String, inputSchema: JSONValue,
                run: @escaping @Sendable (JSONValue) async -> JSONValue) {
        self.name = name; self.description = description
        self.inputSchema = inputSchema; self.run = run
    }
}

/// Thread-safe registry: concurrent tools/calls from any number of agents.
public final class ToolRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tools: [String: Tool] = [:]
    public init() {}
    public func register(_ tool: Tool) {
        lock.withLock { tools[tool.name] = tool }
    }
    public func list() -> [Tool] {
        lock.withLock { tools.values.sorted { $0.name < $1.name } }
    }
    public func call(name: String, args: JSONValue) async -> JSONValue {
        guard let tool = lock.withLock({ tools[name] }) else {
            return .object(["content": .array([.object(["type": .string("text"),
                "text": .string("unknown tool: \(name)")])]), "isError": .bool(true)])
        }
        return await tool.run(args)
    }
}

public func textContent(_ text: String, isError: Bool = false) -> JSONValue {
    .object(["content": .array([.object(["type": .string("text"),
              "text": .string(text)])]),
             "isError": .bool(isError)])
}

/// JSON-RPC dispatcher. Returns nil for notifications (no response).
public enum MCPDispatcher {
    public static func handle(request: JSONValue, registry: ToolRegistry) async -> JSONValue? {
        guard case .object(let obj) = request,
              let method = obj["method"]?.string else {
            return jsonError(code: -32600, message: "invalid request", id: request["id"])
        }
        let id = obj["id"]
        let params = obj["params"] ?? .object([:])
        switch method {
        case "initialize":
            return jsonResult(.object([
                "protocolVersion": .string("2025-06-18"),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(mcpServerName),
                                       "title": .string("macrix MCP server"),
                                       "version": .string(mcpServerVersion)]),
            ]), id: id)
        case "notifications/initialized":
            return nil
        case "ping":
            return jsonResult(.object([:]), id: id)
        case "tools/list":
            let arr: [JSONValue] = registry.list().map { t in
                .object(["name": .string(t.name),
                         "description": .string(t.description),
                         "inputSchema": t.inputSchema])
            }
            return jsonResult(.object(["tools": .array(arr)]), id: id)
        case "tools/call":
            guard let name = params["name"]?.string else {
                return jsonError(code: -32602, message: "missing tool name", id: id)
            }
            let args = params["arguments"] ?? .object([:])
            return jsonResult(await registry.call(name: name, args: args), id: id)
        default:
            return jsonError(code: -32601, message: "method not found: \(method)", id: id)
        }
    }
}
