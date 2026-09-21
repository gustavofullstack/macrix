import Foundation
import Network

/// Minimal concurrent HTTP/1.1 server on NWListener. One connection per
/// task; the shared ToolRegistry is lock-guarded, so any number of agents
/// may call tools at the same time. There is deliberately no rate limiter.
public final class HTTPServer: @unchecked Sendable {
    public let port: UInt16
    private let registry: ToolRegistry
    private let keys: Set<String>
    private let listener: NWListener
    private let statsLock = NSLock()
    private var _totalRequests: Int = 0

    public var totalRequests: Int { statsLock.withLock { _totalRequests } }

    private let startedAt = Date()

    public init(port: UInt16, registry: ToolRegistry, keys: Set<String>) throws {
        self.port = port
        self.registry = registry
        self.keys = keys
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Explicit loopback bind: the only way in from outside is the Cloudflare tunnel.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!)
        self.listener = try NWListener(using: params)
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: .global(qos: .userInitiated))
            Task { await self.handle(connection: conn) }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    public func waitReady(timeout: Double = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if listener.state == .ready { return true }
            if case .failed = listener.state { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return listener.state == .ready
    }

    private func bump() { statsLock.withLock { _totalRequests += 1 } }

    private func handle(connection: NWConnection) async {
        defer { connection.cancel() }
        guard let raw = await recvRequest(on: connection),
              let req = HTTPRequest.parse(raw) else { return }
        bump()
        if req.method == "BAD" {
            send(connection: connection, status: "400 Bad Request", headers: [:], body: Data("invalid Content-Length".utf8)); return
        }
        if let origin = req.headers["origin"], !HTTPPolicy.originAllowed(origin, port: port) {
            send(connection: connection, status: "403 Forbidden", headers: [:], body: Data("origin not allowed".utf8)); return
        }
        let isPublic = HTTPPolicy.isPublic(headers: req.headers)
        if req.method == "GET", req.path == "/health" {
            let body = "{\"status\":\"ok\",\"server\":\"\(mcpServerName)\",\"version\":\"\(mcpServerVersion)\",\"requests\":\(totalRequests),\"tier\":\"\(License.current().tier.rawValue)\"}"
            send(connection: connection, status: "200 OK", headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            return
        }
        if req.method == "GET", req.path == "/" {
            let up = Int(Date().timeIntervalSince(startedAt))
            let page = Console.html(version: mcpServerVersion, tier: License.current().tier.rawValue,
                                    tools: registry.list().count, requests: totalRequests, uptime: up)
            send(connection: connection, status: "200 OK", headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(page.utf8))
            return
        }
        if req.method == "GET", req.path == "/catalog" {
            let body = Console.catalog(registry.list())
            send(connection: connection, status: "200 OK", headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            return
        }
        if req.method == "GET", req.path == "/usage" {
            if isPublic { send(connection: connection, status: "404 Not Found", headers: [:], body: Data()); return }
            guard let token = Auth.token(from: req.headers["authorization"]), keys.contains(token) else {
                send(connection: connection, status: "401 Unauthorized", headers: [:], body: Data())
                return
            }
            let tier = License.current().tier
            let body = Console.usageJSON(fp: License.fingerprint(token), tier: tier)
            send(connection: connection, status: "200 OK", headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            return
        }
        guard req.method == "POST", req.path == "/mcp" else {
            send(connection: connection, status: "404 Not Found", headers: [:], body: Data())
            return
        }
        guard let token = Auth.token(from: req.headers["authorization"]), keys.contains(token) else {
            send(connection: connection, status: "401 Unauthorized",
                 headers: ["WWW-Authenticate": "Bearer realm=\"macrix\", scope=\"mcp:*\""],
                 body: Data())
            return
        }
        let decoder = JSONDecoder()
        guard let rpc = try? decoder.decode(JSONValue.self, from: req.body) else {
            let err = try! JSONEncoder().encode(jsonError(code: -32700, message: "parse error", id: nil))
            send(connection: connection, status: "200 OK", headers: ["Content-Type": "application/json"], body: err)
            return
        }
        let sessionID = UUID().uuidString
        let fp = License.fingerprint(token)
        let tier = License.current().tier
        if case .object(let o) = rpc, o["method"]?.string == "tools/call" {
            let tname = o["params"]?["name"]?.string ?? "?"
            if isPublic, !HTTPPolicy.publicTool(tname) {
                let err = try! JSONEncoder().encode(jsonError(code: -32001, message: "tool \(tname) is not available on the public surface (showcase only); use the local endpoint", id: o["id"]))
                send(connection: connection, status: "200 OK", headers: ["Content-Type": "application/json"], body: err)
                return
            }
            if let over = Usage.admit(keyFP: fp, tool: tname, tier: tier) {
                let err = try! JSONEncoder().encode(jsonError(code: -32000, message: over, id: o["id"]))
                send(connection: connection, status: "200 OK", headers: ["Content-Type": "application/json"], body: err)
                return
            }
            if let resp = await MCPDispatcher.handle(request: rpc, registry: registry) {
                let data = (try? JSONEncoder().encode(resp)) ?? Data()
                send(connection: connection, status: "200 OK",
                     headers: ["Content-Type": "application/json", "Mcp-Session-Id": sessionID],
                     body: data)
            } else {
                send(connection: connection, status: "202 Accepted",
                     headers: ["Mcp-Session-Id": sessionID], body: Data())
            }
            return
        }
        if let resp = await MCPDispatcher.handle(request: rpc, registry: registry) {
            let data = (try? JSONEncoder().encode(resp)) ?? Data()
            send(connection: connection, status: "200 OK",
                 headers: ["Content-Type": "application/json", "Mcp-Session-Id": sessionID],
                 body: data)
        } else {
            send(connection: connection, status: "202 Accepted",
                 headers: ["Mcp-Session-Id": sessionID], body: Data())
        }
    }

    private func recvRequest(on conn: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            var acc = Data()
            func recv() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isDone, err in
                    if let data, !data.isEmpty { acc.append(data) }
                    if let r = HTTPRequest.parse(acc), r.isComplete {
                        cont.resume(returning: acc.prefix(r.totalLength))
                        return
                    }
                    if err != nil || isDone || acc.count > (1 << 22) {
                        cont.resume(returning: acc.isEmpty ? nil : acc)
                        return
                    }
                    recv()
                }
            }
            recv()
        }
    }

    private func send(connection: NWConnection, status: String, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        let sema = DispatchSemaphore(value: 0)
        connection.send(content: out, completion: .contentProcessed { _ in sema.signal() })
        _ = sema.wait(timeout: .now() + 10)
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    let totalLength: Int
    var isComplete: Bool { true }

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = findHeaderEnd(data),
              let head = String(data: data.prefix(headerEnd), encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let clRaw = headers["content-length"] ?? "0"
        guard let contentLength = Int(clRaw), contentLength >= 0, contentLength <= HTTPPolicy.maxBody else {
            // reject before any range arithmetic; the handler answers 400
            return HTTPRequest(method: "BAD", path: "/", headers: headers, body: Data(), totalLength: headerEnd + 4)
        }
        let total = headerEnd + 4 + contentLength
        guard data.count >= total else { return nil }
        let body = data.subdata(in: (headerEnd + 4)..<(headerEnd + 4 + contentLength))
        let path = String(parts[1]).components(separatedBy: "?").first ?? "/"
        return HTTPRequest(method: String(parts[0]), path: path, headers: headers,
                           body: body, totalLength: total)
    }

    private static func findHeaderEnd(_ data: Data) -> Int? {
        let sep: [UInt8] = [13, 10, 13, 10]
        guard data.count >= 4 else { return nil }
        for i in 0...(data.count - 4) {
            if data[i] == sep[0], data[i+1] == sep[1], data[i+2] == sep[2], data[i+3] == sep[3] {
                return i
            }
        }
        return nil
    }
}


/// Policy for the exposed server. Public = arrived through the Cloudflare tunnel
/// (cloudflared adds cf-connecting-ip / cf-ray). The public surface is a showcase:
/// health, console, catalog and a read-only tool allowlist. Operational tools
/// (agents, journeys, voice, files, computer-use, writers) need the local endpoint.
public enum HTTPPolicy {
    public static let maxBody = 1 << 20
    public static let publicPrefixes = ["catalog_", "jev_", "agents_list", "agents_gate", "usage_status", "time_now", "meta_", "health"]
    public static func isPublic(headers: [String: String]) -> Bool { headers["cf-connecting-ip"] != nil || headers["cf-ray"] != nil }
    public static func publicTool(_ name: String) -> Bool { publicPrefixes.contains { name.hasPrefix($0) } }
    public static func originAllowed(_ origin: String, port: UInt16) -> Bool {
        let o = origin.lowercased().trimmingCharacters(in: .whitespaces)
        if o == "null" { return false }
        return o == "http://127.0.0.1:\(port)" || o == "http://localhost:\(port)" || o == "https://macrix.triqhub.tech" || o == "https://macrix.triqhub.cloud"
    }
}
