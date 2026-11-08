// Checks for LinkerCore. Run with `swift run LinkerChecks` (XCTest isn't available without Xcode).
// All names and URLs here are made up.
import Foundation
import LinkerCore

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(what)") }
}

// Normalize
check(Normalize.key("The Acme's") == "acme", "possessive and leading 'the'")
check(Normalize.key("Globex Systems GmbH") == "globex systems", "legal suffix")
check(Normalize.key("  Zürich—AI.  ") == "zurich ai", "diacritics and punctuation")
check(Normalize.key("SE") == "se", "a lone suffix word stays")

// Store + resolver
let store = try Store(path: ":memory:")
let resolver = Resolver(store: store)
func co(_ name: String, _ url: String, aliases: [String] = []) -> Entity {
    Entity(id: "c:\(name)", kind: .company, source: .list, name: name, aliases: aliases, url: URL(string: url)!, badge: "Clients")
}
try store.replace(feed: "list:clients", with: [
    co("Acme", "https://www.acme.example", aliases: ["Acme Corp"]),
    co("Globex", "https://www.globex.example"),
    co("Hooli", "https://hooli.example"),
])
try store.replace(feed: "feed:blog.example", with: [
    Entity(id: "s:1", kind: .post, source: .feed, name: "The pricing napkin", url: URL(string: "https://blog.example/p/napkin")!,
           subtitle: "Five pricing rules", date: Date(), badge: "blog.example"),
    Entity(id: "s:2", kind: .post, source: .feed, name: "Hooli and the future of video", url: URL(string: "https://blog.example/p/hooli")!),
])

if case .certain(let c) = resolver.resolve("Acme") {
    check(c.url.host == "www.acme.example", "acme url")
    check(c.badgeText == "Clients", "list name is the badge")
} else { check(false, "Acme should be certain") }
if case .certain = resolver.resolve("acme corp") {} else { check(false, "alias should be certain") }
if case .certain(let c) = resolver.resolve("the Pricing Napkin") { check(c.kind == .post, "post kind") } else { check(false, "exact post title should be certain") }
if case .choose(let list) = resolver.resolve("napkin") {
    check(list.first?.title == "The pricing napkin", "prefix search finds the post")
} else { check(false, "partial title should go to the picker") }
if case .choose(let list) = resolver.resolve("Globe") { check(list.first?.title == "Globex", "prefix search") } else { check(false, "prefix should not be certain") }

// Two different entities with the same name → picker
try store.replace(feed: "list:people", with: [
    Entity(id: "p:1", kind: .person, source: .list, name: "Hooli", url: URL(string: "https://www.linkedin.com/in/hooli")!),
])
if case .choose(let list) = resolver.resolve("Hooli") { check(list.count >= 2, "ambiguous exact gives options") } else { check(false, "ambiguous should not be certain") }

// Remembered choice wins, can be listed and forgotten
store.remember(key: Normalize.key("Hooli"), Candidate(title: "Hooli", url: URL(string: "https://hooli.example")!, kind: .company, source: .list))
if case .certain(let c) = resolver.resolve("Hooli") { check(c.source == .remembered, "remembered") } else { check(false, "remembered should be certain") }
check(store.choiceCount() == 1 && store.allChoices().first?.key == "hooli", "one remembered choice")

// Link all: first mention of each known name, longest match, capitalization respected, linked text skipped
let draft = "Hi Sam, Acme Corp and Globex are great. Acme again. The pricing napkin helps. hooli is lowercase.\nHooli too."
let alreadyLinked = (draft as NSString).range(of: "Globex")
let matches = LinkScanner(resolver: resolver).scan(draft, excluding: [alreadyLinked])
check(matches.map(\.text) == ["Acme Corp", "The pricing napkin", "Hooli"], "scan found \(matches.map(\.text))")
check(matches.first?.range == (draft as NSString).range(of: "Acme Corp"), "scan range")

store.forgetChoice(key: "hooli")
check(store.choiceCount() == 0, "forget one choice")

// Re-sync replaces a feed and nothing else
try store.replace(feed: "list:clients", with: [co("Acme", "https://www.acme.example")])
check(store.exact(key: "globex").isEmpty, "removed after re-sync")
check(store.count(source: .feed) == 2 && store.count(feed: "list:clients") == 1, "other feeds untouched")
check(store.hasExact(key: "acme") && !store.hasExact(key: "acm"), "hasExact")
check(Set(store.feeds()) == ["list:clients", "list:people", "feed:blog.example"], "feeds listed")

// URL parsing and display
check(URL.lenient("initech.io")?.absoluteString == "https://initech.io", "lenient adds scheme")
check(URL.lenient("not a url") == nil && URL.lenient("ftp://x.example") == nil, "lenient rejects text and other schemes")
check(URL(string: "https://www.acme.example/blog/")!.displayString == "acme.example/blog", "display string")

