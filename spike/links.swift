import AppKit
func attr(_ el: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success ? v : nil }
func walk(_ el: AXUIElement, _ depth: Int) {
    if depth > 40 { return }
    if (attr(el, kAXRoleAttribute) as? String) == "AXLink" {
        let url = attr(el, kAXURLAttribute).map { "\($0)" } ?? "nil"
        print("link:", attr(el, kAXTitleAttribute) ?? "", "->", url)
    }
    for c in (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth + 1) }
}
let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mimestream.Mimestream").first!
let ax = AXUIElementCreateApplication(app.processIdentifier)
let f = attr(ax, kAXFocusedUIElementAttribute) as! AXUIElement
walk(f, 0)
