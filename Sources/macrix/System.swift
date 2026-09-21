import Foundation

/// G1 system family: read-only macOS introspection plus `sys_open`
/// (opens an explicit user-supplied URL/app — the only writer, and it only
/// does what the caller names). All data comes from system CLIs.
public enum Sys {
    static func info() -> String {
        let (c1, hw) = runProcess("/usr/sbin/sysctl", ["-n", "hw.model", "hw.ncpu", "hw.memsize", "kern.osrelease"])
        let (c2, ver) = runProcess("/usr/bin/sw_vers", ["-productVersion"])
        guard c1 == 0 else { return "system info unavailable." }
        let parts = hw.components(separatedBy: "\n").filter { !$0.isEmpty }
        return "model=\(parts.first ?? "?") cpus=\(parts.count > 1 ? parts[1] : "?") " +
            "mem=\(parts.count > 2 ? parts[2] : "?") kernel=\(parts.count > 3 ? parts[3] : "?") " +
            "macos=\(ver.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
    static func battery() -> String {
        let (code, out) = runProcess("/usr/bin/pmset", ["-g", "batt"])
        guard code == 0 else { return "battery info unavailable." }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func volume() -> String {
        let (code, out) = runProcess("/usr/bin/osascript", ["-e", "output volume of (get volume settings)"])
        guard code == 0 else { return "volume unavailable." }
        return "output volume: \(out.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
    static func wifi() -> String {
        let (code, out) = runProcess("/usr/sbin/networksetup", ["-getairportnetwork", "en0"])
        guard code == 0 else { return "wifi info unavailable." }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func clipboard() -> String {
        let (code, out) = runProcess("/usr/bin/pbpaste", [])
        guard code == 0 else { return "clipboard unreadable." }
        let t = out.prefix(500)
        return t.isEmpty ? "clipboard empty." : String(t)
    }
    static func procs() -> String {
        let (code, out) = runProcess("/bin/ps", ["-axo", "pid,pcpu,comm", "-r"])
        guard code == 0 else { return "process list unavailable." }
        return out.split(separator: "\n").prefix(21).joined(separator: "\n")
    }
    static func disk() -> String {
        let (code, out) = runProcess("/bin/df", ["-h", "/"])
        guard code == 0 else { return "disk info unavailable." }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func openTarget(_ target: String) -> String {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 2000,
              t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("/") ||
              t.hasSuffix(".app") || !t.contains(" ") else {
            return "refused: target must be an http(s) URL, absolute path, or .app name."
        }
        let (code, _) = runProcess("/usr/bin/open", [t])
        return code == 0 ? "opened \(t)" : "open failed (exit \(code))."
    }
}
