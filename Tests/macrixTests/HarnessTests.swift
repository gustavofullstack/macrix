import XCTest
@testable import macrix

final class HarnessArgvTests: XCTestCase {
    func testClaudeTiersPinModels() {
        XCTAssertEqual(Harness.Agent.claude_fable.argv(prompt: "x", model: nil, yolo: false),
                       ["-p", "x", "--output-format", "text", "--model", "claude-fable-5-1"])
        XCTAssertEqual(Harness.Agent.claude_sonnet.argv(prompt: "x", model: nil, yolo: true).last, "--dangerously-skip-permissions")
        XCTAssertTrue(Harness.Agent.claude_opus.argv(prompt: "x", model: nil, yolo: false).contains("claude-opus-5"))
    }
    func testOtherAgents() {
        XCTAssertEqual(Harness.Agent.muse.argv(prompt: "oi", model: nil, yolo: false), ["exec", "--reasoning-effort", "low", "oi"])
        XCTAssertEqual(Harness.Agent.codex.argv(prompt: "oi", model: "gpt-5.6-sol", yolo: true), ["exec", "-m", "gpt-5.6-sol", "--full-auto", "oi"])
        XCTAssertEqual(Harness.Agent.antigravity.argv(prompt: "oi", model: nil, yolo: false), ["-p", "oi", "--output-format", "text"])
        XCTAssertEqual(Harness.Agent.opencode.argv(prompt: "oi", model: "omniroute/auto", yolo: false), ["run", "-m", "omniroute/auto", "oi"])
    }
    func testPromptIsSingleArgvEntry() {
        // no shell: metacharacters stay inside one argument
        let a = Harness.Agent.muse.argv(prompt: "rm -rf / ; echo $(x) | cat", model: nil, yolo: false)
        XCTAssertEqual(a.count, 4); XCTAssertEqual(a.last, "rm -rf / ; echo $(x) | cat")
    }
}

final class HarnessWorkspaceTests: XCTestCase {
    func testAllowList() {
        XCTAssertNotNil(Harness.allowedWorkspace("/tmp"))
        XCTAssertNotNil(Harness.allowedWorkspace(""))                       // default ~/Projetos
        XCTAssertNil(Harness.allowedWorkspace("/"))
        XCTAssertNil(Harness.allowedWorkspace("/etc"))
        XCTAssertNil(Harness.allowedWorkspace("/tmp/../etc"))
        XCTAssertNil(Harness.allowedWorkspace(NSHomeDirectory() + "/.ssh"))
        XCTAssertNil(Harness.allowedWorkspace("/tmp/definitely-missing-\(UUID().uuidString)"))
    }
    func testRunRefusals() {
        if case .failure(let e) = Harness.run(.muse, prompt: "   ", workspace: "/tmp") { XCTAssertTrue(e.message.contains("empty")) } else { XCTFail() }
        if case .failure(let e) = Harness.run(.muse, prompt: "x", workspace: "/etc") { XCTAssertTrue(e.message.contains("refused")) } else { XCTFail() }
    }
    func testRunRealProcessBoundedAndKilled() {
        // goose may be absent: pick any resolvable agent path but call /bin/sh through a fake? No — exercise the kill path with a real binary via a tiny helper agent.
        // We use `opencode` argv shape but point at /bin/sleep by temporarily checking resolve(); if opencode is absent the test still passes on refusal.
        let r = Harness.run(.goose, prompt: "x", workspace: "/tmp", timeout: 5)
        switch r {
        case .failure(let e): XCTAssertTrue(e.message.contains("not installed") || e.message.contains("spawn"), e.message)
        case .success(let ok): XCTAssertLessThan(ok.seconds, 60); XCTAssertLessThanOrEqual(ok.output.utf8.count, 20_000 + 64)
        }
    }
}

