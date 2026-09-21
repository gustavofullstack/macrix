import Foundation

/// Jev-as-the-brain: the server routes through the local TypeSafe CLI
/// (jev-1.13.0) instead of guessing. Every judgment returns its noul number
/// so callers cite evidence, not vibes. Gated by MACRIX_JEV=1 like jev_rerank.
public enum Jev {
    static func enabled() -> Bool {
        ProcessInfo.processInfo.environment["MACRIX_JEV"] == "1"
    }
    static func helper() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/typesafe")
    }
    static func disabled() -> String {
        "jev disabled: set MACRIX_JEV=1 in the server environment to enable."
    }

    /// Route a free-text request to the best macrix tools via Jev rerank.
    static func route(_ request: String, tools: [Tool]) -> String {
        guard enabled() else { return disabled() }
        let docs = tools.map { "\($0.name): \($0.description)" }
        let helper = helper()
        // rerank in two batches to stay within arg limits
        var scored: [(String, Double)] = []
        for chunk in docs.chunked(20) {
            var cmd = ["rerank", request]
            cmd.append(contentsOf: chunk)
            let (code, out) = runShell(helper, args: cmd, timeoutSeconds: 120)
            guard code == 0 else { continue }
            scored.append(contentsOf: parseRerank(out))
        }
        guard !scored.isEmpty else { return "jev route failed: no scores." }
        let top = scored.sorted { $0.1 > $1.1 }.prefix(5)
        return "jev route (noul):\n" + top.map { "- \($0.0) (\($0.1))" }.joined(separator: "\n")
    }

    /// Pure parser: "  #1 [Doc 3] Noul=0.81 -> name: desc..." -> [(name, score)].
    static func parseRerank(_ out: String) -> [(String, Double)] {
        var scored: [(String, Double)] = []
        for line in out.components(separatedBy: "\n") {
            guard let nRange = line.range(of: "Noul="),
                  let arrow = line.range(of: " -> ") else { continue }
            let num = String(line[nRange.upperBound...].prefix(while: { $0.isNumber || $0 == "." }))
            let name = String(line[arrow.upperBound...].prefix(while: { $0 != ":" })).trimmingCharacters(in: .whitespaces)
            if let v = Double(num), !name.isEmpty { scored.append((name, v)) }
        }
        return scored
    }

    static func ping() -> String {
        let (code, out) = runShell(helper(), args: ["status"], timeoutSeconds: 30)
        guard code == 0 else { return "jev unreachable." }
        if out.contains("\"status\"") || out.contains("ok") {
            let model = out.contains("jev-1.13") ? "jev-1.13" : "jev"
            return "jev ok (\(model))"
        }
        return "jev status unclear."
    }

    static func bun() -> String? {
        let home = NSHomeDirectory()
        let cands = [home + "/.bun/bin/bun", home + "/.local/bin/bun",
                     "/opt/homebrew/bin/bun", "/usr/local/bin/bun"]
        return cands.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func runShell(_ path: String, args: [String], timeoutSeconds: Double) -> (Int32, String) {
        // node is absent on this machine; bun runs the typesafe entry.
        // launchd PATH is minimal, so resolve bun by absolute path.
        guard let bun = bun() else { return (-1, "bun not found") }
        // The typesafe entry spawns `python3` internally; launchd PATH lacks
        // the uv python that carries typesafe_sdk, so export a full PATH.
        let home = NSHomeDirectory()
        let pathExport = "export PATH=\"\(home)/.local/bin:\(home)/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\"; "
        let (code, out) = runProcess("/bin/sh",
            ["-c", pathExport + "'\(bun)' '\(path)' \(args.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }.joined(separator: " "))"],
            timeoutSeconds: timeoutSeconds)
        return (code, out)
    }
}

extension Array {
    func chunked(_ n: Int) -> [[Element]] {
        stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) }
    }
}
