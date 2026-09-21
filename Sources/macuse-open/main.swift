import Foundation

func printUsage() {
    print("""
    macuse-open \(mcpServerVersion) — open macOS-automation MCP server.
    No daily limits. Concurrent clients allowed.
    Usage:
      macuse-open serve [--port N]     Start the MCP server (default port 35730)
      macuse-open keys                 Print where API keys are loaded from
      macuse-open version              Print version
    Keys: env MACUSE_OPEN_KEYS (comma-separated) and/or ~/.config/macuse-open/keys
    Jev hook: set MACUSE_OPEN_JEV=1 to enable the jev_rerank tool.
    """)
}

let args = CommandLine.arguments.dropFirst()
guard let cmd = args.first else { printUsage(); exit(2) }

switch cmd {
case "version":
    print("\(mcpServerName) \(mcpServerVersion)")
case "keys":
    print("env MACUSE_OPEN_KEYS + ~/.config/macuse-open/keys")
    print("configured keys: \(Auth.loadKeys().count)")
case "serve":
    var port: UInt16 = 35730
    let rest = Array(args.dropFirst())
    if let i = rest.firstIndex(of: "--port"), i + 1 < rest.count, let p = UInt16(rest[i + 1]) {
        port = p
    }
    let keys = Auth.loadKeys()
    if keys.isEmpty {
        fputs("macuse-open: no API keys configured (MACUSE_OPEN_KEYS or ~/.config/macuse-open/keys). Refusing to start unauthenticated.\n", stderr)
        exit(1)
    }
    let registry = ToolRegistry()
    registerAllTools(into: registry)
    do {
        let server = try HTTPServer(port: port, registry: registry, keys: keys)
        server.start()
        guard server.waitReady() else {
            fputs("macuse-open: failed to bind port \(port).\n", stderr)
            exit(1)
        }
        print("macuse-open \(mcpServerVersion) serving MCP on 127.0.0.1:\(port)/mcp (\(registry.list().count) tools, \(keys.count) key(s))")
        fflush(stdout)
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { exit(0) }
        src.resume()
        dispatchMain()
    } catch {
        fputs("macuse-open: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
default:
    printUsage(); exit(2)
}