final class HarnessRouteTests: XCTestCase {
    func testRequestAndParse() {
        let req = Harness.routeRequest(task: "renomear variável", available: [.claude_sonnet, .muse])
        XCTAssertEqual(req["questions"]?["lane"]?["type"]?.string, "choice")
        XCTAssertNotNil(req["questions"]?["lane"]?["criteria"]?["muse"])
        XCTAssertNil(req["questions"]?["lane"]?["criteria"]?["codex"])       // unavailable lanes are not offered
        let resp: JSONValue = .object(["answers": .object([
            "lane": .object(["choice": .string("muse"), "probabilities": .object(["muse": .number(0.7), "claude_sonnet": .number(0.3)])]),
            "needs_review": .object(["noul": .number(0.1)])])])
        let r = Harness.parseRoute(resp)!
        XCTAssertEqual(r.lane, .muse); XCTAssertEqual(r.p, 0.7, accuracy: 1e-9); XCTAssertEqual(r.review, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r.dist.first?.0, "muse")
        XCTAssertTrue(Harness.routeText(r).contains("lane: muse (0.70)"))
    }
    func testRouteWithFakeJevAndFailures() {
        let fake = FakeJev(.object(["lane": .object(["choice": .string("claude_fable"), "probabilities": .object(["claude_fable": .number(0.9)])]),
                                    "needs_review": .object(["noul": .number(0.8)])]))
        if case .success(let r) = Harness.route(task: "redesenhar o daemon", client: fake, available: [.claude_fable, .muse]) {
            XCTAssertEqual(r.lane, .claude_fable); XCTAssertEqual(r.review, 0.8, accuracy: 1e-9)
        } else { XCTFail() }
        if case .failure(let e) = Harness.route(task: "", client: fake, available: [.muse]) { XCTAssertTrue(e.message.contains("empty")) } else { XCTFail() }
        if case .failure(let e) = Harness.route(task: "x", client: fake, available: []) { XCTAssertTrue(e.message.contains("no agent")) } else { XCTFail() }
        fake.fail = "http 500"
        if case .failure(let e) = Harness.route(task: "x", client: fake, available: [.muse]) { XCTAssertTrue(e.message.contains("jev: http 500")) } else { XCTFail() }
    }
}

final class EnvInventoryTests: XCTestCase {
    func testReportShapeWithoutSecrets() {
        let r = EnvInventory.report()
        XCTAssertTrue(r.contains("mcp_servers (claude):"))
        XCTAssertTrue(r.contains("agents: "))
        XCTAssertFalse(r.contains("sk-")); XCTAssertFalse(r.contains("Bearer"))
    }
    func testRegistryHasHarnessTools() {
        let reg = ToolRegistry(); registerAllTools(into: reg)
        let names = Set(reg.list().map { $0.name })
        for n in ["agents_list", "agent_run", "agent_route", "env_inventory"] { XCTAssertTrue(names.contains(n), n) }
    }
}

