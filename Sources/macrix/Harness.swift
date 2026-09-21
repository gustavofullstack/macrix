import Foundation

/// MACRIX as the local harness: the coding CLIs installed on this Mac become
/// tools, and Jev picks which one a task deserves.
///
/// Tiers (Gustavo, 21/09/2026): the hardest work goes to Claude Fable, the
/// medium to Opus, the simple to Sonnet, and bulk/cheap to Muse Spark 1.3.
/// Codex and Antigravity are cross-review lanes when their quota is alive.
/// Jev chooses the tier (choice); code builds the argv and runs the process.
/// Prompts travel as argv, never through a shell.
public enum Harness {
    public enum Agent: String, CaseIterable, Sendable {
        case claude_fable, claude_opus, claude_sonnet, codex, antigravity, opencode, muse, goose

        /// Binary basename resolved against the fixed PATH below.
        var binary: String {
            switch self {
            case .claude_fable, .claude_opus, .claude_sonnet: return "claude"
            case .codex: return "codex"
            case .antigravity: return "agy"
            case .opencode: return "opencode"
            case .muse: return "muse"
            case .goose: return "goose"
            }
        }
        public var tier: String {
            switch self {
            case .claude_fable: return "hardest: architecture, verification, decisions that cannot be wrong"
            case .claude_opus: return "medium: multi-file implementation, debugging with evidence"
            case .claude_sonnet: return "simple: focused edits, tests, documentation, repetitive work"
            case .muse: return "cheapest: bulk reading, drafts, first passes (Meta Muse Spark 1.3 community)"
            case .codex: return "cross-review outside Anthropic; quota-bound"
            case .antigravity: return "cross-review with Gemini; quota-bound (429 today)"
            case .opencode: return "compat lane through OmniRoute providers"
            case .goose: return "experimental ACP harness (Block Goose); no provider configured yet"
            }
        }
        /// Headless argv for one prompt. `yolo` adds the CLI's own auto-approve flag.
        public func argv(prompt: String, model: String?, yolo: Bool) -> [String] {
            switch self {
            case .claude_fable, .claude_opus, .claude_sonnet:
                let m = model ?? ["claude_fable": "claude-fable-5-1", "claude_opus": "claude-opus-5",
                                  "claude_sonnet": "claude-sonnet-5"][rawValue]!
                var a = ["-p", prompt, "--output-format", "text", "--model", m]
                if yolo { a.append("--dangerously-skip-permissions") }
                return a
            case .codex:
                var a = ["exec"]
                if let m = model { a += ["-m", m] }
                if yolo { a.append("--full-auto") }
                a.append(prompt); return a
            case .antigravity:
                var a = ["-p", prompt, "--output-format", "text"]
                if let m = model { a += ["--model", m] }
                if yolo { a.append("--dangerously-skip-permissions") }
                return a
            case .opencode:
                var a = ["run"]
                if let m = model { a += ["-m", m] }
                a.append(prompt); return a
            case .muse:
                var a = ["exec", "--reasoning-effort", "low"]
                if let m = model { a += ["--model", m] }
                if yolo { a.append("--yolo") }
                a.append(prompt); return a
            case .goose:
                var a = ["run", "-t", prompt]
                if let m = model { a += ["--model", m] }
                return a
            }
        }
    }

