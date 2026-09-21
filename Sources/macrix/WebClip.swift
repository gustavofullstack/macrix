import Foundation

/// v0.16 web-fetch + clipboard-read + open family (G1).
/// http(s) only. Fetch capped at 1MB. Downloads land in ~/Downloads only.
public enum WebClip {
    static let maxBytes = 1_000_000

    static func fetch(_ url: String) -> String {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let s = u.scheme?.lowercased(), s == "http" || s == "https"
        else { return "refused: http(s) url only." }
        let (code, out) = runProcess("/usr/bin/curl",
            ["-sSL", "--max-time", "30", "--max-filesize", String(maxBytes), url], timeoutSeconds: 40)
        guard code == 0 else { return "fetch failed." }
        return String(out.prefix(maxBytes))
    }

    static func download(_ url: String, name: String?) -> String {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let s = u.scheme?.lowercased(), s == "http" || s == "https"
        else { return "refused: http(s) url only." }
        var fname = (name ?? u.lastPathComponent).replacingOccurrences(of: "/", with: "_")
        fname = fname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fname.isEmpty, fname.count < 128 else { return "need a filename (pass name)." }
        let dest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads").appendingPathComponent(fname).path
        let (code, _) = runProcess("/usr/bin/curl",
            ["-sSL", "--max-time", "120", "--max-filesize", "104857600", "-o", dest, url], timeoutSeconds: 130)
        guard code == 0, FileManager.default.fileExists(atPath: dest) else { return "download failed." }
        return "saved: \(dest)"
    }

    static func clipGet() -> String {
        let (_, out) = runProcess("/usr/bin/pbpaste", [], timeoutSeconds: 10)
        return out.isEmpty ? "(empty)" : String(out.prefix(100_000))
    }

    static func open(_ url: String) -> String {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let s = u.scheme?.lowercased(), s == "http" || s == "https"
        else { return "refused: http(s) url only." }
        let (code, _) = runProcess("/usr/bin/open", [url], timeoutSeconds: 20)
        return code == 0 ? "opened" : "open failed."
    }
}
