import Foundation

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
}
