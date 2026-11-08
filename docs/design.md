# Linker: design

A menu-bar utility for macOS that adds the right hyperlink to selected text in any app. The main target is writing email in a desktop client.

## Core interaction

1. **Invoke on a selection** with a global hotkey (⌃⌥K).
   - With only a cursor, expand to the longest known name (up to six words) touching the cursor. If nothing known is there, show a hint.
   - With the cursor inside an existing link, select the whole link and offer to replace or remove it.
2. **Resolve** the selection against the local index.
3. **Certain match → link inserted immediately.** A note ("Linked → example.com/about") appears under the text for about four seconds and stays while hovered. Clicking the URL opens it in the browser, "Change" reopens the picker, and ⌘Z undoes.
4. **Uncertain → picker** anchored under the selection. It never takes focus away from the email. Return accepts the top row.
5. **Link all** (⌃⌥⇧K, nothing selected): scan the whole text for known names and show one checklist with every row ticked. Each URL is clickable. Confirming links the first mention of each name.
6. **Already-linked text:** the picker shows the current link (clickable) with "Remove Link" (⌘⌫).

## Confidence rule

A link goes in without asking only when:
- the user picked a link for this exact text before (normalized: case, diacritics, a leading "the", a possessive and legal suffixes like GmbH or Inc are ignored), or
- exactly one entry in a link list or blog has this name or alias, and its URL answers within two seconds.

Everything else goes to the picker. Results from live search (MCP search tools, the user's search endpoint, the web) are never inserted unasked. MCP search results are kept only when every query word starts a word of the name, and a LinkedIn profile only when its address contains part of the person's name. With Link all, a name that starts with a capital letter only matches capitalized text, so "the notion that…" doesn't link a company called Notion.

## Sources

| Source | Sync | Badge |
|---|---|---|
| Remembered choices | Every pick is stored (text → URL); editable in Settings | "Used before" |
| Link lists: CSV/JSON, a local file or a URL with an optional bearer token | Daily, and on "Sync Now" | The list's name |
| MCP server, sync tool: called with no arguments; every result object with a name and a URL is indexed | Daily | The server's name |
| MCP server, search tools: called with the query (in the tool's first required string argument) | Live, from the picker | The server's name |
| Blogs: Substack archive API (cursor or offset paging), else RSS/Atom (`/feed`, `/rss`, …) | Daily | The blog's host |
| Search endpoint: `GET` a URL template with `{query}`, returning the list JSON | Live, from the picker | The endpoint's name |
| Web search: Exa or Brave, plus LinkedIn profiles for text that looks like a person's name | Live, from the picker | "Web" |
| Claude ranking (Claude Haiku, structured output) | Reorders web results using the paragraph; drops namesakes | — |

**Privacy:** web search receives only the selected text. Claude ranking receives the selected text, its paragraph and the result titles and URLs. Nothing else from the document leaves the Mac. Keys live in the Keychain.

## Picker

- A floating panel in the system's translucent material, anchored to the selected text, up to six rows.
- Each row: favicon, title, date for posts, headline for people, the URL as a clickable link, and the source badge.
- A search field prefilled with the selection; typing refines the search live. A typed or pasted URL becomes a row of its own.
- Keys: ↑↓, Return, ⌘1–6, ⌘O (open the selected URL), ⌘C (copy the URL instead of inserting it), Esc.
- Opening a link keeps the picker up. Choosing afterwards brings the email app back to the front and restores its selection before pasting.
- Local results appear at once. Live results are appended when they arrive, with a spinner.

## Insertion

Paste rich text (HTML and RTF with the link) over the selection:
1. Save the clipboard.
2. Write the link to the clipboard, marked transient so clipboard managers don't record it.
3. Simulate ⌘V once the hotkey's modifiers are released.
4. Restore the clipboard, unless something else wrote to it meanwhile.

Removing a link pastes the same text without one. Link all pastes from the last match to the first, selecting each range through Accessibility, with one clipboard save and restore around the batch.

## Feasibility results (spike, macOS 26, a WebKit-based mail client)

| Check | Result |
|---|---|
| Read the selection and its range through Accessibility | ✅ The editor is a WebKit text area |
| Read the surrounding paragraph | ✅ From the field's value |
| Position of the selection on screen | ✅ |
| Paste an HTML/RTF link over the selection | ✅ A real link (`AXLink`); the email's font and styling are kept |
| Restore the clipboard | ✅ |
| Undo | ✅ One "Undo Paste" restores the plain text |
| A floating panel that doesn't take focus | ✅ The panel receives keystrokes; the mail app stays active and keeps its selection |

Consequences: keep the hotkey + rich-text paste approach. Panel placement converts the Accessibility position using the screen that contains the selection.
