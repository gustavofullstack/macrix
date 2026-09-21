import Foundation

func printUsage() {
    print("""
    macrix \(mcpServerVersion) — open macOS-automation MCP server.
    No daily limits. Concurrent clients allowed.
    Usage:
      macrix serve [--port N] [--public-port M | --no-public]
                                  MCP server on 127.0.0.1:N (default 35730) + read-only showcase on M (default 35731)
      macrix keys                 Print where API keys are loaded from
      macrix version              Print version
      macrix voice [--seconds N] [--locale pt-BR] [--dry-run]
                                  Mic → Jev → action before the sentence ends
      macrix voice-say "<texto>"  Same pipeline on a typed transcript (dry-run)
      macrix voice-file <audio> [--locale pt-BR] [--dry-run]
                                  Same pipeline on an audio file (partials → Jev)
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
    var publicPort: UInt16? = 35731
    let rest = Array(args.dropFirst())
    if let i = rest.firstIndex(of: "--port"), i + 1 < rest.count, let p = UInt16(rest[i + 1]) {
        port = p
    }
    if let i = rest.firstIndex(of: "--public-port"), i + 1 < rest.count { publicPort = UInt16(rest[i + 1]) }
    if rest.contains("--no-public") { publicPort = nil }
    let keys = Auth.loadKeys()
    if keys.isEmpty {
        fputs("macrix: no API keys configured (MACRIX_KEYS or ~/.config/macrix/keys). Refusing to start unauthenticated.\n", stderr)
        exit(1)
    }
    let registry = ToolRegistry()
    registerAllTools(into: registry)
    // Recovery must happen at boot, not at the first tool call: touching the gate
    // here reloads persisted state, kills orphaned lanes and marks them unknown.
    let gateBoot = HarnessGate.shared.status()
    fputs("macrix: gate at boot → \(gateBoot)\n", stderr)
    do {
        let server = try HTTPServer(port: port, registry: registry, keys: keys)
        server.start()
        guard server.waitReady() else {
            fputs("macrix: failed to bind port \(port).\n", stderr)
            exit(1)
        }
        var showcaseNote = "no showcase listener"
        if let pp = publicPort {
            let show = try HTTPServer(port: pp, registry: registry, keys: keys, showcase: true)
            show.start()
            showcaseNote = show.waitReady() ? "showcase (read-only, for the tunnel) on 127.0.0.1:\(pp)" : "showcase failed to bind \(pp)"
            _ = Unmanaged.passRetained(show)   // lives for the process lifetime
        }
        print("macrix \(mcpServerVersion) serving MCP on 127.0.0.1:\(port)/mcp (\(registry.list().count) tools, \(keys.count) key(s)) · \(showcaseNote) · pid \(getpid())")
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
case "voice":
    let rest = Array(args.dropFirst())
    var seconds = 20, locale = "pt-BR", execute = true
    if let i = rest.firstIndex(of: "--seconds"), i + 1 < rest.count, let s = Int(rest[i + 1]) { seconds = s }
    if let i = rest.firstIndex(of: "--locale"), i + 1 < rest.count { locale = rest[i + 1] }
    if rest.contains("--dry-run") { execute = false }
    print("macrix voice: listening \(seconds)s (\(locale)) — every partial goes to Jev \(Voice.model); \(execute ? "acting" : "dry-run")")
    fflush(stdout)
    let out = VoiceLoop.run(seconds: seconds, locale: locale, execute: execute) { line in
        print(line); print("---"); fflush(stdout)
    }
    if out.hasPrefix("voice unavailable") || out.hasPrefix("listened") { print(out) }
case "voice-file":
    let rest = Array(args.dropFirst())
    guard let path = rest.first, !path.hasPrefix("--") else { print("usage: macrix voice-file <audio> [--locale pt-BR] [--dry-run]"); exit(2) }
    var locale = "pt-BR"
    if let i = rest.firstIndex(of: "--locale"), i + 1 < rest.count { locale = rest[i + 1] }
    let execute = !rest.contains("--dry-run")
    let out = VoiceFile.run(path: path, locale: locale, execute: execute) { line in print(line); print("---"); fflush(stdout) }
    if out.hasPrefix("voice") { print(out) }
case "voice-say":
    guard let text = args.dropFirst().first else { print("usage: macrix voice-say \"<texto>\" [--execute]"); exit(2) }
    guard let key = Voice.apiKey() else { print("voice unavailable: TYPESAFE_API_KEY missing."); exit(1) }
    let brain = VoiceBrain(client: TypeSafeHTTP(key: key), installed: Apps.installed())
    print(VoiceActor.step(brain: brain, transcript: text, isFinal: true, utterance: VoiceActor.Utterance(),
                          execute: args.contains("--execute")))
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
        tier = License.Tier(name: rest[i + 1]) ?? .lifetime
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
