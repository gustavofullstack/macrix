import Foundation

/// Bearer multi-key auth. No rate limits, no per-client exclusivity:
/// any valid key works concurrently with any other.
public enum Auth {
    /// Extract the token from an `Authorization: Bearer <token>` header value.
    public static func token(from headerValue: String?) -> String? {
        guard let h = headerValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              h.count > 7,
              h.prefix(7).lowercased() == "bearer " else { return nil }
        let tok = h.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
        return tok.isEmpty ? nil : String(tok)
    }

    public static func isAuthorized(headerValue: String?, keys: Set<String>) -> Bool {
        guard let tok = token(from: headerValue) else { return false }
        return keys.contains(tok)
    }

    /// Load keys from `MACUSE_OPEN_KEYS` (comma-separated) plus one-per-line
    /// file at `~/.config/macuse-open/keys` (`#` comments allowed).
    public static func loadKeys() -> Set<String> {
        var out = Set<String>()
        if let env = ProcessInfo.processInfo.environment["MACUSE_OPEN_KEYS"] {
            for part in env.split(separator: ",") {
                let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.insert(t) }
            }
        }
        let path = ("~/.config/macuse-open/keys" as NSString).expandingTildeInPath
        if let content = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && !t.hasPrefix("#") { out.insert(t) }
            }
        }
        return out
    }
}
