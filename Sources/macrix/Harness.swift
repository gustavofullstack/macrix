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
        if proc.isRunning {
            _ = runProcess("/usr/bin/pkill", ["-TERM", "-P", String(proc.processIdentifier)], timeoutSeconds: 3)
            proc.terminate(); Thread.sleep(forTimeInterval: 1)
            if proc.isRunning { _ = runProcess("/usr/bin/pkill", ["-KILL", "-P", String(proc.processIdentifier)], timeoutSeconds: 3); kill(proc.processIdentifier, SIGKILL) }
            killed = true
        }
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

// MARK: - Journey: one task, one id, every step on record (ChatGPT task 5)

public enum Journey {
    /// route (Jev) → gate → run → ledger, all tagged with `journeyId`.
    /// Returns a human log; the ledger line carries the machine record.
    public static func run(task: String, journeyId: String, workspace: String, client: JevClient, gate: HarnessGate,
                           available: [Harness.Agent], yolo: Bool = false, timeout: Double = 300,
                           runner: (Harness.Agent, String, String, Bool, Double) -> Result<Harness.RunResult, JevError> = { a, p, w, y, to in Harness.run(a, prompt: p, workspace: w, yolo: y, timeout: to) }) -> String {
        let id = journeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            return "journey refused: journey_id must match [A-Za-z0-9][A-Za-z0-9_-]{0,63}"
        }
        var log = ["journey \(id)"]
        let route: Harness.Route
        switch Harness.route(task: task, client: client, available: available) {
        case .failure(let e): return (log + ["1 route: \(e.message)", "outcome: blocked_at_route"]).joined(separator: "\n")
        case .success(let r): route = r
        }
        log.append("1 route (jev): " + Harness.routeText(route).replacingOccurrences(of: "\n", with: " · "))
        if HarnessGate.touchesProduction(task) {
            log.append("2 authorization: task names a production marker → blocked by default (no approval path)")
            return (log + ["outcome: blocked_production"]).joined(separator: "\n")
        }
        if route.review >= 0.70 {
            let a = gate.issueApproval(journeyId: id, lane: route.lane, task: task)
            log.append("2 authorization: needs_review \(String(format: "%.2f", route.review)) ≥ 0.70 → prepared, not executed")
            log.append("   approval token issued (single use, expires \(ISO8601DateFormatter().string(from: a.expires))): \(a.token)")
            log.append("   to execute exactly this task on \(a.lane.rawValue): journey_approve {journey_id, token, task}")
            return (log + ["outcome: needs_human_review"]).joined(separator: "\n")
        }
        if let refusal = gate.admit(route.lane, opId: id) {
            log.append("2 gate: refused \(refusal)")
            return (log + ["outcome: refused_by_gate"]).joined(separator: "\n")
        }
        log.append("2 authorization: lane \(route.lane.rawValue) admitted, op_id=\(id)")
        let result = runner(route.lane, task, workspace, yolo, timeout)
        let status = gate.settle(route.lane, opId: id, result: result)
        switch result {
        case .failure(let e): log.append("3 execute: \(e.message)")
        case .success(let r): log.append("3 execute: exit \(r.exit) · \(String(format: "%.1f", r.seconds)) s · \(r.output.count) chars")
        }
        log.append("4 reconcile: execution_status=\(status) · cost_status=unknown (no provider meter for CLIs yet)")
        log.append("5 evidence: ledger \(gate.ledgerPath) (op_id=\(id))")
        log.append("outcome: \(status == "settled" ? "completed" : status)")
        return log.joined(separator: "\n")
    }
}

