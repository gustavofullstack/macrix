import Foundation
import CryptoKit

/// Open-core metering + licensing (the CodexBar-style half of MACRIX).
/// - Every tools/call is counted per key-fingerprint, per tool, per UTC day.
/// - Quotas come from the license tier: free = 1000 calls/day/key (10x the
///   commercial free tier we cloned away from); pro/lifetime = unlimited.
/// - No silent blocks: over-quota calls get error -32000 naming the tier.
public enum License {
    public enum Tier: String, Sendable, CaseIterable {
        case free, starter, growth, scale, max, lifetime
        /// Monthly price in USD. Rule from the founder: price = 2x measured cost.
        public var priceUSD: Int {
            switch self {
            case .free: return 0
            case .starter: return 20
            case .growth: return 50
            case .scale: return 100
            case .max: return 200
            case .lifetime: return -1  // one-time, not monthly
            }
        }
        public var dailyQuota: Int? {
            switch self {
            case .free: return 1000
            case .starter: return 10_000
            case .growth: return 50_000
            case .scale: return 200_000
            case .max, .lifetime: return nil
            }
        }
        /// Legacy alias: v0.3 `pro` is now `growth`.
        public init?(name: String) {
            if name == "pro" { self = .growth; return }
            self.init(rawValue: name)
        }
    }

    public struct Info: Sendable {
        public let tier: Tier
        public let key: String
        public let expires: String?
    }

    static var dir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/macrix")
    }
    static var licensePath: String { (dir as NSString).appendingPathComponent("license") }
    /// Overridable so tests never touch production metering:
    /// set MACRIX_USAGE_PATH to a tmp file.
    static var usagePath: String {
        if let o = ProcessInfo.processInfo.environment["MACRIX_USAGE_PATH"], !o.isEmpty { return o }
        return (dir as NSString).appendingPathComponent("usage.json")
    }

    public static func current() -> Info {
        guard let content = try? String(contentsOfFile: licensePath, encoding: .utf8) else {
            return Info(tier: .free, key: "", expires: nil)
        }
        var tier = Tier.free, key = "", expires: String?
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("tier=") { tier = Tier(name: String(t.dropFirst(5))) ?? .free }
            if t.hasPrefix("key=") { key = String(t.dropFirst(4)) }
            if t.hasPrefix("expires=") { expires = String(t.dropFirst(8)) }
        }
        switch tier {
        case .starter, .growth, .scale:
            if let exp = expires, exp < utcDay() {
                return Info(tier: .free, key: key, expires: exp)
            }
        default: break
        }
        return Info(tier: tier, key: key, expires: expires)
    }

    public static func issue(tier: Tier, months: Int) -> String {
        // NOTE v0.3: self-issued locally. Production issuance moves to the
        // account server; the file format (tier/key/expires) stays the same.
        let key = "mx_\(tier.rawValue)_\(randomSuffix())"
        var exp = ""
        switch tier {
        case .starter, .growth, .scale:
            let d = Calendar.current.date(byAdding: .month, value: max(1, months), to: Date()) ?? Date()
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
            exp = f.string(from: d)
        default: break
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? "tier=\(tier.rawValue)\nkey=\(key)\nexpires=\(exp)\n".write(toFile: licensePath, atomically: true, encoding: .utf8)
        return key
    }

    static func randomSuffix() -> String {
        let bytes = (0..<12).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func utcDay() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }

    public static func fingerprint(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

public enum Usage {
    private static let lock = NSLock()

    struct Day: Codable {
        var date: String
        var keys: [String: [String: Int]]  // fp -> tool -> count
    }

    private static func loadLocked() -> Day {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: License.usagePath)),
           let day = try? JSONDecoder().decode(Day.self, from: data),
           day.date == License.utcDay() {
            return day
        }
        return Day(date: License.utcDay(), keys: [:])
    }

    private static func saveLocked(_ day: Day) {
        try? FileManager.default.createDirectory(atPath: License.dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(day) {
            try? data.write(to: URL(fileURLWithPath: License.usagePath))
        }
    }

    static func load() -> Day { lock.withLock { loadLocked() } }

    static func save(_ day: Day) { lock.withLock { saveLocked(day) } }

    private static func overMessage(_ day: Day, keyFP: String, tier: License.Tier) -> String? {
        guard let quota = tier.dailyQuota else { return nil }
        let total = day.keys[keyFP]?.values.reduce(0, +) ?? 0
        if total >= quota {
            return "daily quota exceeded for tier '\(tier.rawValue)' (\(quota)/day/key) — upgrade with `macrix license-issue --tier pro|lifetime`."
        }
        return nil
    }

    /// Returns nil when allowed, or an over-quota message.
    public static func check(keyFP: String, tool: String, tier: License.Tier) -> String? {
        lock.withLock { overMessage(loadLocked(), keyFP: keyFP, tier: tier) }
    }

    public static func record(keyFP: String, tool: String) {
        lock.withLock {
            var day = loadLocked()
            day.keys[keyFP, default: [:]][tool, default: 0] += 1
            saveLocked(day)
        }
    }

    /// Atomic admit: check + record under one lock so concurrent bursts
    /// cannot overshoot the quota. Returns nil when admitted, else the
    /// over-quota message (nothing recorded).
    public static func admit(keyFP: String, tool: String, tier: License.Tier) -> String? {
        lock.withLock {
            var day = loadLocked()
            if let over = overMessage(day, keyFP: keyFP, tier: tier) { return over }
            day.keys[keyFP, default: [:]][tool, default: 0] += 1
            saveLocked(day)
            return nil
        }
    }

    public static func status(keyFP: String, tier: License.Tier) -> String {
        let day = load()
        let per = day.keys[keyFP] ?? [:]
        let total = per.values.reduce(0, +)
        let quota = tier.dailyQuota.map(String.init) ?? "unlimited"
        let top = per.sorted { $0.value > $1.value }.prefix(5)
            .map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        return "tier \(tier.rawValue) | today \(total)/\(quota) | top: \(top.isEmpty ? "-" : top)"
    }
}
