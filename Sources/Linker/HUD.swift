import AppKit
import SwiftUI

/// A small note next to the selection that fades out ("Linked → example.com/about ↗").
/// When it names a link, the link can be clicked to check it in the browser, and "Change" reopens the picker.
/// Hovering keeps it on screen.
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, symbol: String = "link", url: URL? = nil, near axRect: CGRect?,
                     change: (() -> Void)? = nil) {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let interactive = url != nil || change != nil
        let host = FirstMouseHostingView(rootView:
            HUDView(text: text, symbol: symbol, url: url,
                    open: { u in openLink(u) },
                    change: change.map { c in { dismiss(); c() } },
                    hover: { inside in inside ? hideWork?.cancel() : scheduleHide(after: 1.2) })
        )
        let size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.ignoresMouseEvents = !interactive
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.contentView = host

        var origin: NSPoint
        if let axRect {
            let sel = appKitRect(fromAX: axRect)
            origin = NSPoint(x: sel.minX, y: sel.minY - size.height - 6)
        } else {
            let mouse = NSEvent.mouseLocation
            origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 12)
        }
        p.setFrameOrigin(origin)

        p.alphaValue = reduceMotion ? 1 : 0
        p.orderFrontRegardless()
        if !reduceMotion { NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 } }
        panel = p
        // Long enough to read the target and click it.
        scheduleHide(after: interactive ? 4 : 1.6)
    }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        guard let p = panel else { return }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                if reduceMotion { p.orderOut(nil); return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 },
                                                     completionHandler: { p.orderOut(nil) })
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    static func dismiss() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct HUDView: View {
    let text: String
    let symbol: String
    let url: URL?
    let open: (URL) -> Void
    let change: (() -> Void)?
    let hover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text)
            if let url { LinkText(url: url, open: open) }
            if let change {
                Button("Change", action: change)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .help("Pick a different link")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .fixedSize()
        .onHover(perform: hover)
    }
}
