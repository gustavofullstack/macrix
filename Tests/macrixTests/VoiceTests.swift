import XCTest
@testable import macrix

/// Fake Jev: returns canned answers, records the request it received.
final class FakeJev: JevClient, @unchecked Sendable {
    var answers: JSONValue
    var lastRequest: JSONValue?
    var fail: String? = nil
    init(_ answers: JSONValue) { self.answers = answers }
    func evaluate(_ request: JSONValue) -> Result<JSONValue, JevError> {
        lastRequest = request
        if let f = fail { return .failure(JevError(f)) }
        return .success(.object(["model": .string("jev-1.13.0"), "answers": answers]))
    }
}

func answer(intent: String, p: Double, app: String? = nil, appP: Double = 0,
            complete: Double = 0.5, addressed: Double = 0.9, destructive: Double = 0.05) -> JSONValue {
    var o: [String: JSONValue] = [
        "intent": .object(["type": .string("choice"), "choice": .string(intent),
                           "probabilities": .object([intent: .number(p)])]),
        "complete": .object(["type": .string("noul"), "noul": .number(complete)]),
        "addressed": .object(["type": .string("noul"), "noul": .number(addressed)]),
        "destructive": .object(["type": .string("noul"), "noul": .number(destructive)]),
    ]
    if let a = app {
        o["app"] = .object(["type": .string("choice"), "choice": .string(a), "probabilities": .object([a: .number(appP)])])
    }
    return .object(o)
}

let apps = ["Notes", "Safari", "Calculator", "System Settings", "Terminal", "Mail", "Music"]

final class VoiceCandidateTests: XCTestCase {
    func testPortugueseAliasAndEnglishName() {
        XCTAssertEqual(Apps.candidates(in: "abre o notas e cria", installed: apps), ["Notes"])
        XCTAssertEqual(Apps.candidates(in: "open the notes app and create", installed: apps), ["Notes"])
        XCTAssertEqual(Apps.candidates(in: "abre as configurações", installed: apps), ["System Settings"])
        XCTAssertTrue(Apps.candidates(in: "bom dia", installed: apps).isEmpty)
    }
    func testBoundedToEight() {
        let many = (0..<20).map { "Zapp\($0)" }
        let c = Apps.candidates(in: "abre o zapp1 zapp2 zapp3 zapp4 zapp5 zapp6 zapp7 zapp8 zapp9", installed: many)
        XCTAssertLessThanOrEqual(c.count, 8)
    }
    func testSpans() {
        XCTAssertEqual(Apps.urlSpan(in: "abre o site udiapods.com agora"), "https://udiapods.com")
        XCTAssertEqual(Apps.urlSpan(in: "vai para https://typesafe.ai/docs"), "https://typesafe.ai/docs")
        XCTAssertNil(Apps.urlSpan(in: "abre o notas"))
        XCTAssertEqual(Apps.querySpan(in: "pesquisa por pods de menta no google"), "pods de menta")
        XCTAssertEqual(Apps.querySpan(in: "search for jev typesafe"), "jev typesafe")
        XCTAssertNil(Apps.querySpan(in: "abre o notas"))
    }
}

final class VoiceRequestTests: XCTestCase {
    func testRequestShape() {
        let r = VoiceBrain.request(transcript: "abre o notas", isFinal: false, candidates: ["Notes"])
        XCTAssertEqual(r["model"]?.string, "jev-1.13.0")
        XCTAssertEqual(r["state"]?["transcript"]?.string, "abre o notas")
        XCTAssertEqual(r["state"]?["is_final"]?.bool, false)
        let q = r["questions"]!
        XCTAssertEqual(q["intent"]?["type"]?.string, "choice")
        XCTAssertNotNil(q["intent"]?["criteria"]?["open_app"])
        XCTAssertNotNil(q["app"]?["criteria"]?["Notes"])
        XCTAssertNotNil(q["app"]?["criteria"]?["none"])
        XCTAssertEqual(q["complete"]?["type"]?.string, "noul")
        XCTAssertNotNil(q["addressed"]); XCTAssertNotNil(q["destructive"])
    }
    func testNoAppQuestionWithoutCandidates() {
        let r = VoiceBrain.request(transcript: "bom dia", isFinal: true, candidates: [])
        XCTAssertNil(r["questions"]?["app"])
    }
    func testParse() {
        let a = VoiceBrain.parse(.object(["answers": answer(intent: "open_app", p: 0.91, app: "Notes", appP: 0.88, complete: 0.2)]))!
        XCTAssertEqual(a.intent, .open_app); XCTAssertEqual(a.intentP, 0.91, accuracy: 1e-9)
        XCTAssertEqual(a.app, "Notes"); XCTAssertEqual(a.appP, 0.88, accuracy: 1e-9)
        XCTAssertEqual(a.complete, 0.2, accuracy: 1e-9)
        XCTAssertNil(VoiceBrain.parse(.object(["answers": .object([:])])))
        let none = VoiceBrain.parse(.object(["answers": answer(intent: "none", p: 0.7, app: "none", appP: 0.9)]))!
        XCTAssertNil(none.app)
    }
}

