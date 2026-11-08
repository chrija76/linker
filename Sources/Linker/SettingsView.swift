import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import LinkerCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
            ContextTab(model: model).tabItem { Label("Context", systemImage: "books.vertical") }
            SearchTab(model: model).tabItem { Label("Search & Keys", systemImage: "magnifyingglass") }
        }
        .frame(width: 600, height: 660)
    }
}

// MARK: General

private struct GeneralTab: View {
    @ObservedObject var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var trusted = AXIsProcessTrusted()
    @State private var showingRemembered = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Add link", value: "⌃⌥K")
                LabeledContent("Choose link · Link all", value: "⌃⌥⇧K")
                LabeledContent("Accessibility") {
                    if trusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open Privacy Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            } footer: {
                Text("Select a name in any app and press ⌃⌥K. A sure match is linked at once; otherwise you pick from a list. With nothing selected, ⌃⌥⇧K finds every known name in the text.")
            }

            Section("Sync") {
                LabeledContent {
                    Button("Sync Now") { model.sync() }.disabled(model.syncing)
                } label: {
                    if model.syncing {
                        HStack { ProgressView().controlSize(.small); Text("Syncing…") }
                    } else if let last = model.lastSync {
                        Text("Last synced \(last.formatted(.relative(presentation: .named)))")
                    } else {
                        Text("Not synced yet")
                    }
                }
                LabeledContent("Remembered links") {
                    HStack {
                        Text("\(model.rememberedCount)").monospacedDigit().foregroundStyle(.secondary)
                        Button("Show…") { showingRemembered = true }.disabled(model.rememberedCount == 0)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in trusted = AXIsProcessTrusted() }
        .sheet(isPresented: $showingRemembered) { RememberedLinksView(model: model) }
    }
}

// MARK: Context

private struct ContextTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Text("Linker only knows what you give it. Use any mix of these:")
                VStack(alignment: .leading, spacing: 4) {
                    Text("**MCP server**: your company's knowledge base, CRM or wiki")
                    Text("**Link list**: a CSV or JSON of names and links, from a file or a URL")
                    Text("**Blogs and newsletters**: post titles link to the post")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                HStack {
                    Button("Add MCP Server") { model.mcpServers.append(MCPServerConfig(name: "", url: "")) }
                    Button("New List") { newList() }
                    Button("Add List File…") { addFile() }
                    Button("Add List URL") { model.lists.append(LinkList(name: "", location: "")) }
                }
            }

            ForEach($model.mcpServers) { $server in
                MCPServerSection(server: $server, model: model) { model.mcpServers.removeAll { $0.id == server.id } }
            }

            ForEach($model.lists) { $list in
                ListSection(list: $list, model: model) { model.lists.removeAll { $0.id == list.id } }
            }

            Section {
                TextEditor(text: $model.feeds)
                    .font(.body.monospaced())
                    .frame(height: 56)
                    .scrollContentBackground(.hidden)
                ForEach(model.feeds.split(whereSeparator: \.isNewline).compactMap { FeedSource(String($0)) }, id: \.feed) { f in
                    if let e = model.error(for: f.feed) {
                        ErrorLabel("\(f.address.displayString): \(e)")
                    }
                }
            } header: {
                SectionHeader(icon: "newspaper", title: "Blogs and newsletters", detail: "\(model.postCount) posts")
            } footer: {
                Text("One per line, e.g. yourname.substack.com or a blog's address. Substack's full archive is indexed; other blogs through their RSS or Atom feed.")
            }
        }
        .formStyle(.grouped)
    }

    private func newList() {
        var n = 1
        var file = model.supportDir.appendingPathComponent("links.csv")
        while FileManager.default.fileExists(atPath: file.path) {
            n += 1
            file = model.supportDir.appendingPathComponent("links-\(n).csv")
        }
        try? Data("name,url,aliases,subtitle,kind\n".utf8).write(to: file)
        model.lists.append(LinkList(name: n == 1 ? "My links" : "List \(n)", location: file.path))
        NSWorkspace.shared.open(file)
    }

    private func addFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .json, .plainText, .tabSeparatedText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            model.lists.append(LinkList(name: url.deletingPathExtension().lastPathComponent, location: url.path))
        }
        model.sync()
    }
}