extension Journey {
    /// Second half of a reviewed journey: same id, same task text, one token, one use.
    public static func approve(journeyId: String, token: String, task: String, workspace: String, gate: HarnessGate, yolo: Bool = false, timeout: Double = 300,
                               runner: (Harness.Agent, String, String, Bool, Double) -> Result<Harness.RunResult, JevError> = { a, p, w, y, to in Harness.run(a, prompt: p, workspace: w, yolo: y, timeout: to) }) -> String {
        var log = ["journey \(journeyId) (approved run)"]
        if HarnessGate.touchesProduction(task) { return (log + ["authorization: production marker → blocked even with a token", "outcome: blocked_production"]).joined(separator: "\n") }
        let lane: Harness.Agent
        switch gate.consumeApproval(journeyId: journeyId, token: token, task: task) {
        case .ok(let l): lane = l; log.append("1 approval: valid, consumed (single use)")
        case .missing: return (log + ["1 approval: none issued for this journey", "outcome: refused_no_approval"]).joined(separator: "\n")
        case .expired: return (log + ["1 approval: expired", "outcome: refused_expired"]).joined(separator: "\n")
        case .used: return (log + ["1 approval: already used", "outcome: refused_used"]).joined(separator: "\n")
        case .wrongToken: return (log + ["1 approval: token mismatch", "outcome: refused_token"]).joined(separator: "\n")
        case .taskChanged: return (log + ["1 approval: task text differs from the reviewed one", "outcome: refused_task_changed"]).joined(separator: "\n")
        }
        if let refusal = gate.admit(lane, opId: journeyId + ":approved") { return (log + ["2 gate: refused \(refusal)", "outcome: refused_by_gate"]).joined(separator: "\n") }
        let result = runner(lane, task, workspace, yolo, timeout)
        let status = gate.settle(lane, opId: journeyId + ":approved", result: result)
        switch result {
        case .failure(let e): log.append("3 execute: \(e.message)")
        case .success(let r): log.append("3 execute: exit \(r.exit) · \(String(format: "%.1f", r.seconds)) s · \(r.output.count) chars")
        }
        log.append("4 reconcile: execution_status=\(status) · cost_status=unknown")
        log.append("outcome: \(status == "settled" ? "completed" : status)")
        return log.joined(separator: "\n")
    }
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

// MARK: - Gate: concurrency, dedupe, 429 suspension, attempt ledger (ChatGPT task 4)

/// Every agent_run passes here first. Money is not metered for CLIs (they are
/// subscriptions); what is metered is attempts, seconds and outcome, per lane,
/// so a lane that answers 429 stops being called and duplicates never run twice.
public final class HarnessGate: @unchecked Sendable {
    public static let shared = HarnessGate(ledgerPath: (NSHomeDirectory() as NSString).appendingPathComponent(".config/macrix/agent-ledger.jsonl"))
    private let lock = NSLock()
    private var running = 0
    private var seen: [String: Date] = [:]                 // op_id → first seen
    private var suspended: [Harness.Agent: Date] = [:]     // lane → until
    public let ledgerPath: String
    // ponytail: fixed knobs; per-lane values when we have real contention data
    public var maxConcurrent = 2
    public var dedupeWindow: TimeInterval = 600
    public var suspendFor: TimeInterval = 1800
    /// Canonical ledger (PR #2 bridge). Loaded once; nil = accounting off.
    public lazy var ledgerLoad: Result<LedgerBridge?, LedgerBridge.LoadError> = LedgerBridge.load()
    public var ledger: LedgerBridge? { if case .success(let b?) = ledgerLoad { return b }; return nil }
    private var ledgerNotes: [String: String] = [:]      // op key → ledger outcome for the ledger line

    /// Durable state next to the ledger: seen op_ids, suspensions, in-flight runs,
    /// and single-use approvals. Written atomically after every change.
    public var statePath: String { (ledgerPath as NSString).deletingPathExtension + "-state.json" }
    private var inFlight: [String: (Harness.Agent, Date)] = [:]   // op_id (or run uuid) → lane, started
    private var approvals: [String: Approval] = [:]               // journey_id → approval

    public struct Approval: Equatable, Sendable {
        public var journeyId: String; public var lane: Harness.Agent; public var taskHash: String
        public var token: String; public var expires: Date; public var used = false
    }

    public init(ledgerPath: String) {
        self.ledgerPath = ledgerPath
        loadLocked()
        recoverLocked()
    }

    public enum Refusal: Equatable { case busy(Int), duplicate(String), suspended(Harness.Agent, Date), frozen(String) }

    /// Reserve a slot. Returns nil when admitted.
    public func admit(_ lane: Harness.Agent, opId: String?, now: Date = Date()) -> Refusal? {
        lock.lock(); defer { lock.unlock() }
        if let until = suspended[lane], until > now { return .suspended(lane, until) }
        if let id = opId, !id.isEmpty {
            seen = seen.filter { now.timeIntervalSince($0.value) < dedupeWindow }
            if seen[id] != nil { return .duplicate(id) }
        }
        if running >= maxConcurrent { return .busy(running) }
        let key = opId?.isEmpty == false ? opId! : UUID().uuidString
        if let l = ledger {
            // reserve → dispatch before the process exists; a frozen account refuses
            _ = l.openAccount()
            switch l.reserve(key) {
            case .failure(let e): return .frozen(e.message)
            case .success(let b) where b.frozen: _ = l.cancel(key); return .frozen("account frozen")
            case .success: break
            }
            if case .failure(let e) = l.dispatch(key) { _ = l.cancel(key); return .frozen(e.message) }
            ledgerNotes[key] = "reserved+dispatched"
        }
        running += 1
        if let id = opId, !id.isEmpty { seen[id] = now }
        inFlight[key] = (lane, now)
        saveLocked()
        return nil
    }

