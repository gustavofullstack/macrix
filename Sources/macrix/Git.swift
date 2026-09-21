import Foundation

/// v0.17 git read-only family (G1): status/log/diffstat inside a local repo.
/// No writes, no fetches, no pushes — read-only flags only. Output capped.
public enum Git {
    static let cap = 100_000

    static func repoRoot(_ path: String) -> String? {
        let p = expand(path)
        guard !p.isEmpty else { return nil }
        let (code, out) = runProcess("/usr/bin/git", ["-C", p, "rev-parse", "--show-toplevel"], timeoutSeconds: 15)
        guard code == 0 else { return nil }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func status(_ path: String) -> String {
        guard let root = repoRoot(path) else { return "not a git repo." }
        let (code, out) = runProcess("/usr/bin/git", ["-C", root, "status", "--short", "--branch"], timeoutSeconds: 20)
        guard code == 0 else { return "git status failed." }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((t.isEmpty ? "(clean)" : t).prefix(cap))
    }

    static func log(_ path: String, n: Int) -> String {
        guard let root = repoRoot(path) else { return "not a git repo." }
        let count = min(max(n, 1), 30)
        let (code, out) = runProcess("/usr/bin/git",
            ["-C", root, "log", "--oneline", "-n", String(count)], timeoutSeconds: 20)
        guard code == 0 else { return "git log failed." }
        return String(out.prefix(cap))
    }

    static func diffstat(_ path: String) -> String {
        guard let root = repoRoot(path) else { return "not a git repo." }
        let (code, out) = runProcess("/usr/bin/git",
            ["-C", root, "diff", "--stat"], timeoutSeconds: 20)
        guard code == 0 else { return "git diff failed." }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((t.isEmpty ? "(no changes)" : t).prefix(cap))
    }

    static func expand(_ path: String) -> String {
        let t = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + t.dropFirst(1)
        }
        return t
    }
}
