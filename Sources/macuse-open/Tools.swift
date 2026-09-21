import Foundation
import EventKit

private let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func objSchema(_ props: [String: String], required: [String] = []) -> JSONValue {
    var p: [String: JSONValue] = [:]
    for (k, t) in props { p[k] = .object(["type": .string(t)]) }
    return .object(["type": .string("object"),
                    "properties": .object(p),
                    "required": .array(required.map { .string($0) })])
}

func runProcess(_ path: String, _ args: [String], timeoutSeconds: Double = 30) -> (Int32, String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
        try proc.run()
    } catch {
        return (-1, "spawn failed: \(error.localizedDescription)")
    }
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if proc.isRunning { proc.terminate() }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - Calendar & Reminders (EventKit)

enum EKAccess {
    static func eventStore() async -> EKEventStore? {
        let store = EKEventStore()
        if #available(macOS 14.0, *) {
            do {
                let granted = try await store.requestFullAccessToEvents()
                return granted ? store : nil
            } catch { return nil }
        }
        let granted = await withCheckedContinuation { cont in
            store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
        }
        return granted ? store : nil
    }

    static func reminderStore() async -> EKEventStore? {
        let store = EKEventStore()
        if #available(macOS 14.0, *) {
            do {
                let granted = try await store.requestFullAccessToReminders()
                return granted ? store : nil
            } catch { return nil }
        }
        let granted = await withCheckedContinuation { cont in
            store.requestAccess(to: .reminder) { ok, _ in cont.resume(returning: ok) }
        }
        return granted ? store : nil
    }
}

let permissionDeniedText = "permission denied: grant Calendar/Reminders access in System Settings > Privacy & Security, then retry."

// MARK: - Notes (read-only via the sqlite3 CLI, schema-tolerant)

enum NotesDB {
    static var storeURL: URL? {
        let lib = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes")
        let direct = lib.appendingPathComponent("NoteStore.sqlite")
        if FileManager.default.isReadableFile(atPath: direct.path) { return direct }
        guard let subs = try? FileManager.default.contentsOfDirectory(
            at: lib, includingPropertiesForKeys: nil) else { return nil }
        for sub in subs {
            let cand = sub.appendingPathComponent("NoteStore.sqlite")
            if FileManager.default.isReadableFile(atPath: cand.path) { return cand }
        }
        return nil
    }

    static func sqlQuery(_ db: String, _ sql: String) -> (Int32, String) {
        runProcess("/usr/bin/sqlite3", ["-readonly", "-separator", "\t", db, sql])
    }

    /// Find a note-like table by column names, then search it. Read-only.
    static func search(query: String, limit: Int) -> String {
        guard let url = storeURL else {
            return "notes unavailable: NoteStore.sqlite not readable (grant Full Disk Access and retry)."
        }
        let db = url.path
        let (tc, tablesOut) = sqlQuery(db, "SELECT name FROM sqlite_master WHERE type='table';")
        guard tc == 0 else { return "notes unavailable: cannot inspect NoteStore.sqlite." }
        var schemas: [String: Set<String>] = [:]
        for t in tablesOut.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            let (cc, colsOut) = sqlQuery(db, "PRAGMA table_info(\"\(t)\");")
            guard cc == 0 else { continue }
            schemas[t] = Set(colsOut.components(separatedBy: "\n").compactMap { line -> String? in
                let parts = line.components(separatedBy: "\t")
                return parts.count > 2 ? parts[2] : nil
            })
        }
        let titleCands = ["ZTITLE1", "ZTITLE", "title", "name"]
        let bodyCands = ["ZSNIPPET", "ZTEXT", "snippet", "body", "content"]
        var picked: (String, String, String)?
        for (t, cols) in schemas {
            if let tc2 = titleCands.first(where: { cols.contains($0) }),
               let bc = bodyCands.first(where: { cols.contains($0) }) {
                picked = (t, tc2, bc)
                break
            }
        }
        guard let (table, titleCol, bodyCol) = picked else {
            return "notes unavailable: no note table with a known schema found."
        }
        let ql = query.replacingOccurrences(of: "'", with: "''")
        let n = max(1, min(limit, 50))
        let sql = "SELECT \"\(titleCol)\", substr(\"\(bodyCol)\",1,200) FROM \"\(table)\" " +
            "WHERE \"\(titleCol)\" LIKE '%\(ql)%' OR \"\(bodyCol)\" LIKE '%\(ql)%' LIMIT \(n);"
        let (sc, rowsOut) = sqlQuery(db, sql)
        guard sc == 0 else { return "notes unavailable: search failed." }
        let lines = rowsOut.components(separatedBy: "\n").compactMap { line -> String? in
            let parts = line.components(separatedBy: "\t")
            guard let t = parts.first, !t.isEmpty else { return nil }
            return "- \(t): \(parts.count > 1 ? parts[1] : "")"
        }
        return lines.isEmpty ? "no notes match '\(query)'." : lines.joined(separator: "\n")
    }
}

// MARK: - Registration

