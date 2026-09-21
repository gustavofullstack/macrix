import Foundation
import EventKit
import Contacts

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

func runProcess(_ path: String, _ args: [String], timeoutSeconds: Double = 30, stdin: String? = nil) -> (Int32, String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    if let input = stdin {
        let inp = Pipe()
        inp.fileHandleForWriting.writeabilityHandler = { h in
            h.write(Data(input.utf8))
            try? h.close()
            inp.fileHandleForWriting.writeabilityHandler = nil
        }
        proc.standardInput = inp
    }
    // NOTE (fleet review): stderr goes to null, never an unread pipe —
    // a full pipe would deadlock the child until the deadline kill.
    proc.standardError = FileHandle.nullDevice
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


// MARK: - v0.2: Mail, Messages, Contacts, Screen

enum MailSearch {
    static func search(query: String, limit: Int) -> String {
        let q = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let n = max(1, min(limit, 20))
        let script = """
        tell application "Mail"
        set out to {}
        repeat with m in (messages of inbox whose subject contains "\(q)")
        set end of out to (subject of m) & " | " & (sender of m)
        if (count of out) >= \(n) then exit repeat
        end repeat
        return out
        end tell
        """
        let (code, text) = runProcess("/usr/bin/osascript", ["-e", script], timeoutSeconds: 60)
        if code != 0 {
            return "mail unavailable: is Mail.app installed and Automation allowed for this binary? (exit \(code))"
        }
        let lines = text.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return lines.isEmpty ? "no mail matches '\(query)'." : lines.joined(separator: "\n")
    }
}

enum MessagesDB {
    static var dbPath: String? {
        let p = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Messages/chat.db")
        return FileManager.default.isReadableFile(atPath: p) ? p : nil
    }

    static func search(query: String, limit: Int) -> String {
        guard let db = dbPath else {
            return "messages unavailable: chat.db not readable (grant Full Disk Access and retry)."
        }
        let ql = query.replacingOccurrences(of: "'", with: "''")
        let n = max(1, min(limit, 30))
        let sql = "SELECT COALESCE(h.id,'?'), substr(m.text,1,200) FROM message m " +
            "LEFT JOIN handle h ON m.handle_id=h.ROWID " +
            "WHERE m.text LIKE '%\(ql)%' ORDER BY m.date DESC LIMIT \(n);"
        let (code, out) = runProcess("/usr/bin/sqlite3", ["-readonly", "-separator", "\t", db, sql])
        guard code == 0 else { return "messages unavailable: search failed." }
        let lines = out.components(separatedBy: "\n").compactMap { line -> String? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            return "- [\(parts[0])] \(parts[1])"
        }
        return lines.isEmpty ? "no messages match '\(query)'." : lines.joined(separator: "\n")
    }
}

enum ContactsSearch {
    static func search(query: String, limit: Int) -> String {
        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        do {
            let found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)
            let lines = found.prefix(max(1, min(limit, 30))).map { c -> String in
                let phones = c.phoneNumbers.map { $0.value.stringValue }.joined(separator: ", ")
                let mails = c.emailAddresses.map { String($0.value) }.joined(separator: ", ")
                return "- \(c.givenName) \(c.familyName) | tel: \(phones) | mail: \(mails)"
            }
            return lines.isEmpty ? "no contacts match '\(query)'." : lines.joined(separator: "\n")
        } catch {
            return "contacts unavailable: grant Contacts access in System Settings > Privacy & Security, then retry."
        }
    }
}

// MARK: - Registration

