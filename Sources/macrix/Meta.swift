import Foundation

/// G1 spotlight family: file metadata (mdls) and content search (mdfind),
/// both read-only and capped. Paths refused by the same Files denylist.
public enum Meta {
    static func read(_ path: String) -> String {
        if Files.denied(path) { return "refused: secret-adjacent path." }
        let p = (path as NSString).expandingTildeInPath
        let (code, out) = runProcess("/usr/bin/mdls", [p], timeoutSeconds: 20)
        guard code == 0, !out.isEmpty else { return "no metadata." }
        let lines = out.split(separator: "\n").prefix(30)
        return lines.joined(separator: "\n")
    }
    static func search(_ query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count < 256 else { return "invalid query." }
        let (code, out) = runProcess("/usr/bin/mdfind", [q], timeoutSeconds: 30)
        guard code == 0 else { return "search failed." }
        let hits = out.split(separator: "\n").filter { !Files.denied(String($0)) }.prefix(20)
        return hits.isEmpty ? "no matches." : hits.joined(separator: "\n")
    }
}
