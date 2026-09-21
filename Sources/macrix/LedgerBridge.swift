import Foundation

/// Adapter to the canonical accounting ledger of TriQHub (PR #2 of triqhub-os):
/// `scripts/budget_ledger.py` behind `scripts/ledger_bridge.py`, one process per
/// call, one JSON in, one JSON out. MACRIX never reimplements accounting; it
/// reserves an attempt before dispatch and settles or marks it unknown after.
///
/// Units: CLIs on subscriptions have no provider meter, so the reservation is an
/// ATTEMPT UNIT (price_version says so), not a dollar figure. The tenant is
/// separate from the JEV tenant on purpose — the two reservations never mix.
///
/// Config: ~/.config/macrix/ledger.json {"python","bridge","database","tenant"?,"cap"?,"attempt_units"?}
/// All paths absolute. Python must be ≥ 3.11 (checked on load, not assumed).
public struct LedgerBridge: Sendable {
    public let python: String, bridge: String, database: String
    public let tenant: String, cap: Int, attemptUnits: Int
    public static let priceVersion = "attempt-units-v0"

    public static var configPath: String { (NSHomeDirectory() as NSString).appendingPathComponent(".config/macrix/ledger.json") }

    public enum LoadError: Error, Equatable { case noConfig, badConfig(String), pythonTooOld(String), missing(String) }

    /// Reads the config and runs the preflight. Nil config → ledger disabled (not an error).
    public static func load(path: String = configPath) -> Result<LedgerBridge?, LoadError> {
        guard let d = FileManager.default.contents(atPath: path) else { return .success(nil) }
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: d),
              let py = v["python"]?.string, let br = v["bridge"]?.string, let db = v["database"]?.string else { return .failure(.badConfig("python, bridge, database required")) }
        for p in [py, br, db] where !p.hasPrefix("/") { return .failure(.badConfig("paths must be absolute: \(p)")) }
        guard FileManager.default.isExecutableFile(atPath: py) else { return .failure(.missing(py)) }
        guard FileManager.default.isReadableFile(atPath: br) else { return .failure(.missing(br)) }
        let (code, out) = runProcess(py, ["-c", "import sys; print('%d.%d' % sys.version_info[:2])"], timeoutSeconds: 10)
        let ver = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = ver.split(separator: ".").compactMap { Int($0) }
        guard code == 0, parts.count == 2, (parts[0], parts[1]) >= (3, 11) else { return .failure(.pythonTooOld(ver.isEmpty ? "unknown" : ver)) }
        return .success(LedgerBridge(python: py, bridge: br, database: db, tenant: v["tenant"]?.string ?? "macrix-cli",
                                     cap: v["cap"]?.int ?? 1_000_000, attemptUnits: v["attempt_units"]?.int ?? 1000))
    }

    public struct Balance: Equatable, Sendable { public var cap: Int, held: Int, spent: Int, remaining: Int, frozen: Bool, overBudget: Bool }

    /// One bridge call. Errors carry the ledger's own code (never the payload).
    public func call(_ payload: [String: JSONValue]) -> Result<Balance, JevError> {
        guard let body = try? JSONEncoder().encode(JSONValue.object(payload)), let s = String(data: body, encoding: .utf8) else { return .failure(JevError("encode")) }
        let (code, out) = runProcess(python, ["-S", bridge, "--database", database], timeoutSeconds: 20, stdin: s)
        guard let d = out.data(using: .utf8), let v = try? JSONDecoder().decode(JSONValue.self, from: d) else { return .failure(JevError(code == 0 ? "INVALID_LEDGER_RESPONSE" : "LEDGER_UNAVAILABLE")) }
        guard v["ok"]?.bool == true, let b = v["balance"] else { return .failure(JevError(v["code"]?.string ?? "LEDGER_ERROR")) }
        return .success(Balance(cap: b["cap"]?.int ?? 0, held: b["held"]?.int ?? 0, spent: b["spent"]?.int ?? 0, remaining: b["remaining"]?.int ?? 0,
                                frozen: b["frozen"]?.bool ?? false, overBudget: b["over_budget"]?.bool ?? false))
    }

    func t(_ action: String, _ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var p: [String: JSONValue] = ["action": .string(action), "tenant": .string(tenant)]; for (k, v) in extra { p[k] = v }; return p
    }
    public func openAccount() -> Result<Balance, JevError> {
        let r = call(t("open_account", ["cap": .number(Double(cap))]))
        if case .failure(let e) = r, e.message.contains("EXISTS") || e.message.contains("ALREADY") { return balance() }
        return r
    }
    public func balance() -> Result<Balance, JevError> { call(t("balance")) }
    public func reserve(_ id: String) -> Result<Balance, JevError> {
        call(t("reserve", ["event_id": .string(id), "nano_usd": .number(Double(attemptUnits)), "price_version": .string(LedgerBridge.priceVersion)]))
    }
    public func dispatch(_ id: String) -> Result<Balance, JevError> { call(t("dispatch", ["event_id": .string(id)])) }
    public func settle(_ id: String) -> Result<Balance, JevError> { call(t("settle", ["event_id": .string(id), "actual": .number(Double(attemptUnits))])) }
    public func markUnknown(_ id: String) -> Result<Balance, JevError> { call(t("mark_unknown", ["event_id": .string(id)])) }
    public func cancel(_ id: String) -> Result<Balance, JevError> { call(t("cancel", ["event_id": .string(id)])) }

    public static func describe(_ r: Result<LedgerBridge?, LoadError>) -> String {
        switch r {
        case .success(nil): return "ledger: off (no ~/.config/macrix/ledger.json)"
        case .success(let b?): return "ledger: on · tenant \(b.tenant) · \(b.attemptUnits) units/attempt · \(b.database)"
        case .failure(let e): return "ledger: misconfigured (\(e))"
        }
    }
}