    /// Release the slot and record the outcome. Kill by timeout is `unknown`
    /// (the CLI may have done work we did not observe), never `settled`.
    public func settle(_ lane: Harness.Agent, opId: String?, result: Result<Harness.RunResult, JevError>, now: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        running = max(0, running - 1)
        var key = opId?.isEmpty == false ? opId! : ""
        if key.isEmpty, let k = inFlight.min(by: { $0.value.1 < $1.value.1 })?.key { key = k }
        inFlight[key] = nil
        defer { saveLocked() }
        var status = "settled"; var seconds = 0.0; var exit: Int32 = -1
        switch result {
        case .failure: status = "refused"
        case .success(let r):
            seconds = r.seconds; exit = r.exit
            if r.output.contains("[macrix: killed after") { status = "unknown" }
            if HarnessGate.looksLikeQuota(r.output) {
                status = "quota"
                suspended[lane] = now.addingTimeInterval(suspendFor)
            }
        }
        // ChatGPT review (21/09): exit 0 proves execution, never cost. Cost stays
        // "unknown" until something reconciles it against the provider's meter.
        var costStatus = "unknown"; var ledgerNote = "off"
        if let l = ledger, ledgerNotes[key] != nil {
            let r: Result<LedgerBridge.Balance, JevError>
            switch status {
            case "settled", "quota": r = l.settle(key); costStatus = r.isOk ? "attempt_units_settled" : "unknown"
            case "unknown": r = l.markUnknown(key)            // hold preserved, account frozen until review
            default: r = l.cancel(key)
            }
            ledgerNote = r.isOk ? "ok" : (try? r.get()) == nil ? "error:\((r.error?.message ?? "?"))" : "ok"
            ledgerNotes[key] = nil
        }
        let line: [String: JSONValue] = ["ts": .string(ISO8601DateFormatter().string(from: now)), "lane": .string(lane.rawValue),
            "op_id": .string(opId ?? ""), "seconds": .number((seconds * 10).rounded() / 10), "exit": .number(Double(exit)),
            "execution_status": .string(status), "cost_status": .string(costStatus), "ledger": .string(ledgerNote)]
        if let d = try? JSONEncoder().encode(JSONValue.object(line)), let s = String(data: d, encoding: .utf8) {
            let dir = (ledgerPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let h = FileHandle(forWritingAtPath: ledgerPath) { h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); try? h.close() }
            else { try? (s + "\n").write(toFile: ledgerPath, atomically: true, encoding: .utf8) }
        }
        return status
    }

    /// Provider quota exhaustion as the CLIs print it today (Muse, Codex, Antigravity).
    public static func looksLikeQuota(_ out: String) -> Bool {
        let l = out.lowercased()
        return l.contains("429") || l.contains("quota exhausted") || l.contains("usage limit") || l.contains("resource_exhausted") || l.contains("rate_limit_error")
    }

    public func status(now: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        let s = suspended.filter { $0.value > now }.map { "\($0.key.rawValue) until \(ISO8601DateFormatter().string(from: $0.value))" }.sorted()
        var bal = ""
        if let l = ledger, case .success(let b) = l.balance() { bal = " · account cap \(b.cap) held \(b.held) spent \(b.spent)\(b.frozen ? " FROZEN" : "")" }
        return "running \(running)/\(maxConcurrent) · suspended: \(s.isEmpty ? "none" : s.joined(separator: ", ")) · attempts \(ledgerPath) · \(LedgerBridge.describe(ledgerLoad))\(bal)"
    }

    /// Test hook.
    public func reset() { lock.lock(); running = 0; seen = [:]; suspended = [:]; inFlight = [:]; approvals = [:]; saveLocked(); lock.unlock() }

    // MARK: approvals bound to a journey (ChatGPT task 1)

    /// Issue a single-use approval for exactly this journey, lane and task text.
    public func issueApproval(journeyId: String, lane: Harness.Agent, task: String, ttl: TimeInterval = 900, now: Date = Date()) -> Approval {
        lock.lock(); defer { lock.unlock(); saveLocked() }
        let a = Approval(journeyId: journeyId, lane: lane, taskHash: HarnessGate.hash(task),
                         token: "apr_" + Codec.randomHex(16), expires: now.addingTimeInterval(ttl))
        approvals[journeyId] = a
        return a
    }

    public enum ApprovalCheck: Equatable { case ok(Harness.Agent), missing, expired, used, wrongToken, taskChanged }

    /// Consume the approval: token must match, be unused, unexpired, and the task text unchanged.
    public func consumeApproval(journeyId: String, token: String, task: String, now: Date = Date()) -> ApprovalCheck {
        lock.lock(); defer { lock.unlock(); saveLocked() }
        guard var a = approvals[journeyId] else { return .missing }
        if a.used { return .used }
        if now > a.expires { approvals[journeyId] = nil; return .expired }
        guard a.token == token else { return .wrongToken }
        guard a.taskHash == HarnessGate.hash(task) else { return .taskChanged }
        a.used = true; approvals[journeyId] = a
        return .ok(a.lane)
    }

