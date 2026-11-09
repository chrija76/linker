import AppKit
import SwiftUI
import Combine
import LinkerCore

/// A floating panel that takes keyboard input without activating Linker, so the email keeps its selection.
final class FloatingPanel: NSPanel {
    var onCancel: () -> Void = {}
    /// Set while a link opens in the browser: the panel loses focus but should stay up so the user can come back and pick.
    var keepOnResign = false

    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                   backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel() }
    override func resignKey() {
        super.resignKey()
        if keepOnResign { keepOnResign = false; return }
        onCancel()
    }
}

/// Lets SwiftUI content take the first click in a panel that isn't key yet (after the user looked at a link).
/// It also drops the safe-area inset that the panel's hidden title bar would add, which left an empty strip above the content.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PickerModel: ObservableObject {
    @Published var query: String
    @Published var items: [Candidate]
    @Published var selection = 0
    @Published var searchingRemote = false
    /// The link already on the selected text, when there is one.
    let existing: URL?
    let remoteLabel: String
    let search: (String) -> [Candidate]
    let remote: ((String) async -> [Candidate])?
    let choose: (Candidate) -> Void
    let remove: (() -> Void)?
    let cancel: () -> Void
    let open: (URL) -> Void
    private var remoteTask: Task<Void, Never>?

    init(query: String, items: [Candidate], existing: URL?, remoteLabel: String, search: @escaping (String) -> [Candidate],
         remote: ((String) async -> [Candidate])?, choose: @escaping (Candidate) -> Void, remove: (() -> Void)?,
         cancel: @escaping () -> Void, open: @escaping (URL) -> Void) {
        self.query = query
        self.items = items
        self.existing = existing
        self.remoteLabel = remoteLabel
        self.search = search
        self.remote = remote
        self.choose = choose
        self.remove = remove
        self.cancel = cancel
        self.open = open
        fetchRemote(debounce: false)
    }

    func refresh() {
        items = search(query)
        selection = 0
        fetchRemote(debounce: true)
    }

    /// Local results show at once; live search results are appended when they arrive.
    private func fetchRemote(debounce: Bool) {
        remoteTask?.cancel()
        guard let remote else { return }
        let q = query
        remoteTask = Task { @MainActor in
            if debounce { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled else { return }
            searchingRemote = true
            let found = await remote(q)
            guard !Task.isCancelled, q == query else { return }
            searchingRemote = false
            var seen = Set(items.map { Resolver.urlKey($0.url) })
            items += found.filter { seen.insert(Resolver.urlKey($0.url)).inserted }
        }
    }

    func stop() {
        remoteTask?.cancel()
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + delta + items.count) % items.count
    }

    var selected: Candidate? { items.indices.contains(selection) ? items[selection] : nil }

    func chooseSelected() {
        if let selected { choose(selected) }
    }

    func copySelected() {
        guard let selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected.url.absoluteString, forType: .string)
        HUD.show("Copied \(selected.displayURL)", symbol: "doc.on.doc", near: nil)
    }
}

enum PickerMetrics {
    static let width: CGFloat = 440
    static let rowHeight: CGFloat = 46
    static let maxRows = 6
    static let existingHeight: CGFloat = 38
    static let chrome: CGFloat = 44 + 1 + 8 + 1 + 26 // search bar, dividers, list padding, footer

    static func height(rows: Int, existing: Bool) -> CGFloat {
        chrome + (existing ? existingHeight + 1 : 0) + (rows == 0 ? rowHeight : CGFloat(min(rows, maxRows)) * rowHeight)
    }
}

struct PickerView: View {
    @ObservedObject var model: PickerModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("Search links or paste a URL", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .onSubmit { model.chooseSelected() }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onKeyPress(.escape) { model.cancel(); return .handled }
                    .onKeyPress(phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        switch press.characters {
                        case "o":
                            if let c = model.selected { model.open(c.url) }
                            return .handled
                        case "c" where !model.items.isEmpty:
                            model.copySelected()
                            return .handled
                        default:
                            if let n = Int(press.characters), n >= 1, model.items.indices.contains(n - 1) {
                                model.choose(model.items[n - 1])
                                return .handled
                            }
                            if press.key == .delete, let remove = model.remove { remove(); return .handled }
                            return .ignored
                        }
                    }
                Button { model.cancel() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .help("Cancel (Esc)")
            }
            .padding(.horizontal, 12)
            .frame(height: 44)

            Divider()

            if let existing = model.existing {
                HStack(spacing: 6) {
                    Text("Linked to").foregroundStyle(.secondary)
                    LinkText(url: existing, open: model.open)
                    Spacer(minLength: 8)
                    if let remove = model.remove {
                        Button("Remove Link", action: remove).controlSize(.small).help("Remove the link (⌘⌫)")
                    }
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .frame(height: PickerMetrics.existingHeight)
                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if model.items.isEmpty {
                            Text(model.searchingRemote ? "Searching…" : "No matching links")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: PickerMetrics.rowHeight)
                        }
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { i, c in
                            PickerRow(candidate: c, index: i, selected: i == model.selection, open: model.open)
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture { model.choose(c) }
                                .onHover { if $0 { model.selection = i } }
                        }
                    }
                    .padding(4)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selection) { _, s in proxy.scrollTo(s) }
            }

            Divider()

            HStack(spacing: 12) {
                Text("↩ Link")
                Text("⌘O Open")
                Text("⌘C Copy")
                Text("⌘1–6 Pick")
                Spacer()
                if model.searchingRemote {
                    ProgressView().controlSize(.mini)
                    Text(model.remoteLabel).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 26)
        }
        .frame(width: PickerMetrics.width)
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
        .onChange(of: model.query) { model.refresh() }
    }
}