private struct MCPServerSection: View {
    @Binding var server: MCPServerConfig
    @ObservedObject var model: AppModel
    let remove: () -> Void

    var body: some View {
        let _ = model.keysVersion
        Section {
            TextField("Name", text: $server.name, prompt: Text("Shown on its results"))
            TextField("Server URL", text: $server.url, prompt: Text("https://example.com/mcp"))
            Picker("Access", selection: $server.auth) {
                Text("Sign in with browser").tag(MCPServerConfig.Auth.signIn)
                Text("Token").tag(MCPServerConfig.Auth.token)
                Text("Open (no sign-in)").tag(MCPServerConfig.Auth.none)
            }
            switch server.auth {
            case .signIn:
                LabeledContent("Account") { account }
            case .token:
                SecureField("Token", text: Binding(get: { model.secret(server.credentialAccount) },
                                                   set: { model.setToken(server, $0) }), prompt: Text("Bearer token"))
            case .none:
                EmptyView()
            }
            TextField("Search tools", text: $server.searchTools, prompt: Text("e.g. search, find_person"))
            TextField("Sync tool", text: $server.syncTool, prompt: Text("Optional, e.g. list_customers"))
            if let e = model.signInError[server.id] ?? server.syncFeed.flatMap({ model.error(for: $0) }) {
                ErrorLabel(e)
            }
        } header: {
            SectionHeader(icon: "server.rack", title: server.name.isEmpty ? "MCP server" : server.name,
                          detail: server.syncFeed.map { "\(model.count(feed: $0)) links synced" }, remove: remove)
        } footer: {
            Text("Search tools are asked live from the picker and never insert unasked. The sync tool runs daily; its results are linked like a list. Any result with a name and a URL works.")
        }
    }

    @ViewBuilder private var account: some View {
        if model.signingIn == server.id {
            HStack {
                ProgressView().controlSize(.small)
                Text("Finish in your browser").foregroundStyle(.secondary)
                Button("Cancel") { model.cancelSignIn() }
            }
            .fixedSize()
        } else if model.isConnected(server) {
            HStack {
                Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Sign Out") { model.signOut(server) }
            }
            .fixedSize()
        } else {
            Button("Sign In…") { model.signIn(server) }.disabled(server.endpoint == nil)
        }
    }
}

private struct ListSection: View {
    @Binding var list: LinkList
    @ObservedObject var model: AppModel
    let remove: () -> Void

