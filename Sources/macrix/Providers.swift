import Foundation

/// CodexBar-style local readers: summarize each AI CLI's on-disk activity
/// (sessions, events, bytes, recency). Read-only; never parses credentials,
/// never ships content anywhere — counts and timestamps only.
public struct ProviderDef: Sendable {
    public let name: String
    public let root: String   // may contain ~
    public let fileExt: String?  // e.g. "jsonl"; nil = count entries
    public let fileName: String? // exact basename match (single file)
    public init(name: String, root: String, fileExt: String? = nil, fileName: String? = nil) {
        self.name = name; self.root = root; self.fileExt = fileExt; self.fileName = fileName
    }
}

public enum Providers {
    public static let defs: [ProviderDef] = [
        ProviderDef(name: "codex", root: "~/.codex/sessions", fileExt: "jsonl"),
        ProviderDef(name: "claude", root: "~/.claude/projects", fileExt: "jsonl"),
        ProviderDef(name: "muse", root: "~/.local/share/muse/sessions", fileName: "session.jsonl"),
        ProviderDef(name: "cursor", root: "~/.cursor/acp-sessions"),
        ProviderDef(name: "antigravity", root: "~/.gemini/antigravity-cli", fileName: "history.jsonl"),
        ProviderDef(name: "opencode-log", root: "~/.local/share/opencode/log"),
        ProviderDef(name: "gemini-history", root: "~/.gemini/history"),
    ]

    public struct Summary: Sendable {
        public let name: String
        public let sessions: Int
        public let events: Int
        public let bytes: Int
        public let lastActive: Date?
    }

    /// Scan with hard caps so a giant log dir can't stall a tool call.
    public static func scan(_ def: ProviderDef, maxFiles: Int = 300,
                            maxBytesPerFile: Int = 4 << 20) -> Summary {
        let root = (def.root as NSString).expandingTildeInPath
        var files: [URL] = []
        if let exact = def.fileName {
            let cand = URL(fileURLWithPath: root).appendingPathComponent(exact)
            if FileManager.default.isReadableFile(atPath: cand.path) { files = [cand] }
            // also allow nested match for muse-style sharded trees
            if files.isEmpty, def.name == "muse" {
                files = find(basename: exact, under: root, maxFiles: maxFiles)
            }
        } else if let ext = def.fileExt {
            files = find(ext: ext, under: root, maxFiles: maxFiles)
        } else {
            files = listEntries(under: root, maxFiles: maxFiles)
        }
        var events = 0, bytes = 0
        var latest: Date?
        for url in files.prefix(maxFiles) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            let size = (attrs[.size] as? Int) ?? 0
            bytes += size
            if let m = attrs[.modificationDate] as? Date, latest == nil || m > latest! { latest = m }
            if def.fileExt == "jsonl" || def.fileName?.hasSuffix(".jsonl") == true {
                events += countLines(url: url, cap: maxBytesPerFile)
            }
        }
        let sessions: Int
        if def.fileName != nil && def.name != "muse" {
            sessions = files.isEmpty ? 0 : 1
        } else if def.fileExt == nil && def.fileName == nil {
            sessions = files.count  // dirs / log files as activity units
        } else {
            sessions = files.count
        }
        return Summary(name: def.name, sessions: sessions, events: events,
                       bytes: bytes, lastActive: latest)
    }

    static func find(ext: String, under root: String, maxFiles: Int) -> [URL] {
        find(under: root, maxFiles: maxFiles) { $0.pathExtension == ext }
    }
    static func find(basename: String, under root: String, maxFiles: Int) -> [URL] {
        find(under: root, maxFiles: maxFiles) { $0.lastPathComponent == basename }
    }
    static func find(under root: String, maxFiles: Int,
                     match: (URL) -> Bool = { _ in true }) -> [URL] {
        var out: [URL] = []
        guard let items = FileManager.default.enumerator(atPath: root) else { return out }
        for case let rel as String in items {
            if out.count >= maxFiles * 4 { break }  // enumeration guard
            let url = URL(fileURLWithPath: root).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  !isDir.boolValue, match(url) else { continue }
            out.append(url)
            if out.count >= maxFiles { break }
        }
        return out
    }
    static func listEntries(under root: String, maxFiles: Int) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return names.prefix(maxFiles).map { URL(fileURLWithPath: root).appendingPathComponent($0) }
    }

    static func countLines(url: URL, cap: Int) -> Int {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? fh.close() }
        var count = 0, total = 0
        while total < cap, let chunk = try? fh.read(upToCount: 1 << 16), !chunk.isEmpty {
            total += chunk.count
            count += chunk.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        }
        return count
    }

    public static func report() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        let lines = defs.map { def -> String in
            let s = scan(def)
            let mb = String(format: "%.1fMB", Double(s.bytes) / 1_048_576.0)
            let last = s.lastActive.map { df.string(from: $0) } ?? "-"
            return "- \(s.name): \(s.sessions) sessions, \(s.events) events, \(mb), last \(last)"
        }
        return lines.joined(separator: "\n")
    }
}
