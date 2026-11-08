# Linker: working notes

Read docs/design.md first. It is the source of truth for scope, the auto-insert rules and the UI.

## Layout (Swift Package Manager; Xcode isn't required, only the command-line tools)
- `Sources/LinkerCore`: Foundation-only code, no AppKit/SwiftUI/ApplicationServices. It holds:
  - models
  - the SQLite store (link the system SQLite library)
  - sources: link lists (CSV/JSON, file or URL), blogs (Substack archive, RSS/Atom)
  - MCP: a generic client (streamable HTTP, OAuth sign-in or token), sync and search sources, result extraction
  - live search: the user's search endpoint, web search (Claude, Exa, Brave), Claude ranking
  - the resolver (matching plus the confidence rule) and the scanner for "Link all"
  This target must build on Linux. Run the checks with `swift run LinkerChecks`.
- `Sources/Linker`: the macOS app. It holds:
  - the menu-bar app with no Dock icon (`LSUIElement`)
  - the global hotkeys (Carbon `RegisterEventHotKey`)
  - reading the selection and existing links through the Accessibility API
  - rich-text paste with clipboard save and restore
  - the non-activating floating panels (picker, Link all) and the confirmation note
  - Settings, with keys and tokens stored in the Keychain
  Reuse the patterns proven in `spike/`. This target can only be built and tested on a Mac.
- `scripts/bundle.sh`: builds a release `.app`. `BUNDLE_ID` sets the identifier.

## Rules
- The app has no built-in data sources and no dependency on any company's systems. Everything it links comes from
  sources the user configures. Keep it that way.
- Never commit API keys, tokens, or anyone's real link data. Examples and checks use made-up names and `.example` URLs.
- Live search and web results are never inserted without asking.
- Cloud sessions run on Linux: work in LinkerCore and its checks. Write the macOS target carefully, mark it
  unverified, and leave compiling and testing to a Mac session.
