# Linker

Add the right hyperlink to selected text in any Mac app. Select a name, press **⌃⌥K**, and Linker inserts the link. If it isn't sure, it shows a short list to pick from.

Built for writing email in a desktop client (tested most with Mimestream; also works in Apple Mail, Notes, TextEdit, and Gmail or Google Docs in a browser), where adding a link normally means: select, ⌘K, go find the URL in a browser, check it's the right one, paste, confirm.

## What it does

- **⌃⌥K on a selection**: if the text matches exactly one entry in your link lists or blogs, or a link you picked for this text before, the link goes in at once. A small note shows where it points. Click the URL to check it, or click "Change". ⌘Z undoes it.
- **Otherwise a picker** opens under the selection, without taking focus from your email. It shows your own links first, then results from your search endpoint and the web. Every URL in it can be clicked to open it in the browser before you choose. Keys: ↩ link, ⌘O open, ⌘C copy URL, ⌘1–6 pick, Esc cancel. You can also type or paste a URL.
- **⌃⌥K with just a cursor** links the known name the cursor is in.
- **⌃⌥⇧K** always opens the picker. With nothing selected, it finds every known name in the text and shows one checklist ("Link 4 names?"). It links the first mention of each.
- **On text that already has a link**, the picker shows the current link and offers to replace or remove it.
- **It remembers your choices**: what you pick for a piece of text is used without asking next time. You can review and forget these in Settings.

## Your context

Linker knows only what you give it. Everything is set up in Settings:

| Source | What it's for | Auto-inserts? |
|---|---|---|
| **MCP server**: any server on the streamable HTTP transport, with browser sign-in (OAuth), a token, or open | Your company's knowledge base, CRM or wiki. Pick "search tools" for the picker and, optionally, a "sync tool" whose results work like a link list | Sync tool results: yes, on a unique match. Search tools: no |
| **Link lists**: CSV or JSON, as a local file or a URL (optionally with a bearer token) | Your clients, portfolio, team, products, favourite references | Yes, when exactly one entry matches |
| **Blogs and newsletters**: Substack (full archive) or any RSS/Atom feed | Linking post titles | Yes, on an exact title match |
| **Your search URL**: `https://…?q={query}` returning the list JSON | A CRM, wiki or internal tool your team already has | No, picker only |
| **Web search**: Claude, Exa or Brave, with your own API key | Everything else: company homepages, LinkedIn profiles, articles | No, picker only |
| **Claude ranking** (optional, with Exa or Brave) | Orders their results by the paragraph you're writing, drops namesakes | — |

For an MCP server, Linker reads any result object that has a name (`name`, `title`, …) and a URL (`url`, `website`, `linkedin`, …), at any depth. So most servers work without configuration; search results are filtered to names that match what you typed.

A link list looks like this ([example](examples/links.csv)):

```csv
name,url,aliases,subtitle,kind
Acme,https://acme.example,Acme Corp; ACME Inc,Makes anvils,company
Ada Lovelace,https://www.linkedin.com/in/example,,Analyst,person
```

JSON works too: `[{"name": "Acme", "url": "acme.example", "aliases": ["Acme Corp"]}]`. `kind` is `company`, `person`, `post` or `link`. A list served from a URL is re-synced daily, so a team can share one list.

**No API keys are needed** for MCP servers, lists, blogs and remembered links. For web search, pick one:
- **Claude**, with an [Anthropic API key](https://console.anthropic.com). Claude runs the search itself and picks links that fit your paragraph. One key, a few seconds and about a cent per lookup.
- **[Exa](https://exa.ai)** or **[Brave Search](https://brave.com/search/api/)**, faster, both with free tiers. Add an Anthropic key too and Claude ranks their results.

Keys are stored in the macOS Keychain.

**Privacy**: Linker reads the selection and its paragraph through the Accessibility API. Exa and Brave receive only the selected text. Claude (searching or ranking) also receives the paragraph. Nothing else from your document leaves the Mac, and there is no telemetry.

## Install

Requires macOS 14 or later and the Xcode command-line tools (`xcode-select --install`).

```bash
git clone https://github.com/chrija76/linker.git && cd linker
scripts/make-cert.sh   # once: a local signing identity, so the Accessibility permission survives rebuilds
scripts/bundle.sh      # builds build/Linker.app
cp -R build/Linker.app /Applications/ && open /Applications/Linker.app
```

On first launch, allow Linker under System Settings → Privacy & Security → Accessibility. It needs this to read the selection and paste the link.

## How it works

- Reads the selection, its paragraph and its position through the Accessibility API.
- Pastes the link as rich text (HTML and RTF) over the selection with a simulated ⌘V. It then restores your clipboard and marks the paste as transient so clipboard managers skip it. The email keeps its font and styling, and the editor's own undo works.
- The picker is a non-activating panel, so the email app stays in front and keeps its selection.
- Lists and posts are indexed in a local SQLite database with full-text search.

Code layout: `Sources/LinkerCore` (matching, sources, store; Foundation only, builds on Linux), `Sources/Linker` (the macOS app), `Sources/LinkerChecks` (checks: `swift run LinkerChecks`), `spike/` (the original feasibility probes). Design notes are in [docs/design.md](docs/design.md).

## Limits

- Editors that drop links when pasting rich text (rare) won't work.
- With a link already on the text, the picker can only detect it in editors that expose links through Accessibility. Mail clients built on WebKit and native text views do.
- Not on the App Store: sandboxed apps can't read or paste into other apps.
