import Foundation
import AppKit
#if canImport(Speech)
import Speech
import AVFoundation
#endif

/// Voice → Jev → action, before the sentence ends.
///
/// The pattern from Andy Gao's demo (X, 18/09/2026): speech is transcribed
/// in streaming; EVERY partial transcript becomes ONE Jev request carrying a
/// handful of typed questions (intent, target app, complete?, addressed to
/// me?, destructive?). Jev answers in ~100–500 ms with probabilities, and
/// code — not the model — decides to act, wait or ignore. Jev never
/// generates text: app names and URLs are extracted by code as candidates
/// and Jev only picks one.
///
/// Pure logic (request, parsing, gating, candidates) is in `VoiceBrain`
/// and tested offline with a fake client. Network, microphone and `open -a`
/// live at the edges.
public enum Voice {
    public static let model = "jev-1.13.0"   // pinned: calibration must not drift under our thresholds
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    // ponytail: fixed thresholds; make them per-intent once we have real misfire data
    public static let actIntent = 0.70
    public static let actTarget = 0.60
    public static let minAddressed = 0.50
    public static let needComplete = 0.60
    public static let maxDestructive = 0.70

    public enum Intent: String, CaseIterable, Sendable {
        case open_app, quit_app, open_url, search_web, none
    }

    public struct Answers: Equatable, Sendable {
        public var intent: Intent
        public var intentP: Double
        public var app: String?          // chosen app name (nil == none)
        public var appP: Double
        public var complete: Double
        public var addressed: Double
        public var destructive: Double
    }

    public enum Verdict: Equatable, Sendable {
        case act(Intent, String)        // intent + target (app name, url or query)
        case wait(String)               // reason
        case ignore(String)
        case skip(String)               // already done for this utterance
    }

    /// API key: env first, then the station vault (600, local). Never logged.
    public static func apiKey() -> String? {
        if let k = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !k.isEmpty { return k }
        let vault = (NSHomeDirectory() as NSString).appendingPathComponent(".config/frota/credenciais.env")
        guard let text = try? String(contentsOfFile: vault, encoding: .utf8) else { return nil }
        for raw in text.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard line.hasPrefix("TYPESAFE_API_KEY=") else { continue }
            var v = String(line.dropFirst("TYPESAFE_API_KEY=".count))
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !v.isEmpty { return v }
        }
        return nil
    }
}

// MARK: - Jev client (protocol so tests inject a fake)

public struct JevError: Error, Equatable, Sendable { public let message: String; public init(_ m: String) { message = m } }

public protocol JevClient: Sendable {
    /// Sends one System One request; returns the raw response object or an error.
    func evaluate(_ request: JSONValue) -> Result<JSONValue, JevError>
}

public struct TypeSafeHTTP: JevClient {
    public let key: String
    public var timeout: TimeInterval = 5
    public init(key: String) { self.key = key }

    public func evaluate(_ request: JSONValue) -> Result<JSONValue, JevError> {
        var req = URLRequest(url: Voice.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(request)
        let sem = DispatchSemaphore(value: 0)
        var out: Result<JSONValue, JevError> = .failure(JevError("no response"))
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { out = .failure(JevError("network: \(err.localizedDescription)")); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data else { out = .failure(JevError("http \(code): empty")); return }
            guard code == 200 else { out = .failure(JevError("http \(code)")); return }   // body may echo the key: never surface it
            guard let v = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                out = .failure(JevError("http 200: not json")); return
            }
            out = .success(v)
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 1)
        return out
    }
}

// MARK: - Installed apps + candidate extraction (code, not the model)

public enum Apps {
    static let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                        (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]

    /// pt-BR spoken names → bundle display names. Small on purpose.
    public static let aliases: [String: String] = [
        "notas": "Notes", "nota": "Notes", "calculadora": "Calculator", "calendario": "Calendar",
        "agenda": "Calendar", "lembretes": "Reminders", "lembrete": "Reminders", "mensagens": "Messages",
        "fotos": "Photos", "musica": "Music", "mapas": "Maps", "ajustes": "System Settings",
        "configuracoes": "System Settings", "preferencias": "System Settings", "navegador": "Safari",
        "email": "Mail", "e-mail": "Mail", "correio": "Mail", "terminal": "Terminal", "relogio": "Clock",
        "clima": "Weather", "tempo": "Weather", "contatos": "Contacts", "atalhos": "Shortcuts",
        "loja": "App Store", "previa": "Preview", "visualizador": "Preview", "dicionario": "Dictionary",
    ]

