import Foundation

/// v0.19 archive family (G1): zip create/list/extract via system zip/unzip.
/// Extracts land in /tmp only (zip-slip safe: basenames only). 100MB cap.
public enum Archive {
    static func create(zipName: String, paths: [String]) -> String {
        let name = zipName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count < 128, !name.contains("/"), name.hasSuffix(".zip"),
              !paths.isEmpty, paths.count <= 20 else {
            return "need a .zip bare name + 1-20 source paths."
        }
        for p in paths {
            if Files.denied(p) { return "refused: secret-adjacent path." }
            guard FileManager.default.fileExists(atPath: Git.expand(p)) else {
                return "missing: \(p)"
            }
        }
        let dest = "/tmp/\(name)"
        try? FileManager.default.removeItem(atPath: dest)
        let expanded = paths.map { Git.expand($0) }
        let (code, err) = runProcess("/usr/bin/zip", ["-qr", dest] + expanded, timeoutSeconds: 120)
        guard code == 0, FileManager.default.fileExists(atPath: dest) else {
            return "zip failed: \(err.prefix(300))"
        }
        return "zipped: \(dest)"
    }

    static func list(_ zipPath: String) -> String {
        let p = Git.expand(zipPath)
        guard p.hasSuffix(".zip"), FileManager.default.fileExists(atPath: p) else {
            return "need an existing .zip path."
        }
        if Files.denied(zipPath) { return "refused: secret-adjacent path." }
        let (code, out) = runProcess("/usr/bin/unzip", ["-l", p], timeoutSeconds: 30)
        guard code == 0 else { return "unzip -l failed." }
        return String(out.prefix(100_000))
    }

    static func extract(_ zipPath: String) -> String {
        let p = Git.expand(zipPath)
        guard p.hasSuffix(".zip"), FileManager.default.fileExists(atPath: p) else {
            return "need an existing .zip path."
        }
        if Files.denied(zipPath) { return "refused: secret-adjacent path." }
        let dir = "/tmp/macrix_unzip_\(Int(Date().timeIntervalSince1970))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // -j junk paths: every entry lands flat in dir, no traversal possible.
        let (code, err) = runProcess("/usr/bin/unzip", ["-q", "-j", "-o", p, "-d", dir], timeoutSeconds: 120)
        guard code == 0 else { return "extract failed: \(err.prefix(300))" }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return "extracted \(items.count) file(s) to \(dir)"
    }
}

/// v0.19 text family (G1): stats, CSV head, literal grep — all on top of
/// Files.read, so secret-path refusal and caps come for free.
public enum TextUtil {
    static func stats(_ path: String) -> String {
        let body = Files.read(path)
        if body.hasPrefix("refused") { return body }
        let lines = body.components(separatedBy: "\n").count
        let words = body.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        return "lines=\(lines) words=\(words) bytes=\(body.utf8.count)"
    }

    static func csvHead(_ path: String, n: Int) -> String {
        let body = Files.read(path)
        if body.hasPrefix("refused") { return body }
        let rows = body.components(separatedBy: "\n").prefix(min(max(n, 1), 20))
        return rows.joined(separator: "\n")
    }

    static func grep(_ path: String, pattern: String) -> String {
        let body = Files.read(path)
        if body.hasPrefix("refused") { return body }
        let pat = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pat.isEmpty, pat.count <= 200 else { return "need a literal pattern (max 200)." }
        let hits = body.components(separatedBy: "\n").filter { $0.localizedCaseInsensitiveContains(pat) }
        guard !hits.isEmpty else { return "(no matches)" }
        return String(hits.prefix(50).joined(separator: "\n").prefix(100_000))
    }
}