// Link list formats
let json = #"[{"name": "Acme", "url": "acme.example", "aliases": ["ACME Inc"], "kind": "company"}, {"title": "Ada", "url": "https://x.example/ada", "kind": "person"}, {"name": "no url"}]"#
let rowsJ = try LinkListParser.parse(Data(json.utf8))
check(rowsJ.count == 2 && rowsJ[0].aliases == ["ACME Inc"] && rowsJ[1].kind == .person, "json list")
let csv = "\u{FEFF}name,url,aliases,subtitle\nAcme,acme.example,\"ACME Inc; Acme Corp\",\"Makes, things\"\n\nGlobex,globex.example,,\n"
let rowsC = try LinkListParser.parse(Data(csv.utf8))
check(rowsC.count == 2 && rowsC[0].aliases == ["ACME Inc", "Acme Corp"] && rowsC[0].subtitle == "Makes, things", "csv list \(rowsC)")
let semi = "Name;URL\nInitech;initech.example\n"
check((try LinkListParser.parse(Data(semi.utf8))).first?.name == "Initech", "semicolon csv")

// Feeds
let rss = """
<?xml version="1.0"?><rss version="2.0"><channel><title>Blog</title><link>https://blog.example</link>
<item><title>First &amp; best</title><link>https://blog.example/first</link><pubDate>Tue, 01 Oct 2024 10:00:00 +0000</pubDate>
<description><![CDATA[<p>Hello <b>world</b></p>]]></description></item></channel></rss>
"""
let items = FeedParser.parse(Data(rss.utf8))
check(items.count == 1 && items[0].title == "First & best" && items[0].date != nil && items[0].summary == "Hello world", "rss \(items)")
let atom = """
<feed xmlns="http://www.w3.org/2005/Atom"><title>A</title><entry><title>Post</title>
<link rel="alternate" href="https://a.example/post"/><updated>2024-05-01T10:00:00Z</updated></entry></feed>
"""
check(FeedParser.parse(Data(atom.utf8)).first?.url.absoluteString == "https://a.example/post", "atom")
check(FeedSource.parseDate("2024-05-01T10:00:00.000Z") != nil, "fractional ISO date")

// Web search helpers
check(WebSearch.looksLikePersonName("Ada Lovelace") && !WebSearch.looksLikePersonName("Acme") &&
      !WebSearch.looksLikePersonName("the pricing napkin"), "person-name heuristic")

// MCP tool results: any object with a name and a URL, at any depth
let toolResult: [String: Any] = ["by_name": ["rows": [
    ["c.name": "Acme", "c.website": "acme.example", "c.brief": "Makes anvils"],
    ["p.name": "Ada Lovelace", "p.linkedin": "https://www.linkedin.com/in/ada-lovelace", "p.title": "Analyst"],
    ["c.name": "Fwd: Acme intro", "c.website": "acme.example"],
    ["c.name": "No URL here"],
]], "count": 4]
let mcpLinks = MCPExtract.links(in: toolResult)
check(mcpLinks.map(\.name) == ["Acme", "Ada Lovelace"], "mcp links \(mcpLinks.map(\.name))")
check(mcpLinks.first?.subtitle == "Makes anvils" && mcpLinks.last?.subtitle == "Analyst", "mcp subtitles")
check(MCPExtract.links(in: [["title": "A post", "url": "https://blog.example/p/a"]]).first?.name == "A post", "title as name")
check(MCPExtract.nameMatches("Ada Lovelace", query: "lovelace") && !MCPExtract.nameMatches("Ada Smith", query: "ada lovelace"), "mcp name filter")
check(MCPExtract.profileFits(URL(string: "https://www.linkedin.com/in/ada-lovelace/")!, name: "Ada Lovelace") &&
      !MCPExtract.profileFits(URL(string: "https://www.linkedin.com/in/someone-else-41")!, name: "Ada Lovelace"), "linkedin profile fit")

// Claude web search reply: Claude's chosen links, else the raw search results
let reply: [String: Any] = ["stop_reason": "end_turn", "content": [
    ["type": "server_tool_use", "name": "web_search"],
    ["type": "web_search_tool_result", "content": [["type": "web_search_result", "title": "Acme", "url": "https://acme.example/"],
                                                     ["type": "web_search_result", "title": "Other", "url": "https://other.example/x"]]],
    ["type": "text", "text": "Here you go: {\"links\": [{\"title\": \"Acme Inc\", \"url\": \"https://acme.example\"}]}"],
]]
let picked = ClaudeWebSearch.candidates(from: reply)
check(picked.count == 1 && picked[0].title == "Acme Inc" && picked[0].kind == .company && picked[0].badgeText == "Claude", "claude picks \(picked)")
var noText = reply
noText["content"] = Array((reply["content"] as! [[String: Any]]).prefix(2))
check(ClaudeWebSearch.candidates(from: noText).map(\.url.absoluteString) == ["https://acme.example/", "https://other.example/x"], "raw results fallback")

print(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