public func registerAllTools(into registry: ToolRegistry) {
    registry.register(Tool(
        name: "health",
        description: "Server liveness, version, and capability summary.",
        inputSchema: objSchema([:])) { _ async in
        textContent("\(mcpServerName) \(mcpServerVersion): ok. 109 tools (see GET /catalog). free tier 1000 calls/day/key, paid tiers unlimited. concurrent clients allowed.")
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
        var stdin: String?
        if let input = args["input"]?.string { cmd += ["-i", "-"]; stdin = input }
        let (code, out) = runProcess("/usr/bin/shortcuts", cmd, timeoutSeconds: 120, stdin: stdin)
        if code != 0 { return textContent("shortcut failed (exit \(code)): \(out)", isError: true) }
        return textContent(out.trimmingCharacters(in: .whitespacesAndNewlines))
    })

    registry.register(Tool(
        name: "jev_rerank",
        description: "Rerank candidate passages with the local Jev/TypeSafe model. Enabled only with MACRIX_JEV=1.",
        inputSchema: objSchema(["query": "string", "candidates": "string"], required: ["query", "candidates"])) { args async in
        guard ProcessInfo.processInfo.environment["MACRIX_JEV"] == "1" else {
            return textContent("jev hook disabled: set MACRIX_JEV=1 to enable.", isError: true)
        }
        guard let q = args["query"]?.string, let cands = args["candidates"]?.string else {
            return textContent("missing query or candidates.", isError: true)
        }
        let items = cands.components(separatedBy: "\n---\n").filter { !$0.isEmpty }.prefix(10)
        var lines: [String] = []
        for item in items {
            let (code, out) = Jev.runShell(Jev.helper(), args: ["rerank", q, String(item.prefix(500))], timeoutSeconds: 60)
            lines.append(code == 0 ? out.trimmingCharacters(in: .whitespacesAndNewlines) : "rerank failed for candidate")
        }
        return textContent(lines.joined(separator: "\n"))
    })

    registry.register(Tool(
        name: "mail_search",
        description: "Search Mail.app inbox subjects (read-only).",
        inputSchema: objSchema(["query": "string", "limit": "number"], required: ["query"])) { args async in
        textContent(MailSearch.search(query: args["query"]?.string ?? "", limit: args["limit"]?.int ?? 20))
    })

    registry.register(Tool(
        name: "messages_search",
        description: "Search Messages.app texts by substring (read-only).",
        inputSchema: objSchema(["query": "string", "limit": "number"], required: ["query"])) { args async in
        textContent(MessagesDB.search(query: args["query"]?.string ?? "", limit: args["limit"]?.int ?? 30))
    })

    registry.register(Tool(
        name: "contacts_search",
        description: "Search Contacts by name (phones + emails).",
        inputSchema: objSchema(["query": "string", "limit": "number"], required: ["query"])) { args async in
        textContent(ContactsSearch.search(query: args["query"]?.string ?? "", limit: args["limit"]?.int ?? 20))
    })

    registry.register(Tool(
        name: "screen_capture",
        description: "Capture the main display to a PNG file (needs Screen Recording permission). Returns the file path.",
        inputSchema: objSchema([:])) { _ async in
        let path = "/tmp/mo_cap_\(Int(Date().timeIntervalSince1970)).png"
        let (code, _) = runProcess("/usr/sbin/screencapture", ["-x", "-t", "png", path], timeoutSeconds: 30)
        guard code == 0, FileManager.default.fileExists(atPath: path) else {
            return textContent("screen capture unavailable: grant Screen Recording in System Settings > Privacy & Security, then retry.", isError: true)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        return textContent("screenshot: \(path) (\(size) bytes)")
    })

    // MARK: - v0.3 computer-use + usage
    registry.register(Tool(
        name: "cu_click",
        description: "Click at screen coordinates (left or right). Needs Accessibility permission.",
        inputSchema: objSchema(["x": "number", "y": "number", "right": "number"], required: ["x", "y"])) { args async in
        guard let x = args["x"]?.double, let y = args["y"]?.double else {
            return textContent("missing x/y.", isError: true)
        }
        return CU.click(x: x, y: y, right: (args["right"]?.int ?? 0) == 1)
            ? textContent("clicked (\(Int(x)), \(Int(y)))")
            : textContent(CU.deniedText, isError: true)
    })
    registry.register(Tool(
        name: "cu_type",
        description: "Type text into the focused app. Needs Accessibility permission.",
        inputSchema: objSchema(["text": "string"], required: ["text"])) { args async in
        guard let t = args["text"]?.string, !t.isEmpty else {
            return textContent("missing text.", isError: true)
        }
        return CU.typeText(t) ? textContent("typed \(t.count) chars") : textContent(CU.deniedText, isError: true)
    })
    registry.register(Tool(
        name: "cu_key",
        description: "Press a key (return/tab/escape/space/delete/arrows) with optional modifiers cmd/ctrl/opt/shift.",
        inputSchema: objSchema(["key": "string", "modifiers": "string"], required: ["key"])) { args async in
        guard let k = args["key"]?.string else { return textContent("missing key.", isError: true) }
        let mods = (args["modifiers"]?.string ?? "").split(separator: ",").map { String($0) }
        guard CU.keycodes[k.lowercased()] != nil else {
            return textContent("unknown key '\(k)'.", isError: true)
        }
        return CU.key(k, modifiers: mods) ? textContent("pressed \(k)") : textContent(CU.deniedText, isError: true)
    })
    registry.register(Tool(
        name: "cu_scroll",
        description: "Scroll wheel at coordinates (dy positive = down).",
        inputSchema: objSchema(["x": "number", "y": "number", "dy": "number", "dx": "number"], required: ["x", "y", "dy"])) { args async in
        guard let x = args["x"]?.double, let y = args["y"]?.double, let dy = args["dy"]?.int else {
            return textContent("missing x/y/dy.", isError: true)
        }
        return CU.scroll(x: x, y: y, dy: Int32(dy), dx: Int32(args["dx"]?.int ?? 0))
            ? textContent("scrolled") : textContent(CU.deniedText, isError: true)
    })
    registry.register(Tool(
        name: "cu_windows",
        description: "List on-screen windows (owner, pid, title). No permission needed.",
        inputSchema: objSchema([:])) { _ async in textContent(CU.windows()) })
    registry.register(Tool(
        name: "cu_front_app",
        description: "Frontmost application (name, bundle, pid). No permission needed.",
        inputSchema: objSchema([:])) { _ async in textContent(CU.frontApp()) })
    registry.register(Tool(
        name: "cu_ax_query",
        description: "Bounded Accessibility tree of the focused app (role + title, depth<=3, 100 nodes).",
        inputSchema: objSchema([:])) { _ async in textContent(CU.axQuery()) })
    registry.register(Tool(
        name: "cu_shot",
        description: "Screenshot a screen region to PNG (x,y,w,h). Needs Screen Recording permission.",
        inputSchema: objSchema(["x": "number", "y": "number", "w": "number", "h": "number"],
                               required: ["x", "y", "w", "h"])) { args async in
        guard let x = args["x"]?.int, let y = args["y"]?.int,
              let w = args["w"]?.int, let h = args["h"]?.int else {
            return textContent("missing x/y/w/h.", isError: true)
        }
        let path = "/tmp/macrix_cap_\(Int(Date().timeIntervalSince1970)).png"
        let (code, _) = runProcess("/usr/sbin/screencapture", ["-x", "-t", "png", "-R", "\(x),\(y),\(w),\(h)", path], timeoutSeconds: 30)
        guard code == 0, FileManager.default.fileExists(atPath: path) else {
            return textContent("screen capture unavailable: grant Screen Recording in System Settings > Privacy & Security, then retry.", isError: true)
        }
        return textContent("screenshot: \(path)")
    })
    registry.register(Tool(
        name: "usage_status",
        description: "Today's metered usage for the calling key: tier, calls vs quota, top tools.",
        inputSchema: objSchema([:])) { _ async in
        // NOTE: key identity is not threaded into tool args in v0.3;
        // the server stamps usage per key, and this reports the global tier.
        // Per-key self-report lands in v0.4.
        textContent("tiers free(1k/d) starter$20(10k/d) growth$50(50k/d) scale$100(200k/d) max$200(unlimited) lifetime(unlimited) — now: \(License.current().tier.rawValue)")
    })

    registry.register(Tool(
        name: "providers_usage",
        description: "Per-provider local activity: sessions, events, bytes, recency (codex/claude/muse/cursor/antigravity/opencode/gemini). Counts only, no content.",
        inputSchema: objSchema([:])) { _ async in textContent(Providers.report()) })

    registry.register(Tool(
        name: "providers_spend",
        description: "Measured tokens per provider (muse) with n/a reasons elsewhere; USD only from ~/.config/macrix/rates.json.",
        inputSchema: objSchema([:])) { _ async in textContent(Spend.report()) })

    registry.register(Tool(
        name: "catalog_search",
        description: "Search the 1000-item capability catalog (skills/CLIs/MCPs/tools).",
        inputSchema: objSchema(["query": "string", "limit": "number"], required: ["query"])) { args async in
        textContent(Catalog.search(args["query"]?.string ?? "", limit: args["limit"]?.int ?? 20))
    })
    registry.register(Tool(
        name: "catalog_stats",
        description: "Catalog coverage: counts per kind vs the 1000 target.",
        inputSchema: objSchema([:])) { _ async in textContent(Catalog.stats()) })

    // MARK: - v0.8 system family (G1)
    for (n, d, needArgs) in [
        ("sys_info", "Hardware + OS summary.", false),
        ("sys_battery", "Battery status (pmset).", false),
        ("sys_volume", "Output volume level.", false),
        ("sys_wifi", "Current Wi-Fi network.", false),
        ("sys_clipboard", "Clipboard text (first 500 chars).", false),
        ("sys_procs", "Top CPU processes.", false),
        ("sys_disk", "Disk usage for /.", false),
    ] {
        let name = n, desc = d
        registry.register(Tool(name: name, description: desc, inputSchema: objSchema([:])) { _ async in
            switch name {
            case "sys_info": return textContent(Sys.info())
            case "sys_battery": return textContent(Sys.battery())
            case "sys_volume": return textContent(Sys.volume())
            case "sys_wifi": return textContent(Sys.wifi())
            case "sys_clipboard": return textContent(Sys.clipboard())
            case "sys_procs": return textContent(Sys.procs())
            default: return textContent(Sys.disk())
            }
        })
        _ = needArgs
    }
    registry.register(Tool(
        name: "sys_open",
        description: "Open an http(s) URL, absolute path, or .app by name. Only opens exactly what is named.",
        inputSchema: objSchema(["target": "string"], required: ["target"])) { args async in
        textContent(Sys.openTarget(args["target"]?.string ?? ""))
    })

    // MARK: - v0.9 writers (G1): calendar + reminders CRUD
    registry.register(Tool(
        name: "calendar_create_event",
        description: "Create a calendar event (title, ISO-8601 start/end, optional notes). Returns the event identifier.",
        inputSchema: objSchema(["title": "string", "start": "string", "end": "string", "notes": "string"],
                               required: ["title", "start", "end"])) { args async in
        guard let store = await EKAccess.eventStore() else { return textContent(permissionDeniedText, isError: true) }
        guard let title = args["title"]?.string, !title.isEmpty,
              let startS = args["start"]?.string, let endS = args["end"]?.string,
              let start = iso.date(from: startS), let end = iso.date(from: endS), end > start else {
            return textContent("invalid title/start/end (ISO-8601, end > start).", isError: true)
        }
        let ev = EKEvent(eventStore: store)
        ev.title = title; ev.startDate = start; ev.endDate = end
        ev.calendar = store.defaultCalendarForNewEvents
        if let n = args["notes"]?.string { ev.notes = n }
        do {
            try store.save(ev, span: .thisEvent)
            return textContent("created event \(ev.eventIdentifier ?? "?")")
        } catch {
            return textContent("create failed: \(error.localizedDescription)", isError: true)
        }
    })
    registry.register(Tool(
        name: "calendar_delete_event",
        description: "Delete a calendar event by identifier (from calendar_search_events or create).",
        inputSchema: objSchema(["id": "string"], required: ["id"])) { args async in
        guard let store = await EKAccess.eventStore() else { return textContent(permissionDeniedText, isError: true) }
        guard let ident = args["id"]?.string,
              let ev = store.event(withIdentifier: ident) else {
            return textContent("event not found.", isError: true)
        }
        do {
            try store.remove(ev, span: .thisEvent)
            return textContent("deleted \(ident)")
        } catch {
            return textContent("delete failed: \(error.localizedDescription)", isError: true)
        }
    })
    registry.register(Tool(
        name: "reminders_create",
        description: "Create a reminder (title, optional ISO-8601 due, optional list name). Returns the identifier.",
        inputSchema: objSchema(["title": "string", "due": "string", "list": "string"],
                               required: ["title"])) { args async in
        guard let store = await EKAccess.reminderStore() else { return textContent(permissionDeniedText, isError: true) }
        guard let title = args["title"]?.string, !title.isEmpty else {
            return textContent("missing title.", isError: true)
        }
        let rem = EKReminder(eventStore: store)
        rem.title = title
        rem.calendar = store.defaultCalendarForNewReminders()
        if let dueS = args["due"]?.string, let due = iso.date(from: dueS) {
            rem.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        }
        if let listName = args["list"]?.string,
           let cal = store.calendars(for: .reminder).first(where: { $0.title == listName }) {
            rem.calendar = cal
        }
        do {
            try store.save(rem, commit: true)
            return textContent("created reminder \(rem.calendarItemIdentifier)")
        } catch {
            return textContent("create failed: \(error.localizedDescription)", isError: true)
        }
    })
    registry.register(Tool(
        name: "reminders_complete",
        description: "Mark a reminder completed by identifier.",
        inputSchema: objSchema(["id": "string"], required: ["id"])) { args async in
        guard let store = await EKAccess.reminderStore() else { return textContent(permissionDeniedText, isError: true) }
        guard let ident = args["id"]?.string,
              let rem = store.calendarItem(withIdentifier: ident) as? EKReminder else {
            return textContent("reminder not found.", isError: true)
        }
        rem.isCompleted = true
        do {
            try store.save(rem, commit: true)
            return textContent("completed \(ident)")
        } catch {
            return textContent("complete failed: \(error.localizedDescription)", isError: true)
        }
    })

    // MARK: - v0.10 web family (G5): headless Chromium
    registry.register(Tool(
        name: "web_shot",
        description: "Screenshot an http(s) page with headless Chromium. Returns the PNG path.",
        inputSchema: objSchema(["url": "string"], required: ["url"])) { args async in
        textContent(Web.shot(url: args["url"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "web_text",
        description: "Rendered text of an http(s) page (JS executed, tags stripped, 4000 chars).",
        inputSchema: objSchema(["url": "string"], required: ["url"])) { args async in
        textContent(Web.text(url: args["url"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "web_pdf",
        description: "Print an http(s) page to PDF. Returns the file path.",
        inputSchema: objSchema(["url": "string"], required: ["url"])) { args async in
        textContent(Web.pdf(url: args["url"]?.string ?? ""))
    })

    // MARK: - v0.11 jev routing (Jev behind everything)
    registry.register(Tool(
        name: "jev_route",
        description: "Ask Jev which macrix tools fit a request; returns top-5 with noul scores. Needs MACRIX_JEV=1.",
        inputSchema: objSchema(["request": "string"], required: ["request"])) { args async in
        guard let req = args["request"]?.string, !req.isEmpty else {
            return textContent("missing request.", isError: true)
        }
        return textContent(Jev.route(req, tools: registry.list()))
    })
    registry.register(Tool(
        name: "jev_ping",
        description: "Check the local Jev/TypeSafe brain is reachable.",
        inputSchema: objSchema([:])) { _ async in textContent(Jev.ping()) })

    // MARK: - v0.12 files family (G1): scoped read/write/list
    registry.register(Tool(
        name: "file_read",
        description: "Read a UTF-8 text file (max 100KB). Secret-adjacent paths refused.",
        inputSchema: objSchema(["path": "string"], required: ["path"])) { args async in
        textContent(Files.read(args["path"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "file_write",
        description: "Write text to a bare filename inside /tmp only (max 100KB).",
        inputSchema: objSchema(["name": "string", "content": "string"], required: ["name", "content"])) { args async in
        textContent(Files.write(name: args["name"]?.string ?? "", content: args["content"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "file_list",
        description: "List /tmp or PROJETOS subtrees (max 50 entries).",
        inputSchema: objSchema(["dir": "string"], required: ["dir"])) { args async in
        textContent(Files.list(args["dir"]?.string ?? ""))
    })

    // MARK: - v0.13 net family (G1) + clipboard write
    registry.register(Tool(
        name: "net_dns",
        description: "Resolve a hostname to addresses (getaddrinfo).",
        inputSchema: objSchema(["host": "string"], required: ["host"])) { args async in
        textContent(Net.dns(args["host"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "net_ping",
        description: "2-packet ping summary (loss + round-trip).",
        inputSchema: objSchema(["host": "string"], required: ["host"])) { args async in
        textContent(Net.ping(args["host"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "net_ip",
        description: "Local IPv4 addresses per interface.",
        inputSchema: objSchema([:])) { _ async in textContent(Net.ips()) })
    registry.register(Tool(
        name: "clipboard_write",
        description: "Set clipboard text (max 100KB).",
        inputSchema: objSchema(["text": "string"], required: ["text"])) { args async in
        textContent(Net.clipWrite(args["text"]?.string ?? ""))
    })

    // MARK: - v0.14 spotlight + AX click-on-element (G1)
    registry.register(Tool(
        name: "meta_read",
        description: "File metadata via mdls (first 30 lines). Secret paths refused.",
        inputSchema: objSchema(["path": "string"], required: ["path"])) { args async in
        textContent(Meta.read(args["path"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "meta_search",
        description: "Spotlight filename/content search (max 20 hits).",
        inputSchema: objSchema(["query": "string"], required: ["query"])) { args async in
        textContent(Meta.search(args["query"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "cu_click_element",
        description: "Find a UI element by role+title substring in the focused app and click its center. Needs Accessibility.",
        inputSchema: objSchema(["role": "string", "title": "string"], required: ["role", "title"])) { args async in
        guard let role = args["role"]?.string, let title = args["title"]?.string else {
            return textContent("missing role/title.", isError: true)
        }
        guard let pt = CU.findElement(role: role, title: title) else {
            return textContent("element not found (or accessibility denied).", isError: true)
        }
        return CU.click(x: pt.x, y: pt.y) ? textContent("clicked element at (\(Int(pt.x)), \(Int(pt.y)))") : textContent(CU.deniedText, isError: true)
    })

    // MARK: - v0.15 notify/voice/app + jev_check (G1)
    registry.register(Tool(
        name: "notify_send",
        description: "macOS user notification (title + body).",
        inputSchema: objSchema(["title": "string", "body": "string"], required: ["title"])) { args async in
        textContent(Notify.send(title: args["title"]?.string ?? "", body: args["body"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "tts_render",
        description: "Render speech to an AIFF file (never plays audio — house voice-off rule). Returns the path.",
        inputSchema: objSchema(["text": "string", "voice": "string"], required: ["text"])) { args async in
        textContent(Notify.render(args["text"]?.string ?? "", voice: args["voice"]?.string))
    })
    registry.register(Tool(
        name: "app_quit",
        description: "Quit an app by exact name (no paths/bundles).",
        inputSchema: objSchema(["name": "string"], required: ["name"])) { args async in
        textContent(Notify.quitApp(args["name"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "jev_check",
        description: "Jev citation-check: does the evidence support the claim? Returns the score. Needs MACRIX_JEV=1.",
        inputSchema: objSchema(["claim": "string", "evidence": "string"], required: ["claim", "evidence"])) { args async in
        guard Jev.enabled() else { return textContent(Jev.disabled(), isError: true) }
        guard let c = args["claim"]?.string, let e = args["evidence"]?.string else {
            return textContent("missing claim/evidence.", isError: true)
        }
        let (code, out) = Jev.runShell(Jev.helper(), args: ["citation-check", c, e], timeoutSeconds: 60)
        return code == 0 ? textContent(out.trimmingCharacters(in: .whitespacesAndNewlines)) : textContent("citation-check failed.", isError: true)
    })

    // MARK: - v0.16 web fetch/download + clip read + open (G1)
    registry.register(Tool(
        name: "url_fetch",
        description: "GET an http(s) URL, returns body text (1MB cap).",
        inputSchema: objSchema(["url": "string"], required: ["url"])) { args async in
        textContent(WebClip.fetch(args["url"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "url_download",
        description: "Download an http(s) URL into ~/Downloads. Returns saved path.",
        inputSchema: objSchema(["url": "string", "name": "string"], required: ["url"])) { args async in
        textContent(WebClip.download(args["url"]?.string ?? "", name: args["name"]?.string))
    })
    registry.register(Tool(
        name: "clip_get",
        description: "Read the macOS pasteboard as text.",
        inputSchema: objSchema([:])) { _ async in textContent(WebClip.clipGet()) })
    registry.register(Tool(
        name: "open_url",
        description: "Open an http(s) URL in the default browser.",
        inputSchema: objSchema(["url": "string"], required: ["url"])) { args async in
        textContent(WebClip.open(args["url"]?.string ?? ""))
    })

    // MARK: - v0.17 git read-only + clock (G1)
    registry.register(Tool(
        name: "git_status",
        description: "Short git status of a local repo path. Read-only.",
        inputSchema: objSchema(["path": "string"], required: ["path"])) { args async in
        textContent(Git.status(args["path"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "git_log",
        description: "One-line git log of a local repo path (max 30). Read-only.",
        inputSchema: objSchema(["path": "string", "n": "string"], required: ["path"])) { args async in
        textContent(Git.log(args["path"]?.string ?? "", n: Int(args["n"]?.string ?? "10") ?? 10))
    })
    registry.register(Tool(
        name: "git_diffstat",
        description: "git diff --stat of a local repo path. Read-only.",
        inputSchema: objSchema(["path": "string"], required: ["path"])) { args async in
        textContent(Git.diffstat(args["path"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "time_now",
        description: "Current local time (ISO-8601 with zone).",
        inputSchema: objSchema([:])) { _ async in textContent(Clock.now()) })
    registry.register(Tool(
        name: "time_world",
        description: "Current time in 1-5 IANA zones (comma-separated).",
        inputSchema: objSchema(["zones": "string"], required: ["zones"])) { args async in
        let zs = (args["zones"]?.string ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return textContent(Clock.world(zs))
    })

    // MARK: - v0.18 codec family (G1)
    registry.register(Tool(
        name: "b64_encode",
        description: "Base64-encode text (100KB cap).",
        inputSchema: objSchema(["text": "string"], required: ["text"])) { args async in
        textContent(Codec.b64encode(args["text"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "b64_decode",
        description: "Base64-decode to text.",
        inputSchema: objSchema(["base64": "string"], required: ["base64"])) { args async in
        textContent(Codec.b64decode(args["base64"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "sha256",
        description: "SHA-256 hex of text.",
        inputSchema: objSchema(["text": "string"], required: ["text"])) { args async in
        textContent(Codec.sha256(args["text"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "uuid_gen",
        description: "Random lowercase UUID v4.",
        inputSchema: objSchema([:])) { _ async in textContent(Codec.uuid()) })
    registry.register(Tool(
        name: "json_pretty",
        description: "Pretty-print JSON (sorted keys).",
        inputSchema: objSchema(["json": "string"], required: ["json"])) { args async in
        textContent(Codec.jsonPretty(args["json"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "qr_png",
        description: "Render text/URL as QR PNG in /tmp. Returns the path.",
        inputSchema: objSchema(["text": "string"], required: ["text"])) { args async in
        textContent(Codec.qr(args["text"]?.string ?? ""))
    })

    // MARK: - v0.19 archive + text families (G1)
    registry.register(Tool(
        name: "zip_create",
        description: "Zip up to 20 files into /tmp/<name>.zip.",
        inputSchema: objSchema(["name": "string", "paths": "string"], required: ["name", "paths"])) { args async in
        let ps = (args["paths"]?.string ?? "").split(separator: "\n").map(String.init)
        return textContent(Archive.create(zipName: args["name"]?.string ?? "", paths: ps))
    })
    registry.register(Tool(
        name: "zip_list",
        description: "List entries of a .zip file.",
        inputSchema: objSchema(["path": "string"], required: ["path"])) { args async in
        textContent(Archive.list(args["path"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "zip_extract",
        description: "Extract a .zip flat into a fresh /tmp dir (zip-slip safe).",
        inputSchema: objSchema(["path": "string"], required: ["path"])) { args async in
        textContent(Archive.extract(args["path"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "text_stats",
        description: "Line/word/byte counts of a text file.",
        inputSchema: objSchema(["path": "string"], required: ["path"])) { args async in
        textContent(TextUtil.stats(args["path"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "csv_head",
        description: "First N rows of a CSV file (max 20).",
        inputSchema: objSchema(["path": "string", "n": "string"], required: ["path"])) { args async in
        textContent(TextUtil.csvHead(args["path"]?.string ?? "", n: Int(args["n"]?.string ?? "10") ?? 10))
    })
    registry.register(Tool(
        name: "grep_file",
        description: "Literal case-insensitive search in a text file (max 50 hits).",
        inputSchema: objSchema(["path": "string", "pattern": "string"], required: ["path", "pattern"])) { args async in
        textContent(TextUtil.grep(args["path"]?.string ?? "", pattern: args["pattern"]?.string ?? ""))
    })

    // MARK: - v0.20 media family (G1): sips + afinfo, /tmp outputs only
    registry.register(Tool(
        name: "img_info",
        description: "Image dimensions and format via sips.",
        inputSchema: objSchema(["path": "string"], required: ["path"])) { args async in
        textContent(Media.imgInfo(args["path"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "img_resize",
        description: "Resize image so the long side is <max> px (16-4096). PNG in /tmp.",
        inputSchema: objSchema(["path": "string", "max": "string"], required: ["path"])) { args async in
        textContent(Media.imgResize(args["path"]?.string ?? "", maxSide: Int(args["max"]?.string ?? "512") ?? 512))
    })
    registry.register(Tool(
        name: "img_convert",
        description: "Convert image to png/jpeg/tiff in /tmp.",
        inputSchema: objSchema(["path": "string", "format": "string"], required: ["path", "format"])) { args async in
        textContent(Media.imgConvert(args["path"]?.string ?? "", format: args["format"]?.string ?? "png"))
    })
    registry.register(Tool(
        name: "audio_info",
        description: "Audio file probe via afinfo (no playback).",
        inputSchema: objSchema(["path": "string"], required: ["path"])) { args async in
        textContent(Media.audioInfo(args["path"]?.string ?? ""))
    })

    // MARK: - v0.21 probe family (G1): uptime/mem/ports/md/plist/launchd
    registry.register(Tool(
        name: "sys_uptime",
        description: "Uptime and load averages.",
        inputSchema: objSchema([:])) { _ async in textContent(Probe.uptime()) })
    registry.register(Tool(
        name: "sys_mem",
        description: "macOS virtual-memory summary (vm_stat).",
        inputSchema: objSchema([:])) { _ async in textContent(Probe.mem()) })
    registry.register(Tool(
        name: "net_ports",
        description: "Listening TCP ports (lsof).",
        inputSchema: objSchema([:])) { _ async in textContent(Probe.ports()) })
    registry.register(Tool(
        name: "md_headings",
        description: "Extract # headings from a markdown file.",
        inputSchema: objSchema(["path": "string"], required: ["path"])) { args async in
        textContent(Probe.headings(args["path"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "plist_read",
        description: "Dump a plist file (plutil -p). Secret paths refused.",
        inputSchema: objSchema(["path": "string"], required: ["path"])) { args async in
        textContent(Probe.plist(args["path"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "launchd_list",
        description: "User launchd jobs (first 40 lines).",
        inputSchema: objSchema([:])) { _ async in textContent(Probe.launchd()) })

    // MARK: - v0.22 the 100: jev x3 + codec x4 + probe x5 + csv (G1, web_* since v0.10)
    registry.register(Tool(
        name: "jev_eval",
        description: "Jev typed judgment over a state + question. Returns the noul number. Needs MACRIX_JEV=1.",
        inputSchema: objSchema(["state": "string", "question": "string"], required: ["state", "question"])) { args async in
        guard Jev.enabled() else { return textContent(Jev.disabled(), isError: true) }
        return textContent(Jev.judge(state: args["state"]?.string ?? "", question: args["question"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "jev_skill",
        description: "Jev picks the right skill for a request. Needs MACRIX_JEV=1.",
        inputSchema: objSchema(["prompt": "string"], required: ["prompt"])) { args async in
        guard Jev.enabled() else { return textContent(Jev.disabled(), isError: true) }
        return textContent(Jev.skill(args["prompt"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "jev_models",
        description: "List Jev/TypeSafe models available locally. Needs MACRIX_JEV=1.",
        inputSchema: objSchema([:])) { _ async in
        guard Jev.enabled() else { return textContent(Jev.disabled(), isError: true) }
        return textContent(Jev.models())
    })
    registry.register(Tool(
        name: "file_b64",
        description: "Base64 of a file's bytes (10MB cap). Secret paths refused.",
        inputSchema: objSchema(["path": "string"], required: ["path"])) { args async in
        textContent(Codec.fileB64(args["path"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "random_hex",
        description: "Cryptographic random bytes as hex (1-64 bytes).",
        inputSchema: objSchema(["bytes": "string"], required: ["bytes"])) { args async in
        textContent(Codec.randomHex(Int(args["bytes"]?.string ?? "16") ?? 16))
    })
    registry.register(Tool(
        name: "plist_get",
        description: "Extract one key-path from a plist (dot-separated). Secret paths refused.",
        inputSchema: objSchema(["path": "string", "key": "string"], required: ["path", "key"])) { args async in
        textContent(Probe.plistGet(args["path"]?.string ?? "", key: args["key"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "url_encode",
        description: "Percent-encode text.",
        inputSchema: objSchema(["text": "string"], required: ["text"])) { args async in
        textContent(Codec.urlEncode(args["text"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "url_decode",
        description: "Decode percent-encoding.",
        inputSchema: objSchema(["text": "string"], required: ["text"])) { args async in
        textContent(Codec.urlDecode(args["text"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "file_hash",
        description: "SHA-256 hex of a file (100MB cap). Secret paths refused.",
        inputSchema: objSchema(["path": "string"], required: ["path"])) { args async in
        textContent(Probe.fileHash(args["path"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "dir_size",
        description: "Human du -sh of /tmp or PROJETOS subtrees.",
        inputSchema: objSchema(["dir": "string"], required: ["dir"])) { args async in
        textContent(Probe.dirSize(args["dir"]?.string ?? ""))
    })
    registry.register(Tool(
        name: "host_name",
        description: "This Mac's computer name.",
        inputSchema: objSchema([:])) { _ async in textContent(Probe.hostName()) })
    registry.register(Tool(
        name: "tailscale_status",
        description: "Tailscale mesh status (first 20 nodes).",
        inputSchema: objSchema([:])) { _ async in textContent(Probe.tailscale()) })
    registry.register(Tool(
        name: "csv_cols",
        description: "Numbered column names from a CSV header row.",
        inputSchema: objSchema(["path": "string"], required: ["path"])) { args async in
        textContent(TextUtil.csvCols(args["path"]?.string ?? ""))
    })

    // MARK: - v0.25 voice → Jev → action before the sentence ends (Andy Gao pattern)
    registry.register(Tool(
        name: "voice_decide",
        description: "Run one (partial) transcript through Jev: intent, target app, complete?, addressed?, destructive? — then gate. execute=true acts (open/quit app, open url, search). Streaming-safe: call it on every partial; repeats are deduped per utterance.",
        inputSchema: objSchema(["transcript": "string", "is_final": "string", "execute": "string"], required: ["transcript"])) { args async in
        guard let key = Voice.apiKey() else {
            return textContent("voice unavailable: TYPESAFE_API_KEY not in env nor in ~/.config/frota/credenciais.env.", isError: true)
        }
        let brain = VoiceBrain(client: TypeSafeHTTP(key: key), installed: Apps.installed())
        let isFinal = (args["is_final"]?.string ?? "false") == "true" || args["is_final"]?.bool == true
        let execute = (args["execute"]?.string ?? "false") == "true" || args["execute"]?.bool == true
        return textContent(VoiceActor.step(brain: brain, transcript: args["transcript"]?.string ?? "",
                                           isFinal: isFinal, utterance: VoiceShared.utterance, execute: execute))
    })
    registerHarnessTools(into: registry)
    registry.register(Tool(
        name: "voice_listen",
        description: "Listen on the Mac microphone for N seconds (max 300); every partial transcript goes to Jev and acts mid-sentence. Needs Speech Recognition + Microphone permission for the macrix process. locale default pt-BR; execute default true.",
        inputSchema: objSchema(["seconds": "string", "locale": "string", "execute": "string"])) { args async in
        #if canImport(Speech)
        let secs = Int(args["seconds"]?.string ?? "") ?? args["seconds"]?.int ?? 15
        let locale = args["locale"]?.string ?? "pt-BR"
        let execute = (args["execute"]?.string ?? "true") != "false"
        return textContent(VoiceLoop.run(seconds: secs, locale: locale, execute: execute) { _ in })
        #else
        return textContent("voice_listen unavailable: Speech framework missing.", isError: true)
        #endif
    })
}

/// Harness family (v0.26): the CLIs on this Mac as tools, Jev picks the lane.
func registerHarnessTools(into registry: ToolRegistry) {
    registry.register(Tool(
        name: "agents_list",
        description: "Coding-agent lanes on this Mac (claude_fable/opus/sonnet, codex, antigravity, opencode, muse, goose): binary path or ABSENT, and the tier each lane is for.",
        inputSchema: objSchema([:])) { _ async in textContent(Harness.listText()) })
    registry.register(Tool(
        name: "agent_run",
        description: "Run one headless prompt on a lane inside an allowed workspace (~/Projetos, ~/Documents, /tmp). args: agent, prompt, workspace, model?, yolo? (\"true\" adds the CLI's auto-approve flag), timeout? (s, max 900), op_id? (dedupe: same id never runs twice in 10 min). Max 2 runs in flight; a lane answering 429 is suspended 30 min; timeout kill = status unknown. Ledger: ~/.config/macrix/agent-ledger.jsonl.",
        inputSchema: objSchema(["agent": "string", "prompt": "string", "workspace": "string", "model": "string", "yolo": "string", "timeout": "string", "op_id": "string"],
                               required: ["agent", "prompt"])) { args async in
        guard let a = Harness.Agent(rawValue: args["agent"]?.string ?? "") else {
            return textContent("unknown agent; one of: " + Harness.Agent.allCases.map { $0.rawValue }.joined(separator: ", "), isError: true)
        }
        let opId = args["op_id"]?.string
        let r = Harness.execute(a, prompt: args["prompt"]?.string ?? "", workspace: args["workspace"]?.string ?? "",
                                model: args["model"]?.string, yolo: (args["yolo"]?.string ?? "false") == "true",
                                timeout: Double(args["timeout"]?.string ?? "") ?? 300, opId: opId)
        switch r {
        case .failure(let e): return textContent(e.message, isError: true)
        case .success(let (ok, status)):
            let shown = ok.argv.map { $0 == (args["prompt"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) ? "<prompt>" : $0 }.joined(separator: " ")
            return textContent("agent: \(ok.agent.rawValue)\nargv: \(shown)\nexit: \(ok.exit) · \(String(format: "%.1f", ok.seconds)) s · execution \(status) · cost \(status == "settled" ? "see ledger" : "unknown")\(ok.truncated ? " · output truncated" : "")\n---\n\(ok.output)", isError: ok.exit != 0)
        }
    })
    registry.register(Tool(
        name: "agent_route",
        description: "Ask Jev which lane a task deserves (hardest→claude_fable, medium→claude_opus, simple→claude_sonnet, bulk→muse) plus needs_review. args: task, available? (comma list), execute? (\"true\" runs it through the same gated executor as agent_run; needs_review ≥ 0.70 is never auto-executed), workspace?, yolo?, op_id?.",
        inputSchema: objSchema(["task": "string", "available": "string", "execute": "string", "workspace": "string", "yolo": "string", "op_id": "string"], required: ["task"])) { args async in
        guard let key = Voice.apiKey() else { return textContent("jev unavailable: TYPESAFE_API_KEY missing.", isError: true) }
        var avail = Harness.Agent.allCases.filter { Harness.resolve($0) != nil }
        if let list = args["available"]?.string, !list.isEmpty {
            let wanted = Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            avail = avail.filter { wanted.contains($0.rawValue) }
        }
        let task = args["task"]?.string ?? ""
        switch Harness.route(task: task, client: TypeSafeHTTP(key: key), available: avail) {
        case .failure(let e): return textContent(e.message, isError: true)
        case .success(let r):
            var text = Harness.routeText(r)
            if (args["execute"]?.string ?? "false") == "true" {
                if r.review >= 0.70 { text += "\nrun: needs_review \(String(format: "%.2f", r.review)) ≥ 0.70 → not executed; use journey_run for the approval path" }
                else {
                    switch Harness.execute(r.lane, prompt: task, workspace: args["workspace"]?.string ?? "", yolo: (args["yolo"]?.string ?? "false") == "true", opId: args["op_id"]?.string) {
                    case .failure(let e): text += "\nrun: \(e.message)"
                    case .success(let (ok, status)): text += "\nrun: exit \(ok.exit) · \(String(format: "%.1f", ok.seconds)) s · execution \(status)\n---\n\(ok.output)"
                    }
                }
            }
            return textContent(text)
        }
    })
    registry.register(Tool(
        name: "journey_run",
        description: "End-to-end with one id: Jev routes the task to a lane → needs_review ≥ 0.70 stops for a human → gate admits (dedupe by journey_id) → lane runs headless in the workspace → ledger records execution_status and cost_status=unknown. args: task, journey_id, workspace?, yolo?, timeout?.",
        inputSchema: objSchema(["task": "string", "journey_id": "string", "workspace": "string", "yolo": "string", "timeout": "string"], required: ["task", "journey_id"])) { args async in
        guard let key = Voice.apiKey() else { return textContent("jev unavailable: TYPESAFE_API_KEY missing.", isError: true) }
        let avail = Harness.Agent.allCases.filter { Harness.resolve($0) != nil }
        return textContent(Journey.run(task: args["task"]?.string ?? "", journeyId: args["journey_id"]?.string ?? "",
                                       workspace: args["workspace"]?.string ?? "", client: TypeSafeHTTP(key: key), gate: HarnessGate.shared,
                                       available: avail, yolo: (args["yolo"]?.string ?? "false") == "true",
                                       timeout: Double(args["timeout"]?.string ?? "") ?? 300))
    })
    registry.register(Tool(
        name: "journey_approve",
        description: "Execute a journey that stopped in needs_human_review: needs the journey_id, the single-use token that journey_run wrote to ~/.config/macrix/approvals/<id>.approval on this Mac (never returned over MCP), and the same task/workspace/yolo/timeout. Production markers stay blocked even with a token. args: journey_id, token, task, workspace?, yolo?, timeout?.",
        inputSchema: objSchema(["journey_id": "string", "token": "string", "task": "string", "workspace": "string", "yolo": "string", "timeout": "string"], required: ["journey_id", "token", "task"])) { args async in
        textContent(Journey.approve(journeyId: args["journey_id"]?.string ?? "", token: args["token"]?.string ?? "", task: args["task"]?.string ?? "",
                                    workspace: args["workspace"]?.string ?? "", gate: HarnessGate.shared, yolo: (args["yolo"]?.string ?? "false") == "true",
                                    timeout: Double(args["timeout"]?.string ?? "") ?? 300))
    })
    registry.register(Tool(
        name: "agents_gate",
        description: "Harness gate state: runs in flight, lanes suspended by quota, ledger path.",
        inputSchema: objSchema([:])) { _ async in textContent(HarnessGate.shared.status()) })
    registry.register(Tool(
        name: "env_inventory",
        description: "Read-only census of what agents can use on this Mac: MCP servers, skills, commands, plugins, hooks, opencode agents/providers, codex profiles, muse skills, installed lanes. Names only, no values.",
        inputSchema: objSchema([:])) { _ async in textContent(EnvInventory.report()) })
}

/// One utterance memory shared by voice_decide calls from the same client stream.
enum VoiceShared { static let utterance = VoiceActor.Utterance() }
