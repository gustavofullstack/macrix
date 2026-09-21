import Foundation

/// G5 web family: headless Chromium via the Playwright-cached binaries
/// (no Node/npx needed — the node-based playwright-cli skill can't run on
/// this machine, so the server shells chrome-headless-shell directly).
/// URLs restricted to http(s); output capped.
public enum Web {
    static func browser() -> String? {
        let cands = [
            ("~/Library/Caches/ms-playwright/chromium_headless_shell-1243/chrome-headless-shell-mac-arm64/chrome-headless-shell" as NSString).expandingTildeInPath,
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        ]
        return cands.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func validURL(_ s: String) -> Bool {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty, s.count < 2000 else { return false }
        return true
    }

    static func shot(url: String) -> String {
        guard validURL(url), let bin = browser() else {
            return "web unavailable: need an http(s) URL and a Chromium binary."
        }
        let path = "/tmp/macrix_web_\(Int(Date().timeIntervalSince1970)).png"
        let (code, _) = runProcess(bin, ["--no-sandbox", "--disable-gpu",
            "--screenshot=\(path)", "--window-size=1280,800", "--virtual-time-budget=15000", url],
            timeoutSeconds: 90)
        guard code == 0, FileManager.default.fileExists(atPath: path) else {
            return "screenshot failed."
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        return "screenshot: \(path) (\(size) bytes)"
    }

    static func text(url: String) -> String {
        guard validURL(url), let bin = browser() else {
            return "web unavailable: need an http(s) URL and a Chromium binary."
        }
        let (code, out) = runProcess(bin, ["--no-sandbox", "--disable-gpu",
            "--dump-dom", "--virtual-time-budget=15000", url], timeoutSeconds: 90)
        guard code == 0, !out.isEmpty else { return "fetch failed." }
        var t = out
        t = t.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let collapsed = t.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        return String(collapsed.prefix(4000))
    }

    static func pdf(url: String) -> String {
        guard validURL(url), let bin = browser() else {
            return "web unavailable: need an http(s) URL and a Chromium binary."
        }
        let path = "/tmp/macrix_web_\(Int(Date().timeIntervalSince1970)).pdf"
        let (code, _) = runProcess(bin, ["--no-sandbox", "--disable-gpu",
            "--print-to-pdf=\(path)", "--virtual-time-budget=15000", url],
            timeoutSeconds: 90)
        guard code == 0, FileManager.default.fileExists(atPath: path) else {
            return "pdf failed."
        }
        return "pdf: \(path)"
    }
}
