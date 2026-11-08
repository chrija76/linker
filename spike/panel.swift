// Show a non-activating panel under the Mimestream selection, send it keystrokes, check Mimestream keeps focus and selection.
import AppKit
func attr(_ el: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success ? v : nil }
func param(_ el: AXUIElement, _ n: String, _ p: AnyObject) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyParameterizedAttributeValue(el, n as CFString, p, &v) == .success ? v : nil }

final class KeyPanel: NSPanel {
    var keys: [String] = []
    override var canBecomeKey: Bool { true }
    override func keyDown(with e: NSEvent) { keys.append(e.charactersIgnoringModifiers ?? "?") }
}

let ms = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mimestream.Mimestream").first!
ms.activate(); usleep(400_000)
let ax = AXUIElementCreateApplication(ms.processIdentifier)
let el = attr(ax, kAXFocusedUIElementAttribute) as! AXUIElement
let range = attr(el, kAXSelectedTextRangeAttribute)!
var r = CGRect.zero
AXValueGetValue(param(el, kAXBoundsForRangeParameterizedAttribute, range) as! AXValue, .cgRect, &r)
let selBefore = attr(el, kAXSelectedTextAttribute) as? String ?? "nil"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// AX rects are top-left origin; AppKit is bottom-left of the primary screen
let primaryH = NSScreen.screens[0].frame.height
let size = NSSize(width: 360, height: 180)
let origin = NSPoint(x: r.minX, y: primaryH - r.maxY - 6 - size.height)
let panel = KeyPanel(contentRect: NSRect(origin: origin, size: size),
                     styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
panel.level = .popUpMenu; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
let fx = NSVisualEffectView(); fx.material = .popover; fx.state = .active
panel.contentView = fx
panel.makeKeyAndOrderFront(nil)

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    let src = CGEventSource(stateID: .combinedSessionState)
    for code: CGKeyCode in [125, 125, 126] { // down, down, up
        for d in [true, false] { CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: d)!.post(tap: .cghidEventTap) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        let selAfter = attr(el, kAXSelectedTextAttribute) as? String ?? "nil"
        print("selection bounds (AX):", r, "-> panel frame:", panel.frame)
        print("panel is key:", panel.isKeyWindow, "| keys received by panel:", panel.keys.count)
        print("frontmost app while panel open:", front)
        print("selection before/after:", "\"\(selBefore)\"", "/", "\"\(selAfter)\"")
        panel.orderOut(nil)
        exit(0)
    }
}
app.run()
