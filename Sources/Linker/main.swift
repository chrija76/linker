import AppKit
import Carbon
import SwiftUI
import LinkerCore

let triggerNotification = Notification.Name((Bundle.main.bundleIdentifier ?? "Linker") + ".trigger")

// `Linker --trigger` asks the running app to add a link (for Shortcuts, scripts and testing), then exits.
if CommandLine.arguments.contains("--trigger") {
    DistributedNotificationCenter.default().postNotificationName(triggerNotification, object: nil, userInfo: nil,
                                                                 deliverImmediately: true)
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private let picker = PickerController()
    private let linkAll = LinkAllController()
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var chooseHotKey: HotKey?
    private var settingsWindow: NSWindow?
    private var syncTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        // New status items land at the far left of the extras, which on notched Macs with a full menu bar is
        // behind the notch. Start Linker near the right instead (users can still ⌘-drag it anywhere afterwards).
        let positionKey = "NSStatusItem Preferred Position Linker"
        if UserDefaults.standard.object(forKey: positionKey) == nil { UserDefaults.standard.set(220, forKey: positionKey) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "Linker"
        statusItem.button?.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Linker")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        hotKey = HotKey(id: 1, keyCode: kVK_ANSI_K, modifiers: controlKey | optionKey) { [weak self] in self?.addLink() }
        chooseHotKey = HotKey(id: 2, keyCode: kVK_ANSI_K, modifiers: controlKey | optionKey | shiftKey) { [weak self] in
            self?.addLink(alwaysAsk: true)
        }
        DistributedNotificationCenter.default().addObserver(forName: triggerNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.addLink() }
        }

        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        model.syncIfStale()
        if !UserDefaults.standard.bool(forKey: "shownSettings") {
            UserDefaults.standard.set(true, forKey: "shownSettings")
            openSettings()
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.syncIfStale() }
        }
    }

    /// Opening Linker again (Finder, Spotlight, Dock) shows Settings, so they're reachable even if the icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let add = NSMenuItem(title: "Add Link", action: #selector(addLinkFromMenu), keyEquivalent: "k")
        add.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(add)
        let choose = NSMenuItem(title: "Choose Link / Link All…", action: #selector(chooseLinkFromMenu), keyEquivalent: "K")
        choose.keyEquivalentModifierMask = [.control, .option, .shift]
        menu.addItem(choose)
        menu.addItem(.separator())
        let status = model.syncing ? "Syncing…"
            : model.lastSync.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet"
        let info = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(NSMenuItem(title: "Sync Now", action: #selector(syncNow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit Linker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    @objc private func addLinkFromMenu() {
        // Let the menu close and focus settle back on the text field first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.addLink() }
    }

    @objc private func chooseLinkFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.addLink(alwaysAsk: true) }
    }

    @objc private func syncNow() { model.sync() }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "Linker Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        // A menu-bar app has no main menu, and without an Edit menu ⌘V, ⌘C and ⌘A don't reach text fields. Give
        // Settings one while it's open; the picker keeps its own ⌘C (copy the link) because the menu is gone then.
        NSApp.mainMenu = Self.editMenuBar()
        if let w = settingsWindow, settingsCloseObserver == nil {
            settingsCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w,
                                                                           queue: .main) { _ in
                MainActor.assumeIsolated { NSApp.mainMenu = nil }
            }
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private var settingsCloseObserver: Any?

    private static func editMenuBar() -> NSMenu {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Linker")
        appItem.submenu?.addItem(withTitle: "Close Settings", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        bar.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        bar.addItem(editItem)
        return bar
    }

    // MARK: Add link

    /// ⌃⌥K links the selection (asking only when unsure). `alwaysAsk` (⌃⌥⇧K) opens the picker even when a link is
    /// certain; with nothing selected it offers to link every known name in the text instead.
    private func addLink(alwaysAsk: Bool = false) {
        guard !picker.isOpen, !linkAll.isOpen else { return }
        guard AXIsProcessTrusted() else {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            return
        }
        guard var cap = TextCapture.current() else {
            HUD.show("Click into a text field first", symbol: "character.cursor.ibeam", near: nil)
            return
        }
        if !cap.hasSelection {
            if let onLink = cap.expandingToLinkAtCaret() {
                cap = onLink
            } else if alwaysAsk {
                linkEverything(in: cap)
                return
            } else {
                let resolver = model.resolver
                guard let expanded = cap.expandingAtCaret({ resolver.certain(key: $0) != nil || resolver.store.hasExact(key: $0) }) else {
                    HUD.show("Select the text to link, or press ⌃⌥⇧K to link every known name", symbol: "character.cursor.ibeam",
                             near: cap.bounds)
                    return
                }
                cap = expanded
            }
        }
        cap = cap.trimmingWhitespace()

        let text = cap.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = cap.existingLink {
            showPicker(for: cap, query: text, items: model.resolver.candidates(for: text), existing: existing)
            return
        }
        if alwaysAsk {
            showPicker(for: cap, query: text, items: model.resolver.candidates(for: text))
            return
        }
        switch model.resolver.resolve(text) {
        case .certain(let c) where c.source == .remembered:
            insert(c, over: cap)
        case .certain(let c):
            // A curated link still has to answer before it goes in unasked.
            Task {
                if await LinkCheck.isAlive(c.url) {
                    insert(c, over: cap)
                } else {
                    showPicker(for: cap, query: text, items: model.resolver.candidates(for: text))
                }
            }
        case .choose(let items):
            showPicker(for: cap, query: text, items: items)
        }
    }

    private func showPicker(for cap: TextCapture, query: String, items: [Candidate], existing: URL? = nil) {
        let resolver = model.resolver
        let store = model.store
        let key = Normalize.key(cap.selectedText)
        let searches = model.liveSearches
        let context = cap.paragraph
        let remote: ((String) async -> [Candidate])? = searches.isEmpty ? nil : { q in
            // All live searches at once; results keep the order of `searches` (your own search before the web).
            await withTaskGroup(of: (Int, [Candidate]).self) { group in
                for (i, s) in searches.enumerated() {
                    group.addTask { (i, (try? await s.search(q, context: context)) ?? []) }
                }
                var parts: [(Int, [Candidate])] = []
                for await p in group { parts.append(p) }
                return parts.sorted { $0.0 < $1.0 }.flatMap(\.1)
            }
        }
        // A URL typed or pasted into the search field is offered as a link of its own.
        let search: (String) -> [Candidate] = { q in
            let typed = q.contains(".") ? URL.lenient(q).map {
                Candidate(title: $0.displayString, url: $0, subtitle: nil, kind: .link, source: .list, badge: "Typed")
            } : nil
            return (typed.map { [$0] } ?? []) + resolver.candidates(for: q)
        }
        picker.show(query: query, items: items, existing: existing, near: cap.bounds, remoteLabel: model.liveSearchLabel,
                    search: search, remote: remote,
                    remove: existing == nil ? nil : { [weak self] in
                        store.forgetChoice(key: key)
                        self?.model.refreshCounts()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self?.insert(nil, over: cap) }
                    }) { [weak self] c in
            store.remember(key: key, c)
            self?.model.refreshCounts()
            // The panel has just closed; give the email window its keyboard focus back before pasting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self?.insert(c, over: cap) }
        }
    }

    /// Pastes the link (or, with nil, the bare text) over the captured selection, bringing its app back to the
    /// front first if the user went to the browser to check a link.
    private func insert(_ c: Candidate?, over cap: TextCapture) {
        let range = NSRange(location: cap.range.location, length: cap.range.length)
        bringBack(cap) {
            // Keep the user's exact selected text (spacing, case) and only change the link.
            Inserter.pasteLink(text: cap.selectedText, url: c?.url) { [weak self] in
                guard let c else {
                    HUD.show("Link removed", symbol: "link.badge.plus", near: cap.bounds)
                    return
                }
                HUD.show("Linked →", url: c.url, near: cap.bounds) {
                    self?.bringBack(cap) {
                        cap.select(range)
                        self?.addLink(alwaysAsk: true)
                    }
                }
            }
        }
    }

    private func bringBack(_ cap: TextCapture, then: @escaping () -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == cap.app.processIdentifier {
            then()
            return
        }
        cap.app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            cap.select(NSRange(location: cap.range.location, length: cap.range.length))
            then()
        }
    }

    // MARK: Link all

    private func linkEverything(in cap: TextCapture) {
        guard let value = cap.value, !value.isEmpty else {
            HUD.show("Select the text to link", symbol: "character.cursor.ibeam", near: cap.bounds)
            return
        }
        let ns = value as NSString
        let linked = cap.links(in: NSRange(location: 0, length: ns.length)).map(\.range)
        let matches = LinkScanner(resolver: model.resolver).scan(value, excluding: linked)
        guard !matches.isEmpty else {
            HUD.show("No known names to link in this text", symbol: "text.magnifyingglass", near: cap.bounds)
            return
        }
        let caret = NSRange(location: cap.range.location, length: cap.range.length)
        linkAll.show(matches, near: cap.bounds) { [weak self] picked in
            guard !picked.isEmpty else { return }
            // Back to front, so earlier positions stay valid whatever the editor does to spacing.
            let ordered = picked.sorted { $0.range.location > $1.range.location }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self?.bringBack(cap) {
                    Task { @MainActor in
                        await Inserter.paste(ordered.map { Inserter.Piece(text: $0.text, url: $0.candidate.url) }) { i in
                            cap.select(ordered[i].range)
                        }
                        cap.select(caret)
                        HUD.show("Linked \(ordered.count) \(ordered.count == 1 ? "name" : "names")", near: cap.bounds)
                    }
                }
            }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
