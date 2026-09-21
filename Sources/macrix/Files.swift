import Foundation

/// G1 files family: scoped file access for agents. Reads capped at 100KB.
/// Writes restricted to /tmp (any name) — never outside. Listings restricted
/// to /tmp and the user's project dirs. Secret paths are refused outright.
public enum Files {
    static let deniedSubstrings = [
        ".ssh", ".gnupg", "credenciais.env", ".env", "id_rsa", "id_ed25519",
        ".vault", "keychain", "Secrets", ".pyc", ".secrets",
    ]
    static func denied(_ path: String) -> Bool {
        // Case-insensitive: APFS is usually case-insensitive, so ".SSH"
        // must match ".ssh" — compare lowered on both sides.
        let lower = path.lowercased()
        return deniedSubstrings.contains { lower.contains($0.lowercased()) }
    }
    static func read(_ path: String) -> String {
        if denied(path) { return "refused: secret-adjacent path." }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url), data.count <= (100 << 10) else {
            return "unreadable or over 100KB."
        }
        return String(data: data, encoding: .utf8) ?? "not UTF-8 text."
    }
    static func write(name: String, content: String) -> String {
        guard !name.contains("/"), !name.isEmpty, name.count < 128,
              content.count <= (100 << 10), !denied(name) else {
            return "refused: bare filename in /tmp, max 100KB."
        }
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return "wrote \(url.path) (\(content.count) chars)"
        } catch {
            return "write failed."
        }
    }
    static func list(_ dir: String) -> String {
        let expanded = (dir as NSString).expandingTildeInPath
        let home = NSHomeDirectory()
        let ok = expanded == "/tmp" || expanded.hasPrefix("/tmp/") ||
            expanded.hasPrefix(home + "/Documents/PROJETOS/") ||
            expanded.hasPrefix(home + "/Projetos/")
        guard ok else { return "refused: only /tmp and PROJETOS subtrees." }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: expanded) else {
            return "unlistable."
        }
        return names.prefix(50).joined(separator: "\n")
    }
}