    public static func installed() -> [String] {
        var names = Set<String>()
        for root in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for item in items where item.hasSuffix(".app") { names.insert(String(item.dropLast(4))) }
        }
        return names.sorted()
    }

    public static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
    }

    /// Candidate app names for a transcript: alias hits + apps whose
    /// normalized name contains a spoken word (≥3 chars) or vice versa.
    /// Bounded to 8 so the Choice stays small and fast.
    public static func candidates(in transcript: String, installed: [String]) -> [String] {
        let words = normalize(transcript)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        var out: [String] = []
        func add(_ n: String) { if !out.contains(n) { out.append(n) } }
        for w in words {
            if let a = aliases[w], installed.contains(a) { add(a) }
        }
        for app in installed {
            let n = normalize(app)
            let appWords = n.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            for w in words {
                if appWords.contains(where: { $0 == w || ($0.count >= 4 && $0.hasPrefix(w) && w.count >= 4) }) ||
                   (w.count >= 5 && n.replacingOccurrences(of: " ", with: "") == w) {
                    add(app); break
                }
            }
            if out.count >= 8 { break }
        }
        return Array(out.prefix(8))
    }

    /// First http(s) URL or bare domain in the text, normalized to https.
    public static func urlSpan(in transcript: String) -> String? {
        for tok in transcript.split(separator: " ").map(String.init) {
            let t = tok.trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?"))
            if t.hasPrefix("http://") || t.hasPrefix("https://") { return t }
            let parts = t.split(separator: ".")
            if parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }),
               ["com", "br", "net", "org", "io", "dev", "ai", "app", "cloud", "tech"].contains(String(parts.last!).lowercased()) {
                return "https://" + t.lowercased()
            }
        }
        return nil
    }

    /// Words after the search verb ("pesquisa|pesquise|procura|procure|busca|busque|search for|search|google").
    public static func querySpan(in transcript: String) -> String? {
        let n = transcript.lowercased()
        let verbs = ["pesquisa por ", "pesquise por ", "pesquisa ", "pesquise ", "procura por ", "procure por ",
                     "procura ", "procure ", "busca por ", "busque por ", "busca ", "busque ",
                     "search for ", "search ", "google "]
        for v in verbs {
            if let r = n.range(of: v) {
                let q = String(n[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let cut = q.replacingOccurrences(of: " na internet", with: "").replacingOccurrences(of: " no google", with: "")
                    .replacingOccurrences(of: " on the web", with: "")
                return cut.isEmpty ? nil : cut
            }
        }
        return nil
    }
}

// MARK: - Brain: request, parse, gate

public struct VoiceBrain: Sendable {
    public let client: JevClient
    public let installed: [String]
    public init(client: JevClient, installed: [String]) { self.client = client; self.installed = installed }

    /// One Jev request per partial transcript, all questions in parallel.
    public static func request(transcript: String, isFinal: Bool, candidates: [String]) -> JSONValue {
        var questions: [String: JSONValue] = [
            "intent": .object([
                "type": .string("choice"),
                "instructions": .string("The speaker is dictating a command to a macOS assistant, possibly mid-sentence (Portuguese or English). Which action is being asked?"),
                "criteria": .object([
                    "open_app": .string("open / launch / show a macOS application (abrir, abre, abra, mostra, lança)"),
                    "quit_app": .string("quit / close an application (fechar, fecha, encerra, sai do)"),
                    "open_url": .string("open a specific website or URL (abre o site, vai para ... .com)"),
                    "search_web": .string("search the web for something (pesquisa, procura, busca, google, search for)"),
                    "none": .string("not a command, unrelated speech, or too little said to tell"),
                ]),
            ]),
            "complete": .object([
                "type": .string("noul"),
                "instructions": .string("Has the speaker finished stating the command (nothing essential still missing)?"),
                "criteria": .object(["true": .string("the action and its target are both already said"),
                                     "false": .string("the sentence is cut mid-way or the target is not yet said")]),
            ]),
            "addressed": .object([
                "type": .string("noul"),
                "instructions": .string("Is this speech an instruction meant for the computer assistant, rather than conversation with another person or reading aloud?"),
            ]),
            "destructive": .object([
                "type": .string("noul"),
                "instructions": .string("Would executing this lose data, close unsaved work, or be hard to undo?"),
            ]),
        ]
        if !candidates.isEmpty {
            var crit: [String: JSONValue] = ["none": .string("no application named or a different one than the listed")]
            for c in candidates { crit[c] = .string("the app \(c) (may be said in Portuguese or English)") }
            questions["app"] = .object([
                "type": .string("choice"),
                "instructions": .string("Which application is the speaker referring to?"),
                "criteria": .object(crit),
            ])
        }
        return .object([
            "model": .string(Voice.model),
            "state": .object(["transcript": .string(transcript), "is_final": .bool(isFinal),
                              "app_candidates": .array(candidates.map { .string($0) })]),
            "questions": .object(questions),
        ])
    }

    public static func parse(_ response: JSONValue) -> Voice.Answers? {
        guard let answers = response["answers"] else { return nil }
        guard let intentA = answers["intent"], let choice = intentA["choice"]?.string,
              let intent = Voice.Intent(rawValue: choice) else { return nil }
        let intentP = intentA["probabilities"]?[choice]?.double ?? intentA["confidence"]?.double ?? 0
        var app: String? = nil; var appP = 0.0
        if let a = answers["app"], let c = a["choice"]?.string {
            appP = a["probabilities"]?[c]?.double ?? a["confidence"]?.double ?? 0
            app = c == "none" ? nil : c
        }
        return Voice.Answers(intent: intent, intentP: intentP, app: app, appP: appP,
                             complete: answers["complete"]?["noul"]?.double ?? 0,
                             addressed: answers["addressed"]?["noul"]?.double ?? 0,
                             destructive: answers["destructive"]?["noul"]?.double ?? 0)
    }

    /// The gate. Opening an app fires mid-sentence; anything that needs the
    /// whole sentence (a query, a URL) or that can hurt (quit) waits for `complete`.
    public static func gate(_ a: Voice.Answers, transcript: String, done: Set<String>) -> Voice.Verdict {
        if a.addressed < Voice.minAddressed { return .ignore("not addressed to me (\(fmt(a.addressed)))") }
        if a.intent == .none || a.intentP < Voice.actIntent { return .wait("intent \(a.intent.rawValue) \(fmt(a.intentP)) < \(fmt(Voice.actIntent))") }
        if a.destructive >= Voice.maxDestructive { return .ignore("destructive \(fmt(a.destructive))") }
        switch a.intent {
        case .open_app, .quit_app:
            guard let app = a.app, a.appP >= Voice.actTarget else { return .wait("app \(a.app ?? "none") \(fmt(a.appP)) < \(fmt(Voice.actTarget))") }
            if a.intent == .quit_app, a.complete < Voice.needComplete { return .wait("quit waits for complete \(fmt(a.complete))") }
            let key = "\(a.intent.rawValue):\(app)"
            return done.contains(key) ? .skip(key) : .act(a.intent, app)
        case .open_url:
            guard let u = Apps.urlSpan(in: transcript) else { return .wait("no url span yet") }
            guard a.complete >= Voice.needComplete else { return .wait("url waits for complete \(fmt(a.complete))") }
            let key = "open_url:\(u)"
            return done.contains(key) ? .skip(key) : .act(.open_url, u)
        case .search_web:
            guard let q = Apps.querySpan(in: transcript) else { return .wait("no query span yet") }
            guard a.complete >= Voice.needComplete else { return .wait("query waits for complete \(fmt(a.complete))") }
            let key = "search_web:\(q)"
            return done.contains(key) ? .skip(key) : .act(.search_web, q)
        case .none:
            return .wait("none")
        }
    }

    static func fmt(_ d: Double) -> String { String(format: "%.2f", d) }

    /// Full step: candidates → Jev → gate. Returns answers + verdict + latency.
    public func decide(transcript: String, isFinal: Bool, done: Set<String>) -> (Voice.Answers?, Voice.Verdict, Double, String?) {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 600 else { return (nil, .ignore("empty or too long"), 0, nil) }
        let cands = Apps.candidates(in: t, installed: installed)
        let req = VoiceBrain.request(transcript: t, isFinal: isFinal, candidates: cands)
        let t0 = Date()
        switch client.evaluate(req) {
        case .failure(let e): return (nil, .wait("jev unavailable"), Date().timeIntervalSince(t0) * 1000, e.message)
        case .success(let resp):
            let ms = Date().timeIntervalSince(t0) * 1000
            guard let a = VoiceBrain.parse(resp) else { return (nil, .wait("unparseable answer"), ms, "bad response shape") }
            return (a, VoiceBrain.gate(a, transcript: t, done: done), ms, nil)
        }
    }
}

// MARK: - Actor: the only place that touches the machine

public enum VoiceActor {
    /// Executes a verdict. `installed` is the allow-list for app names.
    public static func perform(_ v: Voice.Verdict, installed: [String]) -> String {
        guard case .act(let intent, let target) = v else { return "no action" }
        switch intent {
        case .open_app:
            guard installed.contains(target) else { return "refused: unknown app \(target)" }
            let (code, _) = runProcess("/usr/bin/open", ["-a", target], timeoutSeconds: 15)
            return code == 0 ? "opened \(target)" : "open failed: \(target)"
        case .quit_app:
            guard installed.contains(target) else { return "refused: unknown app \(target)" }
            return Notify.quitApp(target)
        case .open_url:
            return WebClip.open(target) + " " + target
        case .search_web:
            let q = target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return WebClip.open("https://duckduckgo.com/?q=\(q)") + " search: \(target)"
        case .none:
            return "no action"
        }
    }

    /// One utterance's memory: what already ran, so partials don't repeat it.
    public final class Utterance: @unchecked Sendable {
        private let lock = NSLock()
        private var done = Set<String>()
        public init() {}
        public func snapshot() -> Set<String> { lock.withLock { done } }
        public func mark(_ v: Voice.Verdict) {
            guard case .act(let i, let t) = v else { return }
            lock.withLock { _ = done.insert("\(i.rawValue):\(t)") }
        }
        public func reset() { lock.withLock { done.removeAll() } }
    }

    /// Text-in pipeline used by the `voice_decide` tool and by `voice_listen`.
    public static func step(brain: VoiceBrain, transcript: String, isFinal: Bool,
                            utterance: Utterance, execute: Bool) -> String {
        let (a, verdict, ms, err) = brain.decide(transcript: transcript, isFinal: isFinal, done: utterance.snapshot())
        var lines: [String] = ["transcript: \(transcript)\(isFinal ? " [final]" : "")", "jev: \(Int(ms)) ms"]
        if let err = err { lines.append("error: \(err)") }
        if let a = a {
            lines.append("intent=\(a.intent.rawValue) \(VoiceBrain.fmt(a.intentP)) app=\(a.app ?? "none") \(VoiceBrain.fmt(a.appP)) complete=\(VoiceBrain.fmt(a.complete)) addressed=\(VoiceBrain.fmt(a.addressed)) destructive=\(VoiceBrain.fmt(a.destructive))")
        }
        switch verdict {
        case .act(let i, let t):
            lines.append("verdict: ACT \(i.rawValue) → \(t)")
            if execute {
                lines.append("result: " + perform(verdict, installed: brain.installed))
                utterance.mark(verdict)
            } else { lines.append("result: dry-run (execute=false)") }
        case .wait(let r): lines.append("verdict: WAIT (\(r))")
        case .ignore(let r): lines.append("verdict: IGNORE (\(r))")
        case .skip(let k): lines.append("verdict: SKIP already done (\(k))")
        }
        if isFinal { utterance.reset() }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Microphone: streaming partials from Speech.framework

#if canImport(Speech)
public final class SpeechListener: NSObject, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    public let onTranscript: (String, Bool) -> Void

    public init(locale: String, onTranscript: @escaping (String, Bool) -> Void) {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
        self.onTranscript = onTranscript
    }

    /// TCC callbacks land on the main queue: spin the run loop instead of
    /// blocking it, or the answer (and the dialog) never arrives.
    public static func authorize() -> String? {
        func spin(until done: () -> Bool, seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
            spin(until: { SFSpeechRecognizer.authorizationStatus() != .notDetermined }, seconds: 120)
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .denied: return "speech recognition denied (System Settings → Privacy → Speech Recognition)."
        case .restricted: return "speech recognition restricted on this Mac."
        default: return "speech recognition not authorized (no answer to the permission dialog)."
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            spin(until: { AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined }, seconds: 120)
        }
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? nil
            : "microphone denied (System Settings → Privacy → Microphone)."
    }

    /// Starts streaming; each partial and the final go to `onTranscript`.
    public func start() throws {
        guard let rec = recognizer, rec.isAvailable else {
            throw NSError(domain: "macrix.voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "recognizer unavailable for locale"])
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // ponytail: server recognition allowed; force on-device only when the model is proven downloaded
        request = req
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        fputs("voice: input \(Int(fmt.sampleRate)) Hz x\(fmt.channelCount) · on-device \(rec.supportsOnDeviceRecognition ? "yes" : "no") · locale \(rec.locale.identifier)\n", stderr)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "macrix.voice", code: 2, userInfo: [NSLocalizedDescriptionKey: "no audio input device (format \(fmt))"])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in self?.request?.append(buf) }
        engine.prepare()
        try engine.start()
        task = rec.recognitionTask(with: req, resultHandler: handler)
    }

    private lazy var handler: (SFSpeechRecognitionResult?, Error?) -> Void = { [weak self] result, error in
        guard let self = self else { return }
        if let r = result {
            self.onTranscript(r.bestTranscription.formattedString, r.isFinal)
            if r.isFinal { self.rearm() }
        } else if let e = error {
            fputs("voice: recognizer error: \(e.localizedDescription)\n", stderr)
            Thread.sleep(forTimeInterval: 0.5)
            self.rearm()
        }
    }

    /// After a final (or an error) start a fresh request so listening continues.
    private func rearm() {
        guard let rec = recognizer, engine.isRunning else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        task = rec.recognitionTask(with: req, resultHandler: handler)
    }

    public func stop() {
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Same pipeline fed by an audio FILE (Speech URL request, partials included).
/// Proof path when the default mic is elsewhere (AirPods, lid closed) and a
/// deterministic fixture for tests: `say -o x.aiff "abre o notas e cria..."`.
public enum VoiceFile {
    public static func run(path: String, locale: String, execute: Bool, log: @escaping (String) -> Void) -> String {
        guard let key = Voice.apiKey() else { return "voice unavailable: TYPESAFE_API_KEY not in env nor in ~/.config/frota/credenciais.env." }
        guard FileManager.default.isReadableFile(atPath: path) else { return "voice-file: unreadable \(path)" }
        if let denied = SpeechListener.authorize() { return "voice unavailable: \(denied)" }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: locale)), rec.isAvailable else { return "voice unavailable: recognizer for \(locale)" }
        let brain = VoiceBrain(client: TypeSafeHTTP(key: key), installed: Apps.installed())
        let utterance = VoiceActor.Utterance()
        let req = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
        req.shouldReportPartialResults = true
        let lock = NSLock(); var out: [String] = []; var errored = false
        let q = DispatchQueue(label: "macrix.voice.file")
        let t0 = Date()
        // Each final closes one utterance; the file may hold several. Stop when the task itself ends.
        let task = rec.recognitionTask(with: req) { result, error in
            if let r = result {
                let text = r.bestTranscription.formattedString; let fin = r.isFinal
                let at = Int(Date().timeIntervalSince(t0) * 1000)
                q.async {
                    let line = "t+\(at) ms\n" + VoiceActor.step(brain: brain, transcript: text, isFinal: fin, utterance: utterance, execute: execute)
                    lock.lock(); out.append(line); lock.unlock()
                    log(line)
                }
            } else if let e = error {
                lock.lock(); out.append("recognizer error: \(e.localizedDescription)"); errored = true; lock.unlock()
            }
        }
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            lock.lock(); let bad = errored; lock.unlock()
            if bad || task.state == .completed { break }
        }
        q.sync {}
        lock.lock(); let all = out; lock.unlock()
        return all.isEmpty ? "voice-file: nothing recognized in \(path)" : all.joined(separator: "\n---\n")
    }
}

/// Listen for `seconds`, run the brain on every partial (coalesced: one Jev
/// request in flight, always on the latest transcript), act, return the log.
public enum VoiceLoop {
    public static func run(seconds: Int, locale: String, execute: Bool, log: @escaping (String) -> Void) -> String {
        guard let key = Voice.apiKey() else { return "voice unavailable: TYPESAFE_API_KEY not in env nor in ~/.config/frota/credenciais.env." }
        if let denied = SpeechListener.authorize() { return "voice unavailable: \(denied)" }
        let brain = VoiceBrain(client: TypeSafeHTTP(key: key), installed: Apps.installed())
        let utterance = VoiceActor.Utterance()
        let q = DispatchQueue(label: "macrix.voice.brain")
        let lock = NSLock()
        var latest: (String, Bool)? = nil
        var inFlight = false
        var transcript: [String] = []
        func pump() {
            lock.lock()
            guard !inFlight, let (t, f) = latest else { lock.unlock(); return }
            latest = nil; inFlight = true
            lock.unlock()
            q.async {
                let out = VoiceActor.step(brain: brain, transcript: t, isFinal: f, utterance: utterance, execute: execute)
                lock.lock(); transcript.append(out); inFlight = false; lock.unlock()
                log(out)
                pump()
            }
        }
        let listener = SpeechListener(locale: locale) { text, isFinal in
            lock.lock(); latest = (text, isFinal); lock.unlock()
            pump()
        }
        do { try listener.start() } catch { return "voice unavailable: \(error.localizedDescription)" }
        let deadline = Date().addingTimeInterval(TimeInterval(max(1, min(seconds, 300))))
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        listener.stop()
        Thread.sleep(forTimeInterval: 0.3)
        lock.lock(); let all = transcript; lock.unlock()
        return all.isEmpty ? "listened \(seconds)s: nothing recognized." : all.joined(separator: "\n---\n")
    }
}
#endif