final class HarnessGateTests: XCTestCase {
    func makeGate() -> HarnessGate {
        let p = "/tmp/macrix_gate_\(UUID().uuidString).jsonl"
        return HarnessGate(ledgerPath: p, ledgerConfig: nil)
    }
    func ok(_ out: String, secs: Double = 1) -> Result<Harness.RunResult, JevError> {
        .success(Harness.RunResult(agent: .muse, argv: ["x"], exit: 0, seconds: secs, output: out, truncated: false))
    }
    func testConcurrencyAndRelease() {
        let g = makeGate(); g.maxConcurrent = 2
        XCTAssertNil(g.admit(.claude_sonnet, opId: nil)); XCTAssertNil(g.admit(.claude_sonnet, opId: nil))
        XCTAssertEqual(g.admit(.claude_sonnet, opId: nil), .busy(2))
        XCTAssertEqual(g.settle(.claude_sonnet, opId: nil, result: ok("fine")), "settled")
        XCTAssertNil(g.admit(.claude_sonnet, opId: nil))
    }
    func testDedupeIsForever() {
        let g = makeGate(); let t0 = Date()
        XCTAssertNil(g.admit(.muse, opId: "op-1", now: t0))
        _ = g.settle(.muse, opId: "op-1", result: ok("done"), now: t0)
        XCTAssertEqual(g.admit(.muse, opId: "op-1", now: t0.addingTimeInterval(60)), .duplicate("op-1"))
        XCTAssertEqual(g.admit(.muse, opId: "op-1", now: t0.addingTimeInterval(700)), .duplicate("op-1"))   // replay after 10 min is still a replay
        XCTAssertEqual(g.admit(.muse, opId: "op-1", now: t0.addingTimeInterval(86_400 * 7)), .duplicate("op-1"))
    }
    func testQuotaSuspendsLaneAndTimeoutIsUnknown() {
        let g = makeGate(); let t0 = Date()
        XCTAssertNil(g.admit(.muse, opId: nil, now: t0))
        XCTAssertEqual(g.settle(.muse, opId: nil, result: ok("API error 429: Subscription quota exhausted"), now: t0), "quota")
        if case .suspended(.muse, let until)? = g.admit(.muse, opId: nil, now: t0.addingTimeInterval(5)) {
            XCTAssertEqual(until.timeIntervalSince(t0), 1800, accuracy: 1)
        } else { XCTFail("muse should be suspended") }
        XCTAssertNil(g.admit(.claude_sonnet, opId: nil, now: t0.addingTimeInterval(5)))   // other lanes unaffected
        XCTAssertNil(g.admit(.muse, opId: nil, now: t0.addingTimeInterval(1801)))
        XCTAssertEqual(g.settle(.muse, opId: nil, result: ok("partial\n[macrix: killed after 5s]")), "unknown")
        XCTAssertEqual(g.settle(.muse, opId: nil, result: .failure(JevError("workspace refused"))), "refused")
    }
    func testLedgerLinesAndStatus() {
        let g = makeGate()
        XCTAssertNil(g.admit(.claude_opus, opId: "abc"))
        _ = g.settle(.claude_opus, opId: "abc", result: ok("x", secs: 2.34))
        let lines = (try? String(contentsOfFile: g.ledgerPath, encoding: .utf8))?.split(separator: "\n") ?? []
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("\"lane\":\"claude_opus\"") && lines[0].contains("\"op_id\":\"abc\"") && lines[0].contains("\"execution_status\":\"settled\"") && lines[0].contains("\"cost_status\":\"unknown\""), String(lines[0]))
        XCTAssertTrue(g.status().contains("running 0/2"))
        XCTAssertTrue(HarnessGate.looksLikeQuota("You've hit your usage limit") && !HarnessGate.looksLikeQuota("all good"))
        try? FileManager.default.removeItem(atPath: g.ledgerPath)
    }
}


final class JourneyTests: XCTestCase {
    func gate() -> HarnessGate { HarnessGate(ledgerPath: "/tmp/macrix_journey_\(UUID().uuidString).jsonl", ledgerConfig: nil) }
    func fakeRoute(_ lane: String, review: Double) -> FakeJev {
        FakeJev(.object(["lane": .object(["choice": .string(lane), "probabilities": .object([lane: .number(0.9)])]),
                         "needs_review": .object(["noul": .number(review)])]))
    }
    func testHappyPathWithFakeRunner() {
        let g = gate()
        let out = Journey.run(task: "renomear foo", journeyId: "J-1", workspace: "/tmp", client: fakeRoute("claude_sonnet", review: 0.1), gate: g,
                              available: [.claude_sonnet, .muse]) { lane, _, _, _, _ in
            .success(Harness.RunResult(agent: lane, argv: ["x"], exit: 0, seconds: 1.5, output: "done", truncated: false))
        }
        XCTAssertTrue(out.contains("1 route (jev): lane: claude_sonnet"), out)
        XCTAssertTrue(out.contains("op_id=J-1") && out.contains("execution_status=settled · cost_status=unknown") && out.hasSuffix("outcome: completed"), out)
        let ledger = (try? String(contentsOfFile: g.ledgerPath, encoding: .utf8)) ?? ""
        XCTAssertTrue(ledger.contains("\"op_id\":\"J-1\"") && ledger.contains("\"cost_status\":\"unknown\""))
        // same journey id again → gate dedupe, no second run
        let again = Journey.run(task: "renomear foo", journeyId: "J-1", workspace: "/tmp", client: fakeRoute("claude_sonnet", review: 0.1), gate: g,
                                available: [.claude_sonnet]) { _, _, _, _, _ in XCTFail("must not run twice"); return .failure(JevError("x")) }
        XCTAssertTrue(again.contains("outcome: refused_by_gate"), again)
        try? FileManager.default.removeItem(atPath: g.ledgerPath)
    }
    func testReviewStopsBeforeExecution() {
        var ran = false
        let out = Journey.run(task: "apagar todos os arquivos gerados do projeto", journeyId: "J-2", workspace: "/tmp", client: fakeRoute("claude_fable", review: 0.9), gate: gate(),
                              available: [.claude_fable]) { _, _, _, _, _ in ran = true; return .failure(JevError("x")) }
        XCTAssertFalse(ran); XCTAssertTrue(out.hasSuffix("outcome: needs_human_review"), out)
    }
    func testBadIdAndJevDown() {
        XCTAssertTrue(Journey.run(task: "x", journeyId: "bad id!", workspace: "/tmp", client: fakeRoute("muse", review: 0), gate: gate(), available: [.muse]).hasPrefix("journey refused"))
        let down = fakeRoute("muse", review: 0); down.fail = "http 503"
        XCTAssertTrue(Journey.run(task: "x", journeyId: "J-3", workspace: "/tmp", client: down, gate: gate(), available: [.muse]).hasSuffix("outcome: blocked_at_route"))
    }
}


