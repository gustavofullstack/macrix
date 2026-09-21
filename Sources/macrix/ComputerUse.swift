import Foundation
import ApplicationServices
import AppKit

/// Computer-use primitives via CGEvent + Accessibility API.
/// Every action first checks AXIsProcessTrusted(); without the grant the
/// tool returns an actionable error instead of failing silently.
enum CU {
    static func trusted() -> Bool { AXIsProcessTrusted() }

    static let deniedText = "accessibility denied: add this binary in System Settings > Privacy & Security > Accessibility, then retry."

    static func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }

    static func click(x: Double, y: Double, right: Bool = false) -> Bool {
        guard trusted() else { return false }
        let pt = CGPoint(x: x, y: y)
        let downT: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let upT: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let btn: CGMouseButton = right ? .right : .left
        post(CGEvent(mouseEventSource: nil, mouseType: downT, mouseCursorPosition: pt, mouseButton: btn))
        Thread.sleep(forTimeInterval: 0.05)
        post(CGEvent(mouseEventSource: nil, mouseType: upT, mouseCursorPosition: pt, mouseButton: btn))
        return true
    }

    static func typeText(_ text: String) -> Bool {
        guard trusted() else { return false }
        for ch in text.unicodeScalars {
            var code = ch.value
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            withUnsafePointer(to: &code) { ptr in
                ptr.withMemoryRebound(to: UniChar.self, capacity: 1) { u in
                    down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: u)
                    up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: u)
                }
            }
            post(down); post(up)
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }

    static let keycodes: [String: CGKeyCode] = [
        "return": 36, "tab": 48, "space": 49, "escape": 53,
        "delete": 51, "forwarddelete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    static func key(_ name: String, modifiers: [String]) -> Bool {
        guard trusted(), let code = keycodes[name.lowercased()] else { return false }
        var flags = CGEventFlags(rawValue: 0)
        for m in modifiers {
            switch m.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: break
            }
        }
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = flags; up?.flags = flags
        post(down); post(up)
        return true
    }

    static func scroll(x: Double, y: Double, dy: Int32, dx: Int32 = 0) -> Bool {
        guard trusted() else { return false }
        post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                     wheelCount: dx == 0 ? 1 : 2, wheel1: dy, wheel2: dx, wheel3: 0))
        return true
    }

    static func windows() -> String {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return "window list unavailable."
        }
        let lines = list.prefix(30).compactMap { w -> String? in
            guard let owner = w[kCGWindowOwnerName as String] as? String else { return nil }
            let name = (w[kCGWindowName as String] as? String) ?? "(no title)"
            let pid = (w[kCGWindowOwnerPID as String] as? Int) ?? 0
            return "- \(owner) [\(pid)]: \(name)"
        }
        return lines.isEmpty ? "no windows." : lines.joined(separator: "\n")
    }

    static func frontApp() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "unknown front app." }
        return "\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"), pid \(app.processIdentifier))"
    }

    /// Bounded AX tree dump: role + title + position, depth<=3, max 100 nodes.
    static func axQuery() -> String {
        guard trusted() else { return deniedText }
        let system = AXUIElementCreateSystemWide()
        var out: [String] = []
        func dump(_ el: AXUIElement, depth: Int) {
            guard out.count < 100, depth <= 3 else { return }
            var role: CFTypeRef?
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &title)
            let r = (role as? String) ?? "?"
            let t = (title as? String) ?? ""
            out.append(String(repeating: "  ", count: depth) + "- \(r) \(t)".trimmingCharacters(in: .whitespaces))
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
               let arr = kids as? [AXUIElement] {
                for k in arr.prefix(20) { dump(k, depth: depth + 1) }
            }
        }
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focused) == .success,
           let app = focused as! AXUIElement? {
            dump(app, depth: 0)
        }
        return out.isEmpty ? "ax tree unavailable." : out.joined(separator: "\n")
    }
}