    static let searchPath: [String] = {
        let h = NSHomeDirectory()
        return [h + "/.local/bin", h + "/.opencode/bin", h + "/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    }()

    public static func resolve(_ agent: Agent) -> String? {
        for dir in searchPath {
            let p = dir + "/" + agent.binary
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Workspaces the harness may run in. ponytail: allow-list by prefix; a
    /// per-agent sandbox profile is the upgrade when we let outsiders call this.
    public static func allowedWorkspace(_ path: String) -> String? {
        let p = (path.isEmpty ? NSHomeDirectory() + "/Projetos" : path)
        guard !p.contains(".."), p.hasPrefix("/") else { return nil }
        let std = URL(fileURLWithPath: p).standardizedFileURL.path
        let roots = [NSHomeDirectory() + "/Projetos", NSHomeDirectory() + "/Documents", "/tmp", "/private/tmp"]
        guard roots.contains(where: { std == $0 || std.hasPrefix($0 + "/") }) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: std, isDirectory: &isDir), isDir.boolValue else { return nil }
        return std
    }

    public struct RunResult: Sendable {
        public var agent: Agent; public var argv: [String]; public var exit: Int32
        public var seconds: Double; public var output: String; public var truncated: Bool
    }

    /// Spawn the CLI headless in `workspace`; stdout+stderr bounded to `cap` bytes.
    public static func run(_ agent: Agent, prompt: String, workspace: String, model: String? = nil,
                           yolo: Bool = false, timeout: Double = 300, cap: Int = 20_000) -> Result<RunResult, JevError> {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, p.count <= 20_000 else { return .failure(JevError("prompt empty or over 20000 chars")) }
        guard let bin = resolve(agent) else { return .failure(JevError("\(agent.rawValue): binary \(agent.binary) not installed")) }
        guard let cwd = allowedWorkspace(workspace) else { return .failure(JevError("workspace refused: \(workspace) (allowed: ~/Projetos, ~/Documents, /tmp)")) }
        let argv = agent.argv(prompt: p, model: model, yolo: yolo)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = argv
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        env["CLAUDE_TTS"] = "off"
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe; proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice
        var data = Data(); let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); if data.count < cap * 2 { data.append(d) }; lock.unlock()
        }
        let t0 = Date()
        do { try proc.run() } catch { return .failure(JevError("spawn failed: \(error.localizedDescription)")) }
        let deadline = Date().addingTimeInterval(min(max(timeout, 5), 900))
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        var killed = false
        if proc.isRunning { proc.terminate(); Thread.sleep(forTimeInterval: 1); if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }; killed = true }
        proc.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let all = data; lock.unlock()
        var text = String(decoding: all, as: UTF8.self)
        let truncated = text.utf8.count > cap
        if truncated { text = String(text.suffix(cap)) }
        if killed { text += "\n[macrix: killed after \(Int(timeout))s]" }
        return .success(RunResult(agent: agent, argv: argv, exit: proc.terminationStatus,
                                  seconds: Date().timeIntervalSince(t0), output: text, truncated: truncated))
    }

    public static func listText() -> String {
        Agent.allCases.map { a in
            let path = resolve(a)
            return "\(a.rawValue): \(path == nil ? "ABSENT" : path!) · \(a.tier)"
        }.joined(separator: "\n")
    }

    // MARK: - Jev routing

    /// One Jev choice: which lane deserves this task. Code applies availability.
    public static func routeRequest(task: String, available: [Agent]) -> JSONValue {
        var crit: [String: JSONValue] = [:]
        for a in available { crit[a.rawValue] = .string(a.tier) }
        return .object([
            "model": .string(Voice.model),
            "state": .object(["task": .string(task), "available_agents": .array(available.map { .string($0.rawValue) })]),
            "questions": .object([
                "lane": .object(["type": .string("choice"),
                                 "instructions": .string("Which coding-agent lane should execute this task? Hardest/irreversible work → claude_fable; medium implementation → claude_opus; simple/repetitive → claude_sonnet; bulk cheap drafts/reading → muse. Prefer the cheapest lane that can still do it right."),
                                 "criteria": .object(crit)]),
                "needs_review": .object(["type": .string("noul"),
                                         "instructions": .string("Should the result be cross-reviewed by a second lane before being trusted (touches money, production, security, or deletes data)?")]),
            ]),
        ])
    }

    public struct Route: Equatable, Sendable { public var lane: Agent; public var p: Double; public var review: Double; public var dist: [(String, Double)] }

