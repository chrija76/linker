import AppKit
import SwiftUI
import LinkerCore

/// "Link all": one review sheet listing every known name found in the draft, ticked; Return links the ticked ones.
@MainActor
final class LinkAllModel: ObservableObject {
    @Published var rows: [LinkScanner.Match]
    @Published var ticked: Set<Int>
    let confirm: ([LinkScanner.Match]) -> Void
    let cancel: () -> Void
    let open: (URL) -> Void

    init(rows: [LinkScanner.Match], confirm: @escaping ([LinkScanner.Match]) -> Void, cancel: @escaping () -> Void,
         open: @escaping (URL) -> Void) {
        self.rows = rows
        self.ticked = Set(rows.map(\.id))
        self.confirm = confirm
        self.cancel = cancel
        self.open = open
    }

    func toggle(_ id: Int) {
        if ticked.contains(id) { ticked.remove(id) } else { ticked.insert(id) }
    }

    func confirmTicked() {
        confirm(rows.filter { ticked.contains($0.id) })
    }
}

struct LinkAllView: View {
    @ObservedObject var model: LinkAllModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Link \(model.rows.count) \(model.rows.count == 1 ? "name" : "names") in this text?")
                .font(.headline)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.rows) { m in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(get: { model.ticked.contains(m.id) }, set: { _ in model.toggle(m.id) }))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                            Favicon(url: m.candidate.url, kind: m.candidate.kind)
                            Text(m.text).lineLimit(1).layoutPriority(1)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                            LinkText(url: m.candidate.url, open: model.open).font(.callout)
                            Spacer(minLength: 6)
                            Text(m.candidate.badgeText)
                                .font(.caption2.weight(.medium)).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                        .onTapGesture { model.toggle(m.id) }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 34 * 8 + 8)
            Divider()
            HStack {
                Text("Click a link to check it first.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction)
                Button("Link \(model.ticked.count)", action: model.confirmTicked)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.ticked.isEmpty)
            }
            .padding(10)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
    }
}

@MainActor
final class LinkAllController {
    private var panel: FloatingPanel?

    var isOpen: Bool { panel?.isVisible == true }

    func show(_ matches: [LinkScanner.Match], near axRect: CGRect?, confirm: @escaping ([LinkScanner.Match]) -> Void) {
        close()
        let panel = FloatingPanel()
        let model = LinkAllModel(rows: matches,
                                 confirm: { [weak self] picked in self?.close(); confirm(picked) },
                                 cancel: { [weak self] in self?.close() },
                                 open: { [weak panel] url in panel?.keepOnResign = true; openLink(url) })
        panel.onCancel = { [weak self] in self?.close() }
        let host = FirstMouseHostingView(rootView: LinkAllView(model: model))
        panel.contentView = host
        self.panel = panel
        let size = host.fittingSize
        var origin: NSPoint
        if let axRect {
            let sel = appKitRect(fromAX: axRect)
            origin = NSPoint(x: sel.minX - 12, y: sel.minY - 8 - size.height)
        } else {
            let s = NSScreen.main?.visibleFrame ?? .zero
            origin = NSPoint(x: s.midX - size.width / 2, y: s.midY)
        }
        let visible = (NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main)?.visibleFrame ?? .zero
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = max(origin.y, visible.minY + 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        p.onCancel = {}
        p.orderOut(nil)
    }
}
