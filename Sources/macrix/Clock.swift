import Foundation

/// v0.17 clock family (G1): local time + world times for IANA zones.
public enum Clock {
    static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let tz = TimeZone.current.identifier
        return "\(f.string(from: Date())) (\(tz))"
    }

    static func world(_ zones: [String]) -> String {
        guard !zones.isEmpty, zones.count <= 5 else { return "pass 1-5 IANA zone names." }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var lines: [String] = []
        for z in zones {
            guard let tz = TimeZone(identifier: z) else {
                lines.append("\(z): unknown zone")
                continue
            }
            f.timeZone = tz
            lines.append("\(z): \(f.string(from: Date()))")
        }
        return lines.joined(separator: "\n")
    }
}