    public static func parseRoute(_ resp: JSONValue) -> Route? {
        guard let a = resp["answers"]?["lane"], let c = a["choice"]?.string, let lane = Agent(rawValue: c) else { return nil }
        var dist: [(String, Double)] = []
        if case .object(let probs)? = a["probabilities"] { dist = probs.compactMap { k, v in v.double.map { (k, $0) } }.sorted { $0.1 > $1.1 } }
        return Route(lane: lane, p: a["probabilities"]?[c]?.double ?? a["confidence"]?.double ?? 0,
                     review: resp["answers"]?["needs_review"]?["noul"]?.double ?? 0, dist: dist)
    }

    public static func route(task: String, client: JevClient, available: [Agent]) -> Result<Route, JevError> {
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 4000 else { return .failure(JevError("task empty or over 4000 chars")) }
        guard !available.isEmpty else { return .failure(JevError("no agent available")) }
        switch client.evaluate(routeRequest(task: t, available: available)) {
        case .failure(let e): return .failure(JevError("jev: \(e.message)"))
        case .success(let r): return parseRoute(r).map { .success($0) } ?? .failure(JevError("unparseable jev answer"))
        }
    }

    public static func routeText(_ r: Route) -> String {
        let d = r.dist.prefix(4).map { "\($0.0) \(String(format: "%.2f", $0.1))" }.joined(separator: " · ")
        return "lane: \(r.lane.rawValue) (\(String(format: "%.2f", r.p))) · needs_review \(String(format: "%.2f", r.review))\n\(d)"
    }
}

extension Harness.Route {
    public static func == (l: Harness.Route, r: Harness.Route) -> Bool { l.lane == r.lane && l.p == r.p && l.review == r.review }
}

// MARK: - Environment inventory (read-only)

public enum EnvInventory {
    static func count(dir: String) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: dir))?.filter { !$0.hasPrefix(".") }.count ?? 0
    }
    static func json(_ path: String) -> JSONValue? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: d)
    }
    static func keys(_ v: JSONValue?) -> [String] { if case .object(let o)? = v { return o.keys.sorted() }; return [] }

    /// Everything the agents on this Mac can use, counted from the real files.
    /// Names only (no values): configs carry tokens.
    public static func report() -> String {
        let h = NSHomeDirectory()
        var out: [String] = []
        let cj = json(h + "/.claude.json")
        out.append("mcp_servers (claude): \(keys(cj?["mcpServers"]).count) → \(keys(cj?["mcpServers"]).joined(separator: ", "))")
        out.append("skills ~/.claude/skills: \(count(dir: h + "/.claude/skills")) · ~/.agents/skills: \(count(dir: h + "/.agents/skills"))")
        out.append("commands ~/.claude/commands: \(count(dir: h + "/.claude/commands"))")
        let plugins = json(h + "/.claude/plugins/installed_plugins.json")
        var np = 0
        if case .object(let o)? = plugins { if case .object(let p)? = o["plugins"] { np = p.count } else { np = o.count } }
        out.append("plugins (claude): \(np)")
        let settings = json(h + "/.claude/settings.json")
        if case .object(let hooks)? = settings?["hooks"] {
            out.append("hooks (claude): " + hooks.map { k, v in "\(k)=\((v.arrayCount))" }.sorted().joined(separator: " "))
        }
        let oc = json(h + "/.opencode/opencode.json")
        out.append("opencode agents: \(keys(oc?["agent"]).count) · mcp: \(keys(oc?["mcp"]).count) · providers: \(keys(oc?["provider"]).count)")
        let codexProfiles = (try? FileManager.default.contentsOfDirectory(atPath: h + "/.codex"))?.filter { $0.hasSuffix(".config.toml") }.count ?? 0
        out.append("codex model profiles: \(codexProfiles)")
        out.append("muse bundled skills: \(count(dir: h + "/.local/share/muse/skills/bundled/muse-core/skills"))")
        out.append("agents: " + Harness.Agent.allCases.map { "\($0.rawValue)=\(Harness.resolve($0) == nil ? "absent" : "ok")" }.joined(separator: " "))
        return out.joined(separator: "\n")
    }
}

extension JSONValue {
    var arrayCount: Int { if case .array(let a) = self { return a.count }; return 0 }
}
