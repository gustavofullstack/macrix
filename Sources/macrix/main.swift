import Foundation

func printUsage() {
    print("""
    macrix \(mcpServerVersion) — open macOS-automation MCP server.
    No daily limits. Concurrent clients allowed.
    Usage:
      macrix serve [--port N]     Start the MCP server (default port 35730)
      macrix keys                 Print where API keys are loaded from
      macrix version              Print version
    Keys: env MACRIX_KEYS (comma-separated) and/or ~/.config/macrix/keys
    Jev hook: set MACRIX_JEV=1 to enable the jev_rerank tool.
    """)
}

let args = CommandLine.arguments.dropFirst()
guard let cmd = args.first else { printUsage(); exit(2) }

switch cmd {
case "version":
    print("\(mcpServerName) \(mcpServerVersion)")
case "keys":
    print("env MACRIX_KEYS + ~/.config/macrix/keys")
    print("configured keys: \(Auth.loadKeys().count)")
case "serve":
    var port: UInt16 = 35730
    let rest = Array(args.dropFirst())
    if let i = rest.firstIndex(of: "--port"), i + 1 < rest.count, let p = UInt16(rest[i + 1]) {
        port = p
    }
    let keys = Auth.loadKeys()
    if keys.isEmpty {
        fputs("macrix: no API keys configured (MACRIX_KEYS or ~/.config/macrix/keys). Refusing to start unauthenticated.\n", stderr)
        exit(1)
    }
    let registry = ToolRegistry()
    registerAllTools(into: registry)
    do {
        let server = try HTTPServer(port: port, registry: registry, keys: keys)
        server.start()
        guard server.waitReady() else {
            fputs("macrix: failed to bind port \(port).\n", stderr)
            exit(1)
        }
        print("macrix \(mcpServerVersion) serving MCP on 127.0.0.1:\(port)/mcp (\(registry.list().count) tools, \(keys.count) key(s))")
        fflush(stdout)
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { exit(0) }
        src.resume()
        dispatchMain()
    } catch {
        fputs("macrix: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
case "license":
    let info = License.current()
    var line = "tier: " + info.tier.rawValue
    if let exp = info.expires { line += " (expires " + exp + ")" }
    if info.key.isEmpty { line += " [no license file — free tier]" }
    print(line)
case "license-issue":
    var tier: License.Tier = .lifetime
    var months = 1
    let rest = Array(args.dropFirst())
    if let i = rest.firstIndex(of: "--tier"), i + 1 < rest.count {
        tier = License.Tier(rawValue: rest[i + 1]) ?? .lifetime
    }
    if let i = rest.firstIndex(of: "--months"), i + 1 < rest.count, let m = Int(rest[i + 1]) {
        months = m
    }
    let key = License.issue(tier: tier, months: months)
    print("issued \(tier.rawValue) license: \(key)")
    print("NOTE: v0.3 self-issues locally; production issuance moves to the account server.")
default:
    printUsage(); exit(2)
}
