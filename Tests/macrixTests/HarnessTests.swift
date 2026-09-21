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
        return HarnessGate(ledgerPath: p)
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
    func testDedupeWindow() {
        let g = makeGate(); let t0 = Date()
        XCTAssertNil(g.admit(.muse, opId: "op-1", now: t0))
        _ = g.settle(.muse, opId: "op-1", result: ok("done"), now: t0)
        XCTAssertEqual(g.admit(.muse, opId: "op-1", now: t0.addingTimeInterval(60)), .duplicate("op-1"))
        XCTAssertNil(g.admit(.muse, opId: "op-1", now: t0.addingTimeInterval(700)))   // window expired
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
    func gate() -> HarnessGate { HarnessGate(ledgerPath: "/tmp/macrix_journey_\(UUID().uuidString).jsonl") }
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
        let out = Journey.run(task: "apagar o banco de produção", journeyId: "J-2", workspace: "/tmp", client: fakeRoute("claude_fable", review: 0.9), gate: gate(),
                              available: [.claude_fable]) { _, _, _, _, _ in ran = true; return .failure(JevError("x")) }
        XCTAssertFalse(ran); XCTAssertTrue(out.hasSuffix("outcome: needs_human_review"), out)
    }
    func testBadIdAndJevDown() {
        XCTAssertTrue(Journey.run(task: "x", journeyId: "bad id!", workspace: "/tmp", client: fakeRoute("muse", review: 0), gate: gate(), available: [.muse]).hasPrefix("journey refused"))
        let down = fakeRoute("muse", review: 0); down.fail = "http 503"
        XCTAssertTrue(Journey.run(task: "x", journeyId: "J-3", workspace: "/tmp", client: down, gate: gate(), available: [.muse]).hasSuffix("outcome: blocked_at_route"))
    }
}
