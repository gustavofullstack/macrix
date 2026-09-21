import Foundation
import CryptoKit

/// Open-core metering + licensing (the CodexBar-style half of MACRIX).
/// - Every tools/call is counted per key-fingerprint, per tool, per UTC day.
/// - Quotas come from the license tier: free = 1000 calls/day/key (10x the
///   commercial free tier we cloned away from); pro/lifetime = unlimited.
/// - No silent blocks: over-quota calls get error -32000 naming the tier.
public enum License {
    public enum Tier: String, Sendable {
        case free, pro, lifetime
        public var dailyQuota: Int? {
            switch self {
            case .free: return 1000
            case .pro, .lifetime: return nil
            }
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
    static var usagePath: String { (dir as NSString).appendingPathComponent("usage.json") }

    public static func current() -> Info {
        guard let content = try? String(contentsOfFile: licensePath, encoding: .utf8) else {
            return Info(tier: .free, key: "", expires: nil)
        }
        var tier = Tier.free, key = "", expires: String?
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("tier=") { tier = Tier(rawValue: String(t.dropFirst(5))) ?? .free }
            if t.hasPrefix("key=") { key = String(t.dropFirst(4)) }
            if t.hasPrefix("expires=") { expires = String(t.dropFirst(8)) }
        }
        if tier == .pro, let exp = expires, exp < utcDay() {
            return Info(tier: .free, key: key, expires: exp)
        }
        return Info(tier: tier, key: key, expires: expires)
    }

    public static func issue(tier: Tier, months: Int) -> String {
        // NOTE v0.3: self-issued locally. Production issuance moves to the
        // account server; the file format (tier/key/expires) stays the same.
        let key = "mx_\(tier.rawValue)_\(randomSuffix())"
        var exp = ""
        if tier == .pro {
            let d = Calendar.current.date(byAdding: .month, value: max(1, months), to: Date()) ?? Date()
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
            exp = f.string(from: d)
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

    static func load() -> Day {
        lock.withLock {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: License.usagePath)),
               var day = try? JSONDecoder().decode(Day.self, from: data),
               day.date == License.utcDay() {
                return day
            }
            return Day(date: License.utcDay(), keys: [:])
        }
    }

    static func save(_ day: Day) {
        lock.withLock {
            try? FileManager.default.createDirectory(atPath: License.dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(day) {
                try? data.write(to: URL(fileURLWithPath: License.usagePath))
            }
        }
    }

    /// Returns nil when allowed, or an over-quota message.
    public static func check(keyFP: String, tool: String, tier: License.Tier) -> String? {
        guard let quota = tier.dailyQuota else { return nil }
        var day = load()
        let used = day.keys[keyFP]?[tool] ?? 0
        let total = day.keys[keyFP]?.values.reduce(0, +) ?? 0
        _ = used
        if total >= quota {
            return "daily quota exceeded for tier '\(tier.rawValue)' (\(quota)/day/key) — upgrade with `macrix license-issue --tier pro|lifetime`."
        }
        return nil
    }

    public static func record(keyFP: String, tool: String) {
        var day = load()
        day.keys[keyFP, default: [:]][tool, default: 0] += 1
        save(day)
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