final class VoiceGateTests: XCTestCase {
    func testOpenAppFiresMidSentence() {
        // the demo: "open the notes app and create..." — app opens before complete
        let a = VoiceBrain.parse(.object(["answers": answer(intent: "open_app", p: 0.85, app: "Notes", appP: 0.8, complete: 0.15)]))!
        XCTAssertEqual(VoiceBrain.gate(a, transcript: "open the notes app and", done: []), .act(.open_app, "Notes"))
    }
    func testDedupeWithinUtterance() {
        let a = VoiceBrain.parse(.object(["answers": answer(intent: "open_app", p: 0.85, app: "Notes", appP: 0.8)]))!
        XCTAssertEqual(VoiceBrain.gate(a, transcript: "abre o notas e cria", done: ["open_app:Notes"]), .skip("open_app:Notes"))
    }
    func testWaitsBelowThresholds() {
        let low = VoiceBrain.parse(.object(["answers": answer(intent: "open_app", p: 0.5, app: "Notes", appP: 0.9)]))!
        if case .wait = VoiceBrain.gate(low, transcript: "abre", done: []) {} else { XCTFail("should wait on intent") }
        let noApp = VoiceBrain.parse(.object(["answers": answer(intent: "open_app", p: 0.9, app: "Notes", appP: 0.3)]))!
        if case .wait = VoiceBrain.gate(noApp, transcript: "abre o", done: []) {} else { XCTFail("should wait on app") }
    }
    func testIgnoresConversationAndDestructive() {
        let chat = VoiceBrain.parse(.object(["answers": answer(intent: "open_app", p: 0.9, app: "Notes", appP: 0.9, addressed: 0.2)]))!
        if case .ignore = VoiceBrain.gate(chat, transcript: "ela abriu o notas ontem", done: []) {} else { XCTFail("not addressed") }
        let bad = VoiceBrain.parse(.object(["answers": answer(intent: "quit_app", p: 0.9, app: "Notes", appP: 0.9, complete: 0.9, destructive: 0.8)]))!
        if case .ignore = VoiceBrain.gate(bad, transcript: "fecha o notas sem salvar", done: []) {} else { XCTFail("destructive") }
    }
    func testQuitAndQueryWaitForComplete() {
        let quit = VoiceBrain.parse(.object(["answers": answer(intent: "quit_app", p: 0.9, app: "Notes", appP: 0.9, complete: 0.3)]))!
        if case .wait = VoiceBrain.gate(quit, transcript: "fecha o notas", done: []) {} else { XCTFail("quit should wait") }
        let quitDone = VoiceBrain.parse(.object(["answers": answer(intent: "quit_app", p: 0.9, app: "Notes", appP: 0.9, complete: 0.8)]))!
        XCTAssertEqual(VoiceBrain.gate(quitDone, transcript: "fecha o notas", done: []), .act(.quit_app, "Notes"))
        let q = VoiceBrain.parse(.object(["answers": answer(intent: "search_web", p: 0.9, complete: 0.4)]))!
        if case .wait = VoiceBrain.gate(q, transcript: "pesquisa por pods", done: []) {} else { XCTFail("query should wait") }
        let qDone = VoiceBrain.parse(.object(["answers": answer(intent: "search_web", p: 0.9, complete: 0.9)]))!
        XCTAssertEqual(VoiceBrain.gate(qDone, transcript: "pesquisa por pods de menta", done: []), .act(.search_web, "pods de menta"))
        let url = VoiceBrain.parse(.object(["answers": answer(intent: "open_url", p: 0.9, complete: 0.9)]))!
        XCTAssertEqual(VoiceBrain.gate(url, transcript: "abre o site udiapods.com", done: []), .act(.open_url, "https://udiapods.com"))
    }
}

final class VoicePipelineTests: XCTestCase {
    func testStepDryRunAndMemory() {
        let fake = FakeJev(answer(intent: "open_app", p: 0.9, app: "Notes", appP: 0.85, complete: 0.1))
        let brain = VoiceBrain(client: fake, installed: apps)
        let u = VoiceActor.Utterance()
        let out = VoiceActor.step(brain: brain, transcript: "abre o notas e", isFinal: false, utterance: u, execute: false)
        XCTAssertTrue(out.contains("ACT open_app → Notes"), out)
        XCTAssertTrue(out.contains("dry-run"), out)
        XCTAssertTrue(u.snapshot().isEmpty)                       // dry-run never marks
        if case .array(let c)? = fake.lastRequest?["state"]?["app_candidates"] { XCTAssertEqual(c.first?.string, "Notes") } else { XCTFail("no candidates in state") }
        u.mark(.act(.open_app, "Notes"))
        let again = VoiceActor.step(brain: brain, transcript: "abre o notas e cria uma nota", isFinal: true, utterance: u, execute: false)
        XCTAssertTrue(again.contains("SKIP"), again)
        XCTAssertTrue(u.snapshot().isEmpty)                       // final resets the utterance
    }
    func testJevDownIsWaitNotCrash() {
        let fake = FakeJev(answer(intent: "open_app", p: 0.9)); fake.fail = "http 500"
        let out = VoiceActor.step(brain: VoiceBrain(client: fake, installed: apps), transcript: "abre o notas",
                                  isFinal: false, utterance: VoiceActor.Utterance(), execute: true)
        XCTAssertTrue(out.contains("WAIT (jev unavailable)"), out)
        XCTAssertTrue(out.contains("error: http 500"))
    }
    func testActorRefusesUnknownApp() {
        XCTAssertTrue(VoiceActor.perform(.act(.open_app, "Evil; rm -rf"), installed: apps).contains("refused"))
        XCTAssertEqual(VoiceActor.perform(.wait("x"), installed: apps), "no action")
    }
    func testRegistryHasVoiceTools() {
        let r = ToolRegistry(); registerAllTools(into: r)
        let names = Set(r.list().map { $0.name })
        XCTAssertTrue(names.contains("voice_decide")); XCTAssertTrue(names.contains("voice_listen"))
    }
    func testApiKeyParserShape() {
        // never asserts the value; only that lookup does not crash and returns String? shape
        _ = Voice.apiKey()
    }
}