    public static func hash(_ s: String) -> String { Codec.sha256(s.trimmingCharacters(in: .whitespacesAndNewlines)) }

    /// Deterministic production markers: no confidence overrides this list.
    public static let productionMarkers = ["100.110.127.44", "148.230.75.172", "easypanel", "producao", "produção", "prod-", "docker service", "docker restart", "docker stop", "kill -9", "rm -rf /"]
    public static func touchesProduction(_ task: String) -> Bool {
        let l = task.lowercased()
        return productionMarkers.contains { l.contains($0) }
    }

    // MARK: persistence

    private func saveLocked() {
        let iso = ISO8601DateFormatter()
        var obj: [String: JSONValue] = [
            "seen": .object(Dictionary(uniqueKeysWithValues: seen.map { ($0.key, JSONValue.string(iso.string(from: $0.value))) })),
            "suspended": .object(Dictionary(uniqueKeysWithValues: suspended.map { ($0.key.rawValue, JSONValue.string(iso.string(from: $0.value))) })),
            "in_flight": .object(Dictionary(uniqueKeysWithValues: inFlight.map { ($0.key, JSONValue.object(["lane": .string($0.value.0.rawValue), "started": .string(iso.string(from: $0.value.1))])) })),
            "approvals": .object(Dictionary(uniqueKeysWithValues: approvals.map { ($0.key, JSONValue.object(["lane": .string($0.value.lane.rawValue), "task_hash": .string($0.value.taskHash), "token": .string($0.value.token), "expires": .string(iso.string(from: $0.value.expires)), "used": .bool($0.value.used)])) })),
        ]
        obj["saved_at"] = .string(iso.string(from: Date()))
        guard let d = try? JSONEncoder().encode(JSONValue.object(obj)) else { return }
        let dir = (statePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = statePath + ".tmp"
        try? d.write(to: URL(fileURLWithPath: tmp), options: .atomic)
        _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: statePath), withItemAt: URL(fileURLWithPath: tmp))
    }

    private func loadLocked() {
        guard let d = FileManager.default.contents(atPath: statePath), let v = try? JSONDecoder().decode(JSONValue.self, from: d) else { return }
        let iso = ISO8601DateFormatter()
        if case .object(let s)? = v["seen"] { for (k, val) in s { if let str = val.string, let dt = iso.date(from: str) { seen[k] = dt } } }
        if case .object(let s)? = v["suspended"] { for (k, val) in s { if let a = Harness.Agent(rawValue: k), let str = val.string, let dt = iso.date(from: str) { suspended[a] = dt } } }
        if case .object(let s)? = v["in_flight"] { for (k, val) in s { if let a = Harness.Agent(rawValue: val["lane"]?.string ?? ""), let dt = iso.date(from: val["started"]?.string ?? "") { inFlight[k] = (a, dt) } } }
        if case .object(let s)? = v["approvals"] {
            for (k, val) in s {
                if let a = Harness.Agent(rawValue: val["lane"]?.string ?? ""), let h = val["task_hash"]?.string, let tk = val["token"]?.string,
                   let dt = iso.date(from: val["expires"]?.string ?? "") {
                    approvals[k] = Approval(journeyId: k, lane: a, taskHash: h, token: tk, expires: dt, used: val["used"]?.bool ?? false)
                }
            }
        }
    }

    /// Runs that were in flight when the process died: nobody observed their end,
    /// so they are `unknown`, never settled, and the slot is released.
    private func recoverLocked() {
        guard !inFlight.isEmpty else { return }
        let iso = ISO8601DateFormatter()
        for (k, v) in inFlight {
            let line: [String: JSONValue] = ["ts": .string(iso.string(from: Date())), "lane": .string(v.0.rawValue), "op_id": .string(k),
                "seconds": .number(0), "exit": .number(-1), "execution_status": .string("unknown"), "cost_status": .string("unknown"),
                "note": .string("recovered after restart; started \(iso.string(from: v.1))")]
            if let d = try? JSONEncoder().encode(JSONValue.object(line)), let s = String(data: d, encoding: .utf8) {
                if let h = FileHandle(forWritingAtPath: ledgerPath) { h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); try? h.close() }
                else { try? (s + "\n").write(toFile: ledgerPath, atomically: true, encoding: .utf8) }
            }
        }
        inFlight = [:]; running = 0
        saveLocked()
    }
}


extension Result {
    var isOk: Bool { if case .success = self { return true }; return false }
    var error: Failure? { if case .failure(let e) = self { return e }; return nil }
}
