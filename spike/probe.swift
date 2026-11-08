// Linker feasibility probe: AX read, selection bounds, rich-text paste into a target app.
import AppKit
import ApplicationServices

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func names(_ el: AXUIElement) -> [String] {
    var n: CFArray?
    AXUIElementCopyAttributeNames(el, &n)
    return (n as? [String]) ?? []
}
func paramNames(_ el: AXUIElement) -> [String] {
    var n: CFArray?
    AXUIElementCopyParameterizedAttributeNames(el, &n)
    return (n as? [String]) ?? []
}
func param(_ el: AXUIElement, _ name: String, _ p: AnyObject) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyParameterizedAttributeValue(el, name as CFString, p, &v) == .success ? v : nil
}

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "read"
print("trusted:", AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary))

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mimestream.Mimestream").first else {
    print("Mimestream not running"); exit(1)
}
app.activate()
usleep(400_000)
let axApp = AXUIElementCreateApplication(app.processIdentifier)
guard let focused = attr(axApp, kAXFocusedUIElementAttribute) else { print("no focused element"); exit(2) }
let el = focused as! AXUIElement

switch cmd {
case "read":
    print("role:", attr(el, kAXRoleAttribute) ?? "-", "subrole:", attr(el, kAXSubroleAttribute) ?? "-")
    print("attrs:", names(el).joined(separator: ", "))
    print("param attrs:", paramNames(el).joined(separator: ", "))
    print("selectedText:", (attr(el, kAXSelectedTextAttribute) as? String).map { "\"\($0)\"" } ?? "nil")
    if let r = attr(el, kAXSelectedTextRangeAttribute) {
        var range = CFRange()
        AXValueGetValue(r as! AXValue, .cfRange, &range)
        print("selectedRange:", range.location, range.length)
        if let b = param(el, kAXBoundsForRangeParameterizedAttribute, r) {
            var rect = CGRect.zero
            AXValueGetValue(b as! AXValue, .cgRect, &rect)
            print("selectionBounds:", rect)
        } else { print("selectionBounds: nil") }
        if let value = attr(el, kAXValueAttribute) as? String {
            let ns = value as NSString
            let para = ns.paragraphRange(for: NSRange(location: range.location, length: range.length))
            print("valueLength:", ns.length)
            print("paragraph:", "\"\(ns.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines))\"")
        } else { print("value: nil") }
    } else { print("selectedRange: nil") }
    // WebKit text markers, if the editor is a web view
    if let m = attr(el, "AXSelectedTextMarkerRange") {
        print("textMarkerRange: present")
        if let s = param(el, "AXStringForTextMarkerRange", m) as? String { print("markerString:", "\"\(s)\"") }
        if let b = param(el, "AXBoundsForTextMarkerRange", m) {
            var rect = CGRect.zero
            AXValueGetValue(b as! AXValue, .cgRect, &rect)
            print("markerBounds:", rect)
        }
    }
case "paste":
    let url = args.count > 2 ? args[2] : "https://example.com"
    let text = args.count > 3 ? args[3] : ((attr(el, kAXSelectedTextAttribute) as? String) ?? "link")
    let pb = NSPasteboard.general
    // Save every item and type on the clipboard
    let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
        Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
    }
    let esc = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    let html = "<a href=\"\(url)\">\(esc)</a>"
    let attributed = NSAttributedString(string: text, attributes: [.link: URL(string: url)!])
    let rtf = try! attributed.data(from: NSRange(location: 0, length: attributed.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    pb.clearContents()
    let item = NSPasteboardItem()
    item.setString(html, forType: .html)
    item.setData(rtf, forType: .rtf)
    item.setString(text, forType: .string)
    item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    pb.writeObjects([item])
    let src = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)! // 'v'
        e.flags = .maskCommand
        e.post(tap: .cghidEventTap)
    }
    usleep(300_000)
    pb.clearContents()
    let restored = saved.map { types -> NSPasteboardItem in
        let i = NSPasteboardItem()
        for (t, d) in types { i.setData(d, forType: t) }
        return i
    }
    if !restored.isEmpty { pb.writeObjects(restored) }
    print("pasted link", url, "over", "\"\(text)\"", "; restored", saved.count, "clipboard item(s)")
default:
    print("usage: probe read | paste <url> [text]")
}