/// A URL shown as a link: click opens it in the browser so it can be checked before it goes in.
struct LinkText: View {
    let url: URL
    var full = true
    var light = false
    let open: (URL) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Text(Self.shorten(full ? url.displayString : url.displayHost)).lineLimit(1).truncationMode(.middle)
            Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
        }
        .underline(hovering)
        .foregroundStyle(light ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture { open(url) }
        .help("Open \(url.absoluteString)")
        .accessibilityAddTraits(.isLink)
        .accessibilityAction { open(url) }
    }

    /// Long URLs keep their start and end: "example.com/blog/2024/…/the-post-title".
    static func shorten(_ s: String, max: Int = 64) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max * 2 / 3)) + "…" + String(s.suffix(max / 3))
    }
}

struct PickerRow: View {
    let candidate: Candidate
    let index: Int
    let selected: Bool
    let open: (URL) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Favicon(url: candidate.url, kind: candidate.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title).lineLimit(1)
                HStack(spacing: 4) {
                    if let meta { Text(meta).lineLimit(1).layoutPriority(-1) }
                    LinkText(url: candidate.url, light: selected, open: open)
                }
                .font(.caption)
                .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 6)
            Text(candidate.badgeText)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(selected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15)))
            if index < 6 {
                Text("⌘\(index + 1)").font(.caption).monospacedDigit()
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            }
        }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .frame(height: PickerMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Date for posts, headline for people; the URL itself is shown as a link next to it.
    private var meta: String? {
        var parts: [String] = []
        if let d = candidate.date { parts.append(d.formatted(date: .abbreviated, time: .omitted)) }
        if candidate.kind == .person, let s = candidate.subtitle, !s.isEmpty { parts.append(s) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ") + " ·"
    }
}

struct Favicon: View {
    let url: URL
    let kind: EntityKind

    var body: some View {
        AsyncImage(url: URL(string: "https://\(url.host ?? "")/favicon.ico")) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high)
            } else {
                Image(systemName: kind.symbol).foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// Owns the panel's lifetime and placement next to the selection.
@MainActor
final class PickerController {
    private var panel: FloatingPanel?
    private var model: PickerModel?
    private var modelObserver: Any?

    var isOpen: Bool { panel?.isVisible == true }

    func show(query: String, items: [Candidate], existing: URL? = nil, near axRect: CGRect?, remoteLabel: String,
              search: @escaping (String) -> [Candidate], remote: ((String) async -> [Candidate])?,
              remove: (() -> Void)? = nil, choose: @escaping (Candidate) -> Void) {
        close()
        let panel = FloatingPanel()
        let model = PickerModel(query: query, items: items, existing: existing, remoteLabel: remoteLabel, search: search,
                                remote: remote,
                                choose: { [weak self] c in self?.close(); choose(c) },
                                remove: remove.map { r in { [weak self] in self?.close(); r() } },
                                cancel: { [weak self] in self?.close() },
                                open: { [weak panel] url in
                                    // Keep the picker up while the page loads in the browser.
                                    panel?.keepOnResign = true
                                    openLink(url)
                                })
        panel.onCancel = { [weak self] in self?.close() }
        panel.contentView = FirstMouseHostingView(rootView: PickerView(model: model))
        self.panel = panel
        self.model = model

        let height = PickerMetrics.height(rows: items.count, existing: existing != nil)
        panel.setFrame(frame(height: height, near: axRect), display: false)
        panel.makeKeyAndOrderFront(nil)

        // Keep the panel's top edge fixed as results change.
        modelObserver = model.$items.dropFirst().sink { [weak panel] items in
            guard let panel else { return }
            var f = panel.frame
            let h = PickerMetrics.height(rows: items.count, existing: existing != nil)
            f.origin.y += f.height - h
            f.size.height = h
            panel.setFrame(f, display: true, animate: false)
        }
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        model?.stop()
        model = nil
        modelObserver = nil
        p.onCancel = {}
        p.orderOut(nil)
    }

    /// Just below the selection; above it if there's no room; centered on the screen without a selection rect.
    private func frame(height: CGFloat, near axRect: CGRect?) -> NSRect {
        let size = NSSize(width: PickerMetrics.width, height: height)
        guard let axRect else {
            let s = NSScreen.main?.visibleFrame ?? .zero
            return NSRect(x: s.midX - size.width / 2, y: s.midY, width: size.width, height: size.height)
        }
        let sel = appKitRect(fromAX: axRect)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: sel.midX, y: sel.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: sel.minX - 12, y: sel.minY - 6 - size.height)
        if origin.y < visible.minY { origin.y = sel.maxY + 6 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        return NSRect(origin: origin, size: size)
    }
}
