import Foundation
import AppKit

/// G1 net family: DNS, latency, local IPs — plus clipboard write.
/// All in-process or via system ping; no external API dependency.
public enum Net {
    static func dns(_ host: String) -> String {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, h.count < 256, !h.contains(" ") else { return "invalid host." }
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = h.withCString { getaddrinfo($0, nil, nil, &res) }
        guard rc == 0, let list = res else { return "dns failed." }
        defer { freeaddrinfo(list) }
        var out: [String] = []
        var cur: UnsafeMutablePointer<addrinfo>? = list
        while let node = cur, out.count < 10 {
            var hostbuf = [CChar](repeating: 0, count: 256)
            if getnameinfo(node.pointee.ai_addr, node.pointee.ai_addrlen,
                           &hostbuf, socklen_t(hostbuf.count), nil, 0,
                           NI_NUMERICHOST) == 0 {
                out.append(String(cString: hostbuf))
            }
            cur = node.pointee.ai_next
        }
        return out.isEmpty ? "no addresses." : out.joined(separator: "\n")
    }
    static func ping(_ host: String) -> String {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, h.count < 256, !h.contains(" ") else { return "invalid host." }
        let (_, out) = runProcess("/sbin/ping", ["-c", "2", "-t", "5", h], timeoutSeconds: 20)
        let lines = out.split(separator: "\n")
        let summary = lines.filter { $0.contains("round-trip") || $0.contains("packet loss") }
        // Even 100% loss is data (e.g. ICMP filtered); only empty output is failure.
        return summary.isEmpty ? "ping failed." : summary.joined(separator: " | ")
    }
    static func ips() -> String {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return "unavailable." }
        defer { freeifaddrs(first) }
        var out: [String] = []
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let node = cur {
            let flags = node.pointee.ifa_flags
            if (flags & UInt32(IFF_UP | IFF_RUNNING)) == UInt32(IFF_UP | IFF_RUNNING),
               let sa = node.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var buf = [CChar](repeating: 0, count: 256)
                let s = unsafeBitCast(sa, to: UnsafePointer<sockaddr_in>.self)
                var addr = s.pointee.sin_addr
                if inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count)) != nil {
                    out.append("\(String(cString: node.pointee.ifa_name)): \(String(cString: buf))")
                }
            }
            cur = node.pointee.ifa_next
        }
        return out.isEmpty ? "no addresses." : out.joined(separator: "\n")
    }
    static func clipWrite(_ text: String) -> String {
        guard !text.isEmpty, text.count <= (100 << 10) else { return "empty or over 100KB." }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(text, forType: .string) ? "clipboard set (\(text.count) chars)" : "clipboard failed."
    }
}
