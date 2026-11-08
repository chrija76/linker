import AppKit
import ApplicationServices
import LinkerCore

/// The focused text field of the frontmost app, read through the Accessibility API.
struct TextCapture {
    let element: AXUIElement
    let app: NSRunningApplication
    var selectedText: String
    var range: CFRange
    var value: String?
    /// Selection rectangle in Accessibility coordinates (top-left origin of the primary screen).
    var bounds: CGRect?

    var hasSelection: Bool { !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The paragraph around the selection, for context.
    var paragraph: String? {
        guard let value else { return nil }
        let ns = value as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return nil }
        return ns.substring(with: ns.paragraphRange(for: NSRange(location: range.location, length: range.length)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func current() -> TextCapture? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = attr(axApp, kAXFocusedUIElementAttribute) else { return nil }
        let el = focused as! AXUIElement
        var range = CFRange(location: 0, length: 0)
        if let r = attr(el, kAXSelectedTextRangeAttribute) { AXValueGetValue(r as! AXValue, .cfRange, &range) }
        else { return nil }
        var cap = TextCapture(element: el, app: app,
                              selectedText: attr(el, kAXSelectedTextAttribute) as? String ?? "",
                              range: range, value: attr(el, kAXValueAttribute) as? String, bounds: nil)
        cap.bounds = cap.boundsFor(range)
        return cap
    }

    func boundsFor(_ range: CFRange) -> CGRect? {
        var r = range
        guard let v = AXValueCreate(.cfRange, &r), let b = param(element, kAXBoundsForRangeParameterizedAttribute, v) else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(b as! AXValue, .cgRect, &rect)
        return rect.width > 0 || rect.height > 0 ? rect : nil
    }

    /// Selects `r` (UTF-16 range in the field's text) in the app.
    @discardableResult
    func select(_ r: NSRange) -> Bool {
        var cf = CFRange(location: r.location, length: r.length)
        guard let v = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    /// Runs of linked text inside `range`, with absolute ranges and their URLs, read from the field's
    /// attributed text (WebKit editors, NSTextView). Empty when the app doesn't expose links.
    func links(in range: NSRange) -> [(range: NSRange, url: URL)] {
        var cf = CFRange(location: range.location, length: range.length)
        guard range.length > 0, let v = AXValueCreate(.cfRange, &cf),
              let raw = param(element, kAXAttributedStringForRangeParameterizedAttribute, v),
              let attributed = raw as? NSAttributedString else { return [] }
        var out: [(NSRange, URL)] = []
        let key = NSAttributedString.Key("AXLink")
        attributed.enumerateAttribute(key, in: NSRange(location: 0, length: attributed.length)) { value, r, _ in
            guard let value, let url = Self.url(fromLink: value as AnyObject) else { return }
            let abs = NSRange(location: range.location + r.location, length: r.length)
            // Adjacent runs of the same link (e.g. a bold word inside it) count as one.
            if let last = out.last, last.1 == url, NSMaxRange(last.0) == abs.location {
                out[out.count - 1].0 = NSUnionRange(last.0, abs)
            } else {
                out.append((abs, url))
            }
        }
        return out.map { (range: $0.0, url: $0.1) }
    }

    private static func url(fromLink value: AnyObject) -> URL? {
        if let u = value as? URL { return u }
        if let s = value as? String { return URL(string: s) }
        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            let el = value as! AXUIElement
            if let u = attr(el, kAXURLAttribute) as? URL { return u }
            if let s = attr(el, kAXURLAttribute) as? String { return URL(string: s) }
        }
        return nil
    }

    /// The link on the current selection, if the whole selection sits inside one link.
    var existingLink: URL? {
        let sel = NSRange(location: range.location, length: range.length)
        guard let first = links(in: sel).first, NSIntersectionRange(first.range, sel) == sel else { return nil }
        return first.url
    }

    /// With only a caret inside a link, selects the whole link text and returns the updated capture.
    func expandingToLinkAtCaret() -> TextCapture? {
        guard range.length == 0, let value else { return nil }
        let ns = value as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(range.location, ns.length), length: 0))
        guard let hit = links(in: para).first(where: { NSLocationInRange(range.location, $0.range) && range.location > $0.range.location }),
              select(hit.range), var updated = TextCapture.current(), updated.range.length == hit.range.length else { return nil }
        updated.bounds = updated.boundsFor(CFRange(location: hit.range.location, length: hit.range.length))
        return updated
    }

    /// Shrinks the selection to exclude leading/trailing whitespace, so a sloppy drag doesn't link the space.
    func trimmingWhitespace() -> TextCapture {
        let ws = CharacterSet.whitespacesAndNewlines
        let lead = selectedText.prefix { $0.unicodeScalars.allSatisfy(ws.contains) }.utf16.count
        let trail = String(selectedText.reversed().prefix { $0.unicodeScalars.allSatisfy(ws.contains) }).utf16.count
        let length = range.length - lead - trail
        guard lead + trail > 0, length > 0 else { return self }
        var cf = CFRange(location: range.location + lead, length: length)
        guard let v = AXValueCreate(.cfRange, &cf),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, v) == .success,
              var updated = TextCapture.current(),
              updated.selectedText == selectedText.trimmingCharacters(in: ws) else { return self }
        updated.bounds = updated.boundsFor(cf)
        return updated
    }

    /// With only a caret, finds the longest known name (up to 6 words) touching the caret, selects it and
    /// returns the updated capture. Nil when nothing known is there.
    func expandingAtCaret(_ isKnown: (String) -> Bool) -> TextCapture? {
        guard range.length == 0, let value else { return nil }
        let ns = value as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(range.location, ns.length), length: 0))
        var words: [NSRange] = []
        ns.enumerateSubstrings(in: para, options: .byWords) { _, r, _, _ in words.append(r) }
        guard let at = words.firstIndex(where: { range.location >= $0.location && range.location <= NSMaxRange($0) }) else { return nil }

        for length in stride(from: min(6, words.count), through: 1, by: -1) {
            for start in max(0, at - length + 1)...at where start + length <= words.count {
                let span = NSUnionRange(words[start], words[start + length - 1])
                let text = ns.substring(with: span)
                guard isKnown(Normalize.key(text)) else { continue }
                var cf = CFRange(location: span.location, length: span.length)
                guard let v = AXValueCreate(.cfRange, &cf),
                      AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, v) == .success,
                      var updated = TextCapture.current(), updated.selectedText == text else { return nil }
                updated.bounds = updated.boundsFor(cf)
                return updated
            }
        }
        return nil
    }
}

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func param(_ el: AXUIElement, _ name: String, _ p: AnyObject) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyParameterizedAttributeValue(el, name as CFString, p, &v) == .success ? v : nil
}

/// Converts an Accessibility rect (top-left origin) to AppKit screen coordinates (bottom-left origin).
func appKitRect(fromAX r: CGRect) -> NSRect {
    let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
    return NSRect(x: r.minX, y: primaryTop - r.maxY, width: r.width, height: r.height)
}