    var body: some View {
        let _ = model.keysVersion
        let file = LinkListSource(id: list.id, name: list.name, location: list.location).fileURL
        Section {
            TextField("Name", text: $list.name, prompt: Text("Shown on its links, e.g. Clients"))
            LabeledContent("Location") {
                HStack {
                    TextField("Location", text: $list.location, prompt: Text("File path or https:// URL")).labelsHidden()
                    if let file {
                        Button("Edit") { NSWorkspace.shared.open(file) }
                        Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Image(systemName: "folder") }
                            .help("Show in Finder")
                    } else if let url = URL.lenient(list.location) {
                        LinkText(url: url, full: false) { openLink($0) }.fixedSize()
                    }
                }
            }
            Picker("Default kind", selection: $list.kind) {
                ForEach(EntityKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            if file == nil {
                SecureField("Token", text: Binding(get: { model.secret(list.tokenAccount) }, set: { model.setSecret(list.tokenAccount, $0) }),
                            prompt: Text("Optional bearer token"))
            }
            if let e = model.error(for: list.feed) { ErrorLabel(e) }
        } header: {
            SectionHeader(icon: "list.bullet.rectangle", title: list.name.isEmpty ? "Link list" : list.name,
                          detail: "\(model.count(feed: list.feed)) links", remove: remove)
        } footer: {
            Text("CSV with a header row (name, url; optionally aliases separated by ;, subtitle, kind) or JSON. A name that matches exactly one entry is linked without asking.")
        }
    }
}

// MARK: Search and keys

private struct SearchTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Search the web with", selection: $model.webProvider) {
                    Text("Off").tag(WebProvider?.none)
                    Text("Claude (Anthropic key)").tag(WebProvider?.some(.claude))
                    Text("Exa").tag(WebProvider?.some(.exa))
                    Text("Brave Search").tag(WebProvider?.some(.brave))
                }
                if let p = model.webProvider, (model.secret(AppModel.webKeyAccount(p))).isEmpty {
                    Label("Add your \(p.keyLabel) under API keys below", systemImage: "key").foregroundStyle(.orange)
                }
            } header: {
                SectionHeader(icon: "globe", title: "Web search")
            } footer: {
                Text("Used when nothing in your own context fits. Results show in the picker and are never inserted without asking. Claude runs the search itself and picks pages that fit your paragraph (a few seconds, about a cent). Exa and Brave are faster and get only the selected text.")
            }

            Section {
                KeyField(label: "Anthropic", account: AppModel.anthropicAccount, url: WebProvider.claude.keyURL, model: model)
                KeyField(label: "Exa", account: AppModel.webKeyAccount(.exa), url: WebProvider.exa.keyURL, model: model)
                KeyField(label: "Brave Search", account: AppModel.webKeyAccount(.brave), url: WebProvider.brave.keyURL, model: model)
            } header: {
                SectionHeader(icon: "key", title: "API keys")
            } footer: {
                Text("Stored in your Mac's keychain. The Anthropic key powers Claude web search, and with Exa or Brave it also ranks their results by your paragraph. Lists, blogs and MCP servers need no key.")
            }

            Section {
                TextField("URL", text: $model.searchTemplate, prompt: Text("https://example.com/search?q={query}"))
                if !model.searchTemplate.isEmpty {
                    TextField("Name", text: $model.searchName, prompt: Text("Shown on its results, e.g. CRM"))
                    SecureField("Token", text: Binding(get: { model.secret(AppModel.searchTokenAccount) },
                                                       set: { model.setSecret(AppModel.searchTokenAccount, $0) }),
                                prompt: Text("Optional bearer token"))
                }
            } header: {
                SectionHeader(icon: "magnifyingglass", title: "Your own search URL")
            } footer: {
                Text("Any endpoint that takes the search text in place of {query} and returns links in the list JSON format.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeyField: View {
    let label: String
    let account: String
    let url: URL
    @ObservedObject var model: AppModel
    @State private var editing = false

    var body: some View {
        let _ = model.keysVersion
        let saved = model.secret(account)
        LabeledContent(label) {
            HStack(spacing: 8) {
                if saved.isEmpty {
                    Link("Get a key", destination: url)
                    Button("Add Key…") { editing = true }
                } else {
                    Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("…" + saved.suffix(4)).monospaced().foregroundStyle(.secondary)
                    Button("Change…") { editing = true }
                    Button("Remove", role: .destructive) { model.setSecret(account, "") }
                }
            }
            .fixedSize()
        }
        .sheet(isPresented: $editing) {
            KeyEntrySheet(label: label, url: url) { model.setSecret(account, $0) }
        }
    }
}

/// A small window to paste an API key into.
private struct KeyEntrySheet: View {
    let label: String
    let url: URL
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(label) API key").font(.headline)
            Text("Paste your key below. It's stored in your Mac's keychain and only sent to \(label).")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Paste key here", text: $key)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
            HStack {
                Link("Get a key", destination: url).font(.callout)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { focused = true }
    }

    private func commit() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        save(k)
        dismiss()
    }
}

// MARK: Shared pieces

private struct SectionHeader: View {
    let icon: String
    let title: String
    var detail: String?
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title)
            if let detail { Text("· \(detail)").foregroundStyle(.secondary).fontWeight(.regular) }
            Spacer()
            if let remove {
                Button("Remove", role: .destructive, action: remove)
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
        }
    }
}

private struct ErrorLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
    }
}

/// Every remembered link, with its target clickable and a button to forget it.
private struct RememberedLinksView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [Store.Choice] = []

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(choices) { c in
                    HStack(spacing: 8) {
                        Favicon(url: c.candidate.url, kind: c.candidate.kind)
                        Text(c.key).lineLimit(1)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                        LinkText(url: c.candidate.url) { openLink($0) }
                        Spacer()
                        Button { model.forgetChoice(c.key); reload() } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Forget; ask again next time")
                    }
                }
            }
            Divider()
            HStack {
                Button("Forget All", role: .destructive) { model.forgetChoices(); reload() }
                    .disabled(choices.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 560, height: 420)
        .onAppear(perform: reload)
    }

    private func reload() { choices = model.store.allChoices() }
}

