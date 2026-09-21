import Foundation
import CryptoKit

/// v0.21 probe family (G1): uptime/load, memory, listening ports,
/// markdown headings, plist dump, launchd jobs. All read-only;
/// file inputs honor Files.denied.
public enum Probe {
    static func uptime() -> String {
        let (code, out) = runProcess("/usr/bin/uptime", [], timeoutSeconds: 15)
        guard code == 0 else { return "uptime unavailable." }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func mem() -> String {
        let (code, out) = runProcess("/usr/bin/vm_stat", [], timeoutSeconds: 15)
        guard code == 0 else { return "memory stats unavailable." }
        return String(out.split(separator: "\n").prefix(12).joined(separator: "\n"))
    }

    static func ports() -> String {
        let (code, out) = runProcess("/usr/sbin/lsof",
            ["-iTCP", "-sTCP:LISTEN", "-P", "-n"], timeoutSeconds: 30)
        guard code == 0 else { return "port list unavailable." }
        let lines = out.split(separator: "\n").prefix(21)
        return lines.isEmpty ? "(no listening TCP ports)" : lines.joined(separator: "\n")
    }

    static func headings(_ path: String) -> String {
        let body = Files.read(path)
        if body.hasPrefix("refused") { return body }
        let heads = body.components(separatedBy: "\n").filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("#")
        }
        guard !heads.isEmpty else { return "(no headings)" }
        return String(heads.prefix(100).joined(separator: "\n").prefix(100_000))
    }

    static func plist(_ path: String) -> String {
        let p = Git.expand(path)
        guard !p.isEmpty, FileManager.default.fileExists(atPath: p) else { return "missing file." }
        if Files.denied(path) { return "refused: secret-adjacent path." }
        let (code, out) = runProcess("/usr/bin/plutil", ["-p", p], timeoutSeconds: 30)
        guard code == 0 else { return "not a plist." }
        return String(out.prefix(100_000))
    }

    static func launchd() -> String {
        let (code, out) = runProcess("/bin/launchctl", ["list"], timeoutSeconds: 20)
        guard code == 0 else { return "launchctl unavailable." }
        return String(out.split(separator: "\n").prefix(41).joined(separator: "\n"))
    }

    static func fileHash(_ path: String) -> String {
        let p = Git.expand(path)
        guard !p.isEmpty, FileManager.default.fileExists(atPath: p) else { return "missing file." }
        if Files.denied(path) { return "refused: secret-adjacent path." }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)), data.count <= 100_000_000 else {
            return "unreadable or over 100MB."
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func dirSize(_ dir: String) -> String {
        let p = Git.expand(dir)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let ok = p == "/tmp" || p.hasPrefix("/tmp/") || p.hasPrefix(home + "/Documents/PROJETOS/")
        guard ok else { return "refused: only /tmp and PROJETOS subtrees." }
        let (code, out) = runProcess("/usr/bin/du", ["-sh", p], timeoutSeconds: 60)
        guard code == 0 else { return "du failed." }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hostName() -> String {
        let (code, out) = runProcess("/usr/sbin/scutil", ["--get", "ComputerName"], timeoutSeconds: 10)
        guard code == 0 else { return "hostname unavailable." }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plistGet(_ path: String, key: String) -> String {
        let p = Git.expand(path)
        guard !p.isEmpty, FileManager.default.fileExists(atPath: p) else { return "missing file." }
        if Files.denied(path) { return "refused: secret-adjacent path." }
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, k.count <= 200, k.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil else {
            return "need a dot-separated key (letters/digits/._)."
        }
        let (code, out) = runProcess("/usr/bin/plutil",
            ["-extract", k, "json", "-o", "-", p], timeoutSeconds: 30)
        guard code == 0 else { return "key not found (or not a plist)." }
        return String(out.prefix(100_000))
    }

    static func tailscale() -> String {
        let ts = NSHomeDirectory() + "/.local/bin/tailscale"
        guard FileManager.default.isExecutableFile(atPath: ts) else { return "tailscale cli missing." }
        let (code, out) = runProcess(ts, ["status"], timeoutSeconds: 20)
        guard code == 0 else { return "tailscale status failed." }
        return String(out.split(separator: "\n").prefix(21).joined(separator: "\n").prefix(8000))
    }
}