final class GatePersistenceAndApprovalTests: XCTestCase {
    func path() -> String { "/tmp/macrix_gp_\(UUID().uuidString).jsonl" }
    func ok(_ lane: Harness.Agent) -> Result<Harness.RunResult, JevError> { .success(Harness.RunResult(agent: lane, argv: ["x"], exit: 0, seconds: 1, output: "ok", truncated: false)) }
    func testStateSurvivesRestartAndInFlightBecomesUnknown() {
        let p = path()
        let g1 = HarnessGate(ledgerPath: p, ledgerConfig: nil)
        XCTAssertNil(g1.admit(.muse, opId: "op-A")); _ = g1.settle(.muse, opId: "op-A", result: .success(Harness.RunResult(agent: .muse, argv: [], exit: 1, seconds: 2, output: "429 quota", truncated: false)))
        XCTAssertNil(g1.admit(.claude_sonnet, opId: "op-B"))          // left in flight → simulated crash
        let g2 = HarnessGate(ledgerPath: p, ledgerConfig: nil)                             // "restart"
        XCTAssertEqual(g2.admit(.claude_sonnet, opId: "op-A"), .duplicate("op-A"))   // seen persisted (dedupe is per op_id)
        if case .suspended(.muse, _)? = g2.admit(.muse, opId: "op-Z") {} else { XCTFail("suspension should persist") }
        XCTAssertNil(g2.admit(.claude_sonnet, opId: "op-C"))            // slot recovered
        let ledger = (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
        XCTAssertTrue(ledger.contains("\"op_id\":\"op-B\"") && ledger.contains("recovered after restart") && ledger.contains("\"execution_status\":\"unknown\""), ledger)
        XCTAssertTrue(FileManager.default.fileExists(atPath: g2.statePath))
        for f in [p, g2.statePath] { try? FileManager.default.removeItem(atPath: f) }
    }
    func testApprovalIsSingleUseBoundToTaskAndExpires() {
        let g = HarnessGate(ledgerPath: path(), ledgerConfig: nil); let t0 = Date()
        let a = g.issueApproval(journeyId: "J-9", lane: .claude_fable, task: "refatorar o daemon", now: t0)!
        XCTAssertTrue(a.token.hasPrefix("apr_"))
        XCTAssertEqual(g.consumeApproval(journeyId: "J-9", token: "apr_wrong", task: "refatorar o daemon", now: t0), .wrongToken)
        XCTAssertEqual(g.consumeApproval(journeyId: "J-9", token: a.token, task: "refatorar o daemon E apagar tudo", now: t0), .taskChanged)
        XCTAssertEqual(g.consumeApproval(journeyId: "J-9", token: a.token, task: "refatorar o daemon", now: t0), .ok(.claude_fable))
        XCTAssertEqual(g.consumeApproval(journeyId: "J-9", token: a.token, task: "refatorar o daemon", now: t0), .used)
        XCTAssertEqual(g.consumeApproval(journeyId: "J-9", token: a.token, task: "refatorar o daemon", workspace: "/tmp/other"), .used)   // used wins, but a manifest change alone would also refuse
        let b = g.issueApproval(journeyId: "J-10", lane: .muse, task: "x", ttl: 10, now: t0)!
        XCTAssertEqual(g.consumeApproval(journeyId: "J-10", token: b.token, task: "x", now: t0.addingTimeInterval(11)), .expired)
        XCTAssertEqual(g.consumeApproval(journeyId: "J-none", token: "apr_x", task: "x"), .missing)
        try? FileManager.default.removeItem(atPath: g.statePath)
    }
    func testProductionBlockedByDefaultEvenWithToken() {
        XCTAssertTrue(HarnessGate.touchesProduction("reiniciar o container no EasyPanel da produção"))
        XCTAssertTrue(HarnessGate.touchesProduction("ssh 100.110.127.44 docker restart api"))
        XCTAssertFalse(HarnessGate.touchesProduction("renomear variável no arquivo local"))
        let g = HarnessGate(ledgerPath: path(), ledgerConfig: nil)
        let fake = FakeJev(.object(["lane": .object(["choice": .string("claude_fable"), "probabilities": .object(["claude_fable": .number(0.9)])]), "needs_review": .object(["noul": .number(0.2)])]))
        var ran = false
        let out = Journey.run(task: "docker restart api na producao", journeyId: "J-P", workspace: "/tmp", client: fake, gate: g, available: [.claude_fable]) { _, _, _, _, _ in ran = true; return .failure(JevError("x")) }
        XCTAssertFalse(ran); XCTAssertTrue(out.hasSuffix("outcome: blocked_production"), out)
        let a = g.issueApproval(journeyId: "J-P2", lane: .claude_fable, task: "docker stop api", workspace: "/tmp")!
        let out2 = Journey.approve(journeyId: "J-P2", token: a.token, task: "docker stop api", workspace: "/tmp", gate: g) { _, _, _, _, _ in ran = true; return .failure(JevError("x")) }
        XCTAssertFalse(ran); XCTAssertTrue(out2.hasSuffix("outcome: blocked_production"), out2)
        try? FileManager.default.removeItem(atPath: g.statePath)
    }
    func testReviewedJourneyThenApproveRunsOnce() {
        let g = HarnessGate(ledgerPath: path(), ledgerConfig: nil)
        let fake = FakeJev(.object(["lane": .object(["choice": .string("claude_opus"), "probabilities": .object(["claude_opus": .number(0.8)])]), "needs_review": .object(["noul": .number(0.9)])]))
        let out = Journey.run(task: "reescrever o parser de argumentos", journeyId: "J-R", workspace: "/tmp", client: fake, gate: g, available: [.claude_opus]) { _, _, _, _, _ in XCTFail("must not run"); return .failure(JevError("x")) }
        XCTAssertTrue(out.hasSuffix("outcome: needs_human_review"), out)
        XCTAssertFalse(out.contains("apr_"), "token must not be returned to the MCP caller")
        let file = out.split(separator: "\n").compactMap { l -> String? in guard let r = l.range(of: "Mac: ") else { return nil }; return String(l[r.upperBound...]) }.first!
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let token = text.split(separator: "\n").first { $0.hasPrefix("token: ") }.map { String($0.dropFirst(7)) }!
        XCTAssertTrue(token.hasPrefix("apr_"))
        // changing a parameter of the manifest (workspace) kills the token
        let wrongWs = Journey.approve(journeyId: "J-R", token: token, task: "reescrever o parser de argumentos", workspace: "/tmp/elsewhere", gate: g) { _, _, _, _, _ in XCTFail("must not run"); return .failure(JevError("x")) }
        XCTAssertTrue(wrongWs.hasSuffix("outcome: refused_task_changed"), wrongWs)
        try? FileManager.default.removeItem(atPath: file)
        var runs = 0
        let ok = Journey.approve(journeyId: "J-R", token: token, task: "reescrever o parser de argumentos", workspace: "/tmp", gate: g) { lane, _, _, _, _ in runs += 1; return self.ok(lane) }
        XCTAssertTrue(ok.hasSuffix("outcome: completed") && ok.contains("1 approval: valid, consumed"), ok); XCTAssertEqual(runs, 1)
        let again = Journey.approve(journeyId: "J-R", token: token, task: "reescrever o parser de argumentos", workspace: "/tmp", gate: g) { _, _, _, _, _ in runs += 1; return .failure(JevError("x")) }
        XCTAssertTrue(again.hasSuffix("outcome: refused_used"), again); XCTAssertEqual(runs, 1)
        try? FileManager.default.removeItem(atPath: g.statePath)
    }
}

final class LedgerBridgeTests: XCTestCase {
    /// A python ≥ 3.11 for the fake bridge; skip when the machine has none.
    func modernPython() -> String? {
        for p in ["/Users/sug/.local/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            let (c, out) = runProcess(p, ["-c", "import sys; print(sys.version_info >= (3, 11))"], timeoutSeconds: 10)
            if c == 0, out.contains("True") { return p }
        }
        return nil
    }
    func writeFakeBridge(_ dir: String) -> String {
        let script = """
        import json, sys, os
        p = json.loads(sys.stdin.read()); log = os.path.join(os.path.dirname(os.path.abspath(sys.argv[2])), 'calls.log')
        open(log, 'a').write(p['action'] + '\\n')
        if p['action'] == 'reserve' and p['event_id'] == 'frozen-op': print(json.dumps({'ok': False, 'code': 'ACCOUNT_FROZEN'})); sys.exit(1)
        print(json.dumps({'ok': True, 'balance': {'cap': 1000000, 'held': 1000 if p['action'] in ('reserve','dispatch') else 0, 'spent': 1000 if p['action']=='settle' else 0, 'remaining': 999000, 'frozen': p['action']=='mark_unknown', 'over_budget': False}}))
        """
        let path = dir + "/fake_bridge.py"; try? script.write(toFile: path, atomically: true, encoding: .utf8); return path
    }
    func testLoadStates() {
        XCTAssertEqual(LedgerBridge.load(path: "/tmp/definitely-missing-\(UUID().uuidString).json").map { $0 == nil }, .success(true))
        let dir = "/tmp/macrix_lb_\(UUID().uuidString)"; try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let bad = dir + "/bad.json"; try? "{\"python\":\"/usr/bin/python3\",\"bridge\":\"\(dir)/nope.py\",\"database\":\"\(dir)/db.sqlite\"}".write(toFile: bad, atomically: true, encoding: .utf8)
        if case .failure(let e) = LedgerBridge.load(path: bad) { XCTAssertEqual(e, .missing("\(dir)/nope.py")) } else { XCTFail("missing bridge must fail") }
        let br = writeFakeBridge(dir)
        let old = dir + "/old.json"; try? "{\"python\":\"/usr/bin/python3\",\"bridge\":\"\(br)\",\"database\":\"\(dir)/db.sqlite\"}".write(toFile: old, atomically: true, encoding: .utf8)
        if case .failure(let e) = LedgerBridge.load(path: old) { if case .pythonTooOld = e {} else { XCTFail("3.9 must be refused, got \(e)") } } else { XCTFail("old python must fail preflight") }
        let rel = dir + "/rel.json"; try? "{\"python\":\"python3\",\"bridge\":\"\(br)\",\"database\":\"\(dir)/db.sqlite\"}".write(toFile: rel, atomically: true, encoding: .utf8)
        if case .failure(.badConfig) = LedgerBridge.load(path: rel) {} else { XCTFail("relative path must be refused") }
        try? FileManager.default.removeItem(atPath: dir)
    }
    func testGateReservesDispatchesSettlesThroughBridge() throws {
        guard let py = modernPython() else { throw XCTSkip("no python ≥ 3.11 here") }
        let dir = "/tmp/macrix_lb_\(UUID().uuidString)"; try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let br = writeFakeBridge(dir)
        let cfg = dir + "/ledger.json"; try? "{\"python\":\"\(py)\",\"bridge\":\"\(br)\",\"database\":\"\(dir)/db.sqlite\",\"tenant\":\"t\",\"attempt_units\":1000}".write(toFile: cfg, atomically: true, encoding: .utf8)
        let g = HarnessGate(ledgerPath: dir + "/ledger.jsonl", ledgerConfig: nil)
        g.ledgerLoad = LedgerBridge.load(path: cfg)
        XCTAssertNotNil(g.ledger, "\(g.ledgerLoad)")
        XCTAssertNil(g.admit(.claude_sonnet, opId: "op-1"))
        XCTAssertEqual(g.settle(.claude_sonnet, opId: "op-1", result: .success(Harness.RunResult(agent: .claude_sonnet, argv: [], exit: 0, seconds: 1, output: "ok", truncated: false))), "settled")
        XCTAssertNil(g.admit(.muse, opId: "op-2"))
        XCTAssertEqual(g.settle(.muse, opId: "op-2", result: .success(Harness.RunResult(agent: .muse, argv: [], exit: -1, seconds: 5, output: "[macrix: killed after 5s]", truncated: false))), "unknown")
        XCTAssertEqual(g.admit(.muse, opId: "frozen-op"), .frozen("ACCOUNT_FROZEN"))
        let calls = (try? String(contentsOfFile: dir + "/calls.log", encoding: .utf8)) ?? ""
        XCTAssertEqual(calls, "open_account\nreserve\ndispatch\nsettle\nopen_account\nreserve\ndispatch\nmark_unknown\nopen_account\nreserve\n", calls)
        let line = (try? String(contentsOfFile: dir + "/ledger.jsonl", encoding: .utf8)) ?? ""
        XCTAssertTrue(line.contains("\"cost_status\":\"attempt_units_settled\"") && line.contains("\"ledger\":\"ok\""), line)
        XCTAssertTrue(g.status().contains("ledger: on"))
        try? FileManager.default.removeItem(atPath: dir)
    }
}


final class ExecutorAndProcessTreeTests: XCTestCase {
    func testExecuteAppliesProductionPolicyBeforeGate() {
        let g = HarnessGate(ledgerPath: "/tmp/macrix_exec_\(UUID().uuidString).jsonl", ledgerConfig: nil)
        if case .failure(let e) = Harness.execute(.muse, prompt: "docker restart api na producao", workspace: "/tmp", opId: "x", gate: g) {
            XCTAssertTrue(e.message.hasPrefix("blocked_production"), e.message)
        } else { XCTFail() }
        XCTAssertNil(g.admit(.muse, opId: "x"))   // nothing was admitted by the refused execute
        try? FileManager.default.removeItem(atPath: g.statePath)
    }
    func testProcessTreeKillsGrandchildren() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 30 & sleep 30 & wait"]
        try? p.run(); Thread.sleep(forTimeInterval: 0.5)
        let kids = Harness.ProcessTree.descendants(of: p.processIdentifier)
        XCTAssertGreaterThanOrEqual(kids.count, 2, "sh should have two sleep children: \(kids)")
        let left = Harness.ProcessTree.terminate(root: p.processIdentifier)
        XCTAssertTrue(left.isEmpty, "survivors: \(left)")
        XCTAssertFalse(kids.contains { Harness.ProcessTree.alive($0) })
    }
}

