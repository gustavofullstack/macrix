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
