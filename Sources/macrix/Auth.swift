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

    /// Load keys from `MACRIX_KEYS` (comma-separated, legacy `MACUSE_OPEN_KEYS`
    /// still honored) plus one-per-line files at `~/.config/macrix/keys`
    /// (legacy `~/.config/macuse-open/keys` still honored).
    public static func loadKeys() -> Set<String> {
        var out = Set<String>()
        let env = ProcessInfo.processInfo.environment
        for varName in ["MACRIX_KEYS", "MACUSE_OPEN_KEYS"] {
            if let val = env[varName] {
                for part in val.split(separator: ",") {
                    let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { out.insert(t) }
                }
            }
        }
        for dotfile in [MacrixPaths.home + "/keys", "~/.config/macuse-open/keys"] {
            let path = (dotfile as NSString).expandingTildeInPath
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                for line in content.components(separatedBy: .newlines) {
                    let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty && !t.hasPrefix("#") { out.insert(t) }
                }
            }
        }
        return out
    }
}