final class HTTPPolicyTests: XCTestCase {
    func testContentLengthRejected() {
        let neg = HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: -5\r\n\r\n".utf8))!
        XCTAssertEqual(neg.method, "BAD")
        let huge = HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 99999999999\r\n\r\n".utf8))!
        XCTAssertEqual(huge.method, "BAD")
        let junk = HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: abc\r\n\r\n".utf8))!
        XCTAssertEqual(junk.method, "BAD")
        let ok = HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8))!
        XCTAssertEqual(ok.method, "POST"); XCTAssertEqual(ok.body.count, 2)
    }
    func testPublicSurfaceAndOrigin() {
        XCTAssertTrue(HTTPPolicy.isPublic(headers: ["cf-ray": "abc"])); XCTAssertFalse(HTTPPolicy.isPublic(headers: ["host": "127.0.0.1:35730"]))
        XCTAssertTrue(HTTPPolicy.publicTool("catalog_search")); XCTAssertTrue(HTTPPolicy.publicTool("jev_ping")); XCTAssertTrue(HTTPPolicy.publicTool("agents_gate"))
        for t in ["agent_run", "journey_run", "journey_approve", "voice_listen", "file_read", "cu_click", "app_quit", "notify"] { XCTAssertFalse(HTTPPolicy.publicTool(t), t) }
        XCTAssertTrue(HTTPPolicy.originAllowed("http://127.0.0.1:35730", port: 35730)); XCTAssertTrue(HTTPPolicy.originAllowed("https://macrix.triqhub.tech", port: 35730))
        XCTAssertFalse(HTTPPolicy.originAllowed("https://evil.example", port: 35730)); XCTAssertFalse(HTTPPolicy.originAllowed("null", port: 35730))
    }
}
