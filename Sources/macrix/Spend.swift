import Foundation

/// Spend estimation from local logs (G3 second half).
/// Honest rules: tokens are MEASURED where logs carry them (muse
/// model_completed); everywhere else is n/a with the reason. Cost in USD is
/// computed ONLY from ~/.config/macrix/rates.json (model -> $/Mtok in/out),
/// which the owner fills from real invoices — no invented rates in code.
/// Codex contributes limit/credit metadata (has_credits, balance, limit_id).
public enum Spend {
    public struct Tokens: Sendable {
        public var input: Int = 0
        public var output: Int = 0
        public var cached: Int = 0
    }

    static func scanMuse(root: String, maxFiles: Int = 300) -> (Tokens, [String: Int]) {
        var tot = Tokens()
        var perModel: [String: Int] = [:]  // model -> input+output
        let files = Providers.find(basename: "session.jsonl", under: root, maxFiles: maxFiles)
        for url in files {
            guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? fh.close() }
            guard let data = try? fh.readToEnd(), data.count < (8 << 20),
                  let text = String(data: data, encoding: .utf8) else { continue }
            // Lightweight scan: only lines mentioning model_completed carry usage.
            for line in text.split(separator: "\n") {
                guard line.count < 200_000, line.contains("model_completed") else { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      let event = payload["event"] as? [String: Any],
                      let usage = event["usage"] as? [String: Any] else { continue }
                let i = usage["input_tokens"] as? Int ?? 0
                let o = usage["output_tokens"] as? Int ?? 0
                let c = usage["cached_tokens"] as? Int ?? 0
                tot.input += i; tot.output += o; tot.cached += c
                let model = event["model"] as? String
                    ?? (payload["model"] as? String) ?? "unknown"
                perModel[model, default: 0] += i + o
            }
        }
        return (tot, perModel)
    }

    static func scanCodexLimits(root: String, maxFiles: Int = 60) -> [String] {
        var out: [String] = []
        let files = Providers.find(ext: "jsonl", under: root, maxFiles: maxFiles)
        for url in files.prefix(20) {
            guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? fh.close() }
            guard let data = try? fh.readToEnd(), data.count < (8 << 20),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard line.contains("token_count") else { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let pl = (obj["payload"] as? [String: Any]),
                      let rl = pl["rate_limits"] as? [String: Any] else { continue }
                let lid = rl["limit_id"] as? String ?? "?"
                var cred = "credits?"
                if let cr = rl["credits"] as? [String: Any] {
                    let has = cr["has_credits"] as? Bool ?? false
                    var bstr = ""
                    if let b = cr["balance"], !(b is NSNull) { bstr = " balance=\(b)" }
                    cred = "has_credits=\(has)" + bstr
                }
                let s = "\(lid) \(cred)"
                if !out.contains(s) { out.append(s) }
            }
        }
        return out
    }

    static func rates() -> [String: [String: Double]] {
        let p = (NSHomeDirectory() as NSString).appendingPathComponent(".config/macrix/rates.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]] else { return [:] }
        return obj
    }

    public static func report() -> String {
        let home = NSHomeDirectory()
        let (muse, perModel) = scanMuse(root: home + "/.local/share/muse/sessions")
        let rates = rates()
        var costLines: [String] = []
        var costed = false
        var lines = ["- muse: in \(muse.input) / out \(muse.output) / cached \(muse.cached) tokens"]
        for (model, n) in perModel.sorted(by: { $0.value > $1.value }).prefix(5) {
            lines.append("    \(model): \(n) tokens")
        }
        if let star = rates["*"], let ri = star["in"], let ro = star["out"] {
            let c = Double(muse.input) / 1e6 * ri + Double(muse.output) / 1e6 * ro
            costed = true
            costLines.append(String(format: "estimated cost @ default rate: $%.2f", c))
        }
        let limits = scanCodexLimits(root: home + "/.codex/sessions")
        lines.append("- codex: tokens n/a (rollouts carry no usage counts); " +
                     (limits.isEmpty ? "no limit metadata" : "limits: " + limits.joined(separator: " | ")))
        lines.append("- claude/cursor/antigravity/opencode/gemini: tokens n/a (no usage fields in local logs)")
        if costed { lines.append(contentsOf: costLines) }
        else { lines.append("cost: n/a — fill ~/.config/macrix/rates.json from invoices to enable $ math") }
        return lines.joined(separator: "\n")
    }
}
