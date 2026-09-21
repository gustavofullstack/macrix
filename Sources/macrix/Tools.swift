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

func runProcess(_ path: String, _ args: [String], timeoutSeconds: Double = 30) -> (Int32, String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
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
        textContent("\(mcpServerName) \(mcpServerVersion): ok. tools: health, calendar_list_calendars, calendar_search_events, reminders_search, notes_search_notes, shortcuts_list, shortcuts_run, jev_rerank, mail_search, messages_search, contacts_search, screen_capture. no daily limits, concurrent clients allowed.")
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
}
