import Foundation

/// v0.23 web console (G1): read-only status page + JSON catalog.
/// No auth (loopback-only, like /health), no secrets, no actions —
/// it only renders what the server already exposes.
public enum Console {
    static func html(version: String, tier: String, tools: Int, requests: Int, uptime: Int) -> String {
        let h = uptime / 3600, m = (uptime % 3600) / 60, s = uptime % 60
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>macrix \(version)</title>
        <style>body{font-family:system-ui,sans-serif;max-width:40rem;margin:3rem auto;padding:0 1.5rem;line-height:1.6;color:#14181c}
        h1{font-size:1.6rem}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(8rem,1fr));gap:.75rem;margin:1.5rem 0}
        .stat{border:1px solid #d6dee4;border-radius:6px;padding:.75rem 1rem}.stat b{font-size:1.4rem;display:block}
        .stat span{font-size:.75rem;color:#6d7c87;text-transform:uppercase;letter-spacing:.06em}
        code{background:#edf1f4;padding:.1em .35em;border-radius:3px}</style></head><body>
        <h1>macrix <code>\(version)</code></h1>
        <p>Open macOS-automation MCP server. No daily limits; concurrent clients allowed.</p>
        <div class="grid">
        <div class="stat"><b>\(tools)</b><span>tools</span></div>
        <div class="stat"><b>\(tier)</b><span>tier</span></div>
        <div class="stat"><b>\(requests)</b><span>requests</span></div>
        <div class="stat"><b>\(h)h \(m)m \(s)s</b><span>uptime</span></div>
        </div>
        <p><code>POST /mcp</code> (Bearer) · <code>GET /health</code> · <code>GET /catalog</code></p>
        </body></html>
        """
    }

    static func catalog(_ tools: [Tool]) -> String {
        let items = tools.sorted { $0.name < $1.name }.map {
            "{\"name\":\($0.name.jsonQuoted),\"description\":\($0.description.jsonQuoted)}"
        }
        return "{\"tools\":[\(items.joined(separator: ","))]}"
    }
}

private extension String {
    var jsonQuoted: String {
        let e = self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(e)\""
    }
}
