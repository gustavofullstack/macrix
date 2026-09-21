import Foundation

/// v0.20 media family (G1): image inspect/resize/convert via sips,
/// audio probe via afinfo. Reads honor Files.denied; every output
/// lands in /tmp. No playback, no sound (house voice-off rule).
public enum Media {
    static func imgInfo(_ path: String) -> String {
        let p = Git.expand(path)
        guard !p.isEmpty, FileManager.default.fileExists(atPath: p) else { return "missing file." }
        if Files.denied(path) { return "refused: secret-adjacent path." }
        let (code, out) = runProcess("/usr/bin/sips",
            ["-g", "pixelWidth", "-g", "pixelHeight", "-g", "format", p], timeoutSeconds: 30)
        guard code == 0 else { return "not a readable image." }
        return String(out.prefix(4000))
    }

    static func imgResize(_ path: String, maxSide: Int) -> String {
        let p = Git.expand(path)
        guard !p.isEmpty, FileManager.default.fileExists(atPath: p) else { return "missing file." }
        if Files.denied(path) { return "refused: secret-adjacent path." }
        let m = min(max(maxSide, 16), 4096)
        let stem = URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_").prefix(60)
        let dest = "/tmp/macrix_img_\(m)_\(stem).png"
        let (code, _) = runProcess("/usr/bin/sips",
            ["-Z", String(m), "-s", "format", "png", p, "--out", dest], timeoutSeconds: 120)
        guard code == 0, FileManager.default.fileExists(atPath: dest) else {
            return "resize failed (not an image?)."
        }
        return "resized: \(dest)"
    }

    static func imgConvert(_ path: String, format: String) -> String {
        let p = Git.expand(path)
        guard !p.isEmpty, FileManager.default.fileExists(atPath: p) else { return "missing file." }
        if Files.denied(path) { return "refused: secret-adjacent path." }
        let fmt = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["png", "jpeg", "tiff"].contains(fmt) else { return "format must be png, jpeg, or tiff." }
        let ext = fmt == "jpeg" ? "jpg" : fmt
        let stem = URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_").prefix(60)
        let dest = "/tmp/macrix_conv_\(stem).\(ext)"
        let (code, _) = runProcess("/usr/bin/sips",
            ["-s", "format", fmt, p, "--out", dest], timeoutSeconds: 120)
        guard code == 0, FileManager.default.fileExists(atPath: dest) else {
            return "convert failed (not an image?)."
        }
        return "converted: \(dest)"
    }

    static func audioInfo(_ path: String) -> String {
        let p = Git.expand(path)
        guard !p.isEmpty, FileManager.default.fileExists(atPath: p) else { return "missing file." }
        if Files.denied(path) { return "refused: secret-adjacent path." }
        let (code, out) = runProcess("/usr/bin/afinfo", ["-b", p], timeoutSeconds: 30)
        guard code == 0 else { return "not a readable audio file." }
        return String(out.prefix(4000))
    }
}