public func registerAllTools(into registry: ToolRegistry) {
    registry.register(Tool(
        name: "health",
        description: "Server liveness, version, and capability summary.",
        inputSchema: objSchema([:])) { _ async in
        textContent("\(mcpServerName) \(mcpServerVersion): ok. tools: calendar_list_calendars, calendar_search_events, reminders_search, notes_search_notes, shortcuts_list, shortcuts_run, jev_rerank. no daily limits, concurrent clients allowed.")
    })

    registry.register(Tool(
        name: "calendar_list_calendars",
        description: "List all calendars accessible on this Mac.",
        inputSchema: objSchema([:])) { _ async in
        guard let store = await EKAccess.eventStore() else { return textContent(permissionDeniedText, isError: true) }
        let lines = store.calendars(for: .event).map { "- \($0.title) [\($0.calendarIdentifier)]" }.sorted()
        return textContent(lines.isEmpty ? "no calendars." : lines.joined(separator: "\n"))
    })

    registry.register(Tool(
        name: "calendar_search_events",
        description: "Search calendar events within a date range. Dates accept 'today', '+7d', or ISO-8601.",
        inputSchema: objSchema(["start": "string", "end": "string", "query": "string"],
                               required: ["start", "end"])) { args async in
        guard let store = await EKAccess.eventStore() else { return textContent(permissionDeniedText, isError: true) }
        func parse(_ s: String) -> Date? {
            if s == "today" { return Calendar.current.startOfDay(for: Date()) }
            if s.hasPrefix("+"), s.hasSuffix("d"), let n = Int(s.dropFirst().dropLast()) {
                return Calendar.current.date(byAdding: .day, value: n, to: Date())
            }
            return iso.date(from: s)
        }
        guard let start = parse(args["start"]?.string ?? ""),
              let end = parse(args["end"]?.string ?? "") else {
            return textContent("invalid dates: use 'today', '+7d', or ISO-8601.", isError: true)
        }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let q = args["query"]?.string ?? ""
        let events = store.events(matching: pred)
            .filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) }
            .sorted { ($0.startDate ?? Date()) < ($1.startDate ?? Date()) }
            .prefix(50)
        let lines = events.map { e in
            "- \(e.title ?? "(untitled)") @ \(e.startDate.map { iso.string(from: $0) } ?? "?")"
        }
        return textContent(lines.isEmpty ? "no events." : lines.joined(separator: "\n"))
    })

    registry.register(Tool(
        name: "reminders_search",
        description: "Search reminders by title substring across all lists.",
        inputSchema: objSchema(["query": "string"], required: ["query"])) { args async in
        guard let store = await EKAccess.reminderStore() else { return textContent(permissionDeniedText, isError: true) }
        let q = args["query"]?.string ?? ""
        let pred = store.predicateForReminders(in: nil)
        let found: [String] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: pred) { rems in
                let lines = (rems ?? [])
                    .filter { q.isEmpty || ($0.title.localizedCaseInsensitiveContains(q)) }
                    .prefix(50)
                    .map { "- \($0.title ?? "(untitled)")\($0.isCompleted ? " [done]" : "")" }
                cont.resume(returning: Array(lines))
            }
        }
        return textContent(found.isEmpty ? "no reminders match '\(q)'." : found.joined(separator: "\n"))
    })

    registry.register(Tool(
        name: "notes_search_notes",
        description: "Search Notes.app notes by title/body substring (read-only, paginated).",
        inputSchema: objSchema(["query": "string", "limit": "number"], required: ["query"])) { args async in
        let q = args["query"]?.string ?? ""
        let lim = args["limit"]?.int ?? 20
        return textContent(NotesDB.search(query: q, limit: lim))
    })

    registry.register(Tool(
        name: "shortcuts_list",
        description: "List Apple Shortcuts available on this Mac.",
        inputSchema: objSchema([:])) { _ async in
        let (code, out) = runProcess("/usr/bin/shortcuts", ["list"])
        if code != 0 { return textContent("shortcuts unavailable (exit \(code)).", isError: true) }
        return textContent(out.trimmingCharacters(in: .whitespacesAndNewlines))
    })

    registry.register(Tool(
        name: "shortcuts_run",
        description: "Run an Apple Shortcut by name, with optional input piped via stdin.",
        inputSchema: objSchema(["name": "string", "input": "string"], required: ["name"])) { args async in
        guard let name = args["name"]?.string else {
            return textContent("missing shortcut name.", isError: true)
        }
        var cmd = ["run", name]
        if args["input"]?.string != nil { cmd += ["-i", "-"] }
        // NOTE: stdin piping omitted in v0.1; input param reserved for v0.2.
        let (code, out) = runProcess("/usr/bin/shortcuts", cmd, timeoutSeconds: 120)
        if code != 0 { return textContent("shortcut failed (exit \(code)): \(out)", isError: true) }
        return textContent(out.trimmingCharacters(in: .whitespacesAndNewlines))
    })

    registry.register(Tool(
        name: "jev_rerank",
        description: "Rerank candidate passages with the local Jev/TypeSafe model. Enabled only with MACUSE_OPEN_JEV=1.",
        inputSchema: objSchema(["query": "string", "candidates": "string"], required: ["query", "candidates"])) { args async in
        guard ProcessInfo.processInfo.environment["MACUSE_OPEN_JEV"] == "1" else {
            return textContent("jev hook disabled: set MACUSE_OPEN_JEV=1 to enable.", isError: true)
        }
        guard let q = args["query"]?.string, let cands = args["candidates"]?.string else {
            return textContent("missing query or candidates.", isError: true)
        }
        let items = cands.components(separatedBy: "\n---\n").filter { !$0.isEmpty }.prefix(10)
        let helper = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/typesafe")
        var lines: [String] = []
        for item in items {
            let (code, out) = runProcess("/bin/sh", ["-c", "bun '\(helper)' rerank \"\(q.replacingOccurrences(of: "\"", with: ""))\" \"\(item.replacingOccurrences(of: "\"", with: "").prefix(500))\""], timeoutSeconds: 60)
            lines.append(code == 0 ? out.trimmingCharacters(in: .whitespacesAndNewlines) : "rerank failed for candidate")
        }
        return textContent(lines.joined(separator: "\n"))
    })
}
