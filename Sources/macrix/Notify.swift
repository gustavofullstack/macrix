import Foundation

/// G1 notify/voice family: user-visible notification, speech, and quitting
/// a NAMED app (the only writer; exact name only, no bundles/paths).
public enum Notify {
    static func send(title: String, body: String) -> String {
        let t = title.prefix(100).replacingOccurrences(of: "\"", with: "")
        let b = body.prefix(300).replacingOccurrences(of: "\"", with: "")
        guard !t.isEmpty else { return "missing title." }
        let (code, _) = runProcess("/usr/bin/osascript",
            ["-e", "display notification \"\(b)\" with title \"\(t)\""], timeoutSeconds: 20)
        return code == 0 ? "notified" : "notification failed."
    }
    /// Render speech to a file — NEVER to speakers (house voice-off order).
    static func render(_ text: String, voice: String?) -> String {
        let t = text.prefix(500)
        guard !t.isEmpty else { return "missing text." }
        var args = ["-r", "180"]
        if let v = voice, !v.isEmpty, v.count < 64,
           v.range(of: "^[A-Za-z ]+$", options: .regularExpression) != nil {
            args += ["-v", v]
        }
        let path = "/tmp/macrix_tts_\(Int(Date().timeIntervalSince1970)).aiff"
        let (code, _) = runProcess("/usr/bin/say", args + ["-o", path, String(t)], timeoutSeconds: 120)
        guard code == 0, FileManager.default.fileExists(atPath: path) else {
            return "speech render failed."
        }
        return "audio: \(path)"
    }
    static func quitApp(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count < 128, !n.contains("\""), !n.contains("/") else {
            return "refused: exact app name only."
        }
        let (code, _) = runProcess("/usr/bin/osascript",
            ["-e", "tell application \"\(n)\" to quit"], timeoutSeconds: 30)
        return code == 0 ? "quit \(n)" : "quit failed (not running?)."
    }
}
