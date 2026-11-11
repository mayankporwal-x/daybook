// Daybook ← AI chats: turns coding-assistant chats saved on this Mac into Board items.
//
// When switched on, new chats that are about a PR, a task or an issue become an item on the
// Board ("In progress" / "To do", dated the day the chat started). Other chats (stand-up notes,
// questions, personal stuff) are skipped. Chats are read from the local transcripts only;
// nothing is sent anywhere.

import Foundation

struct ChatSyncResult { var created = 0; var updated = 0; var skipped = 0; var added: [String] = [] }
struct ChatStatus { var available: Bool; var lastCheck: String?; var lastAdded: [String]; var skipped: [String] }

// MARK: - Constants

private let homeDir: String = {  // os.path.expanduser("~"): $HOME, else the account's home
    if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return h }
    if let pw = getpwuid(getuid()), let d = pw.pointee.pw_dir { return String(cString: d) }
    return NSHomeDirectory()
}()
// Where the coding assistant stores its chats on this Mac (fixed by that tool, not by Daybook).
private let chatProjects = homeDir + "/.claude/projects"
private let desktopSessionsDir = homeDir + "/Library/Application Support/Claude/claude-code-sessions"
private let prReviewMinutes = 30   // default time estimate for PR review items
private let indexVersion = 3
private let maxParsedLine = 400_000

// MARK: - Regexes (NSRegularExpression is immutable and thread-safe)

private final class Rx {
    let re: NSRegularExpression
    init(_ pattern: String, ci: Bool = false) {
        re = try! NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : [])
    }
    init?(dynamic pattern: String, ci: Bool = false) {
        guard let r = try? NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : []) else { return nil }
        re = r
    }
    private static func groups(_ m: NSTextCheckingResult, _ ns: NSString) -> [String?] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }
    func test(_ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
    /// Groups of the first match (index 0 = whole match), like re.search.
    func search(_ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Rx.groups(m, ns)
    }
    /// Groups of every non-overlapping match, like re.finditer.
    func all(_ s: String) -> [[String?]] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { Rx.groups($0, ns) }
    }
    /// Like re.sub with a literal replacement.
    func sub(_ s: String, _ with: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                    withTemplate: NSRegularExpression.escapedTemplate(for: with))
    }
}

// what makes a chat "work": a PR, a task or an issue
private let prURLRx = Rx(#"https://github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)"#)
private let linearURLRx = Rx(#"https://linear\.app/[\w-]+/issue/([A-Za-z][A-Za-z0-9]{1,5}-\d+)"#)
private let ticketRx = Rx(#"\b([A-Z][A-Z0-9]{1,5})-(\d{2,6})\b"#)
private let notTickets: Set<String> = ["UTF", "ISO", "SHA", "RFC", "AES", "RSA", "HTTP", "TLS", "COVID", "GPT", "CVE",
                                       "MP3", "MP4", "IPV4", "IPV6", "ES", "PEP"]
private let prWordsRx = Rx(#"\bPRs?\b|pull request|code review"#, ci: true)
private let taskWordsRx = Rx(#"\b(?:new|assigned)\s+(?:task|issue|bug|ticket)s?\b"#
                             + #"|\b(?:task|issue|bug|ticket)s?\s+(?:got\s+|was\s+|is\s+|has\s+been\s+)?assigned\b"#, ci: true)
private let explicitTypeRx = Rx(#"\b(?:new|assigned)\s+(task|issue|bug|ticket)s?\b"#
                                + #"|\b(task|issue|bug|ticket)s?\s+(?:got\s+|was\s+|is\s+|has\s+been\s+)?assigned\b"#, ci: true)
private let bugWordsRx = Rx(#"(?<![a-z])(?:bugs?|fix|fixes|fixed|broken|breaks|crash(?:es)?|regression|errors?|lost|loss|"#
                            + #"wrong|incorrect|not working|fails|failing|doesn'?t work)(?![a-z])"#, ci: true)
private let planAskRx = Rx(#"\b(?:create|make|write|draft|prepare|give me|come up with)\s+(?:a\s+|an\s+|the\s+)?"#
                           + #"(?:detailed\s+|implementation\s+|step[- ]by[- ]step\s+)?plan\b"#, ci: true)
private let tagRx = Rx(#"<[^>]{1,200}>"#)
private let multiSpaceRx = Rx(#"\s{2,}"#)
private let edgePunctRx = Rx(#"^[\s|:·,\-–—]+|[\s|:·,\-–—]+$"#)
private let desktopIdRx = Rx(#"^local_[A-Za-z0-9-]{1,64}$"#)
private let noisePrefixes = ["<command-name>", "<local-command", "Caveat:", "[Request interrupted", "<system-reminder>",
                             "<task-notification>", "<side-sessions-event>", "<ci-monitor-event>"]

// signs that work on a task actually started in the chat (a plan, or code changes) — matched on raw bytes
private func b(_ s: String) -> [UInt8] { Array(s.utf8) }
private let toolHead = b(#""type":"tool_use","id":""#)
private let toolName = b(#"","name":""#)
private let toolInput = b(#"","input":{"#)
private let editTools: Set<[UInt8]> = [b("Edit"), b("Write"), b("MultiEdit"), b("NotebookEdit")]
private let startTools: [[UInt8]: String] = [b("ExitPlanMode"): "plan", b("EnterWorktree"): "branch",
                                             b("mcp__ccd_directory__propose_branch"): "branch"]
private let bashTool = b("Bash")
private let gitStarts = [b("git commit"), b("git checkout -b"), b("git switch -c"), b("git worktree add"), b("gh pr create")]
private let filePathKeys = [b(#""file_path":""#), b(#""notebook_path":""#)]
private let timestampKey = [b(#""timestamp":""#)]
private let notWorkPaths = ["/.claude/", "/tmp/", "/private/tmp/", "/private/var/folders/", "/var/folders/"]
private let bToolUse = b(#""tool_use""#)
private let bAiTitle = b(#""ai-title""#)
private let bCustomTitle = b(#""custom-title""#)
private let bPrLink = b(#""pr-link""#)
private let bTypeUser = b(#""type":"user""#)
private let bToolResult = b(#""tool_result""#)
private let bPlan = b("plan")

// MARK: - Python-compatible string helpers

private typealias Bytes = UnsafeBufferPointer<UInt8>

/// Non-empty string or nil (Python truthiness of an optional str).
private func nz(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }

/// s[:n] counted in code points, like Python.
private func pre(_ s: String, _ n: Int) -> String {
    let u = s.unicodeScalars
    guard let i = u.index(u.startIndex, offsetBy: n, limitedBy: u.endIndex) else { return s }
    return String(String.UnicodeScalarView(u[..<i]))
}

private func isPySpace(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
    default: return false
    }
}

/// str.strip()
private func pyStrip(_ s: String) -> String {
    let u = s.unicodeScalars
    guard let a = u.firstIndex(where: { !isPySpace($0) }), let z = u.lastIndex(where: { !isPySpace($0) }) else { return "" }
    return String(String.UnicodeScalarView(u[a...z]))
}

/// str.splitlines()
private func pySplitLines(_ s: String) -> [String] {
    var out: [String] = [], cur = String.UnicodeScalarView()
    for c in s.unicodeScalars {
        switch c.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
            out.append(String(cur)); cur = String.UnicodeScalarView()
        default: cur.append(c)
        }
    }
    if !cur.isEmpty { out.append(String(cur)) }
    return out
}

/// Python truthiness of a value from JSONSerialization.
private func truthy(_ v: Any?) -> Bool {
    guard let v = v, !(v is NSNull) else { return false }
    if let s = v as? String { return !s.isEmpty }
    if let n = v as? NSNumber { return n.doubleValue != 0 }
    if let a = v as? [Any] { return !a.isEmpty }
    if let d = v as? [String: Any] { return !d.isEmpty }
    return true
}

/// Python truthiness of a JSONValue.
private func truthy(_ v: JSONValue?) -> Bool {
    switch v {
    case nil, .null?: return false
    case .bool(let x)?: return x
    case .number(let n)?: return n != 0
    case .string(let s)?: return !s.isEmpty
    case .array(let a)?: return !a.isEmpty
    case .object(let o)?: return !o.isEmpty
    }
}

private func hexId() -> String {
    String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(11))
}

/// datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp(), or 0.
private func isoTimestamp(_ s: String) -> Double {
    if s.isEmpty { return 0 }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d.timeIntervalSince1970 }
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: s) { return d.timeIntervalSince1970 }
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = .current
    for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss",
                "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
        df.dateFormat = fmt
        if let d = df.date(from: s) { return d.timeIntervalSince1970 }
    }
    return 0
}

// MARK: - Byte helpers

private func find(_ h: Bytes, _ needle: [UInt8], from: Int = 0) -> Int? {
    guard let base = h.baseAddress, from < h.count else { return nil }
    let r = needle.withUnsafeBytes { nb in memmem(base + from, h.count - from, nb.baseAddress!, nb.count) }
    guard let r = r else { return nil }
    return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(r))
}

private func has(_ h: Bytes, _ needle: [UInt8]) -> Bool { find(h, needle) != nil }

private func startsWith(_ h: Bytes, at i: Int, _ p: [UInt8]) -> Bool {
    guard i + p.count <= h.count else { return false }
    for k in 0..<p.count where h[i + k] != p[k] { return false }
    return true
}

/// re.search(rb'"(?:key1|key2)":"([^"]+)"', h) → group 1, scanning candidates from the left.
private func quotedValue(_ h: Bytes, keys: [[UInt8]]) -> String? {
    var i = 0
    while i < h.count {
        // next position where any key starts
        var cand: (Int, [UInt8])? = nil
        for k in keys { if let p = find(h, k, from: i), cand == nil || p < cand!.0 { cand = (p, k) } }
        guard let (p, key) = cand else { return nil }
        let st = p + key.count
        var j = st
        while j < h.count && h[j] != 0x22 { j += 1 }
        if j > st && j < h.count { return String(decoding: UnsafeBufferPointer(rebasing: h[st..<j]), as: UTF8.self) }
        i = p + 1
    }
    return nil
}

// MARK: - Index records (same JSON keys as the Python version)

private struct FileRec: Codable {
    var sid: String?
    var offset: Int?
    var size: Int?
    var first: String?
    var aiTitle: String?
    var customTitle: String?
    var prs: [String]?
    var startedAt: String?
    var cwd: String?
    var branch: String?
    var workAt: String?
    var workHow: String?

    enum CodingKeys: String, CodingKey {
        case sid, offset, size, first, aiTitle, customTitle, prs, startedAt, cwd, branch, workAt, workHow
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        func i(_ k: CodingKeys) -> Int? {
            if let v = try? c.decodeIfPresent(Int.self, forKey: k) { return v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: k) { return Int(v) }
            return nil
        }
        sid = s(.sid); offset = i(.offset); size = i(.size); first = s(.first); aiTitle = s(.aiTitle)
        customTitle = s(.customTitle); startedAt = s(.startedAt); cwd = s(.cwd); branch = s(.branch)
        workAt = s(.workAt); workHow = s(.workHow)
        prs = (try? c.decodeIfPresent([String].self, forKey: .prs)) ?? nil
    }

    var anyTitle: String { nz(customTitle) ?? nz(aiTitle) ?? "" }
}

private struct IndexFile: Codable {
    var version: Int? = indexVersion
    var files: [String: FileRec]? = [:]
}

private struct ChatState: Codable {
    var seen: [String: String] = [:]
    var lastCheck: String?
    var skipped: [String]?
    var lastAdded: [String]?

    enum CodingKeys: String, CodingKey { case seen, lastCheck, skipped, lastAdded }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seen = (try? c.decodeIfPresent([String: String].self, forKey: .seen)) ?? nil ?? [:]
        lastCheck = (try? c.decodeIfPresent(String.self, forKey: .lastCheck)) ?? nil
        skipped = (try? c.decodeIfPresent([String].self, forKey: .skipped)) ?? nil
        lastAdded = (try? c.decodeIfPresent([String].self, forKey: .lastAdded)) ?? nil
    }
}

// MARK: - Classification and titles

private func tickets(_ text: String) -> [String] {
    ticketRx.all(text).compactMap { g in
        guard let a = g[1], let n = g[2], !notTickets.contains(a) else { return nil }
        return "\(a)-\(n)"
    }
}

private func prRef(_ g: [String?]) -> String { "\(g[1] ?? "")/\(g[2] ?? "")#\(g[3] ?? "")" }

/// (kind, key, label) for chats about a PR / task / issue, else nil.
/// `key` de-duplicates: several chats about the same PR or ticket give one Board item.
private func classify(_ rec: FileRec) -> (kind: String, key: String, label: String)? {
    let title = rec.anyTitle
    let first = rec.first ?? ""
    if title.lowercased().hasPrefix("btw:") { return nil }  // side-question forks of another chat
    if let m = prURLRx.search(first) {
        let ref = prRef(m)
        return ("pr", ref, "PR \(ref)")
    }
    if let t = tickets(title).first { return ("issue", t, t) }
    if let m = linearURLRx.search(first), let id = m[1] {
        return ("issue", id.uppercased(), id.uppercased())
    }
    if let p = rec.prs?.first {
        if let m = prURLRx.search(p) {
            let ref = prRef(m)
            return ("pr", ref, "PR \(ref)")
        }
    }
    let sid = rec.sid ?? ""
    if prWordsRx.test(title) { return ("pr", "chat:" + sid, "PR") }
    let head = pre(first, 600)
    if taskWordsRx.test(head) || taskWordsRx.test(title) { return ("task", "chat:" + sid, "Task") }
    if let t = tickets(head).first { return ("issue", t, t) }
    return nil
}

private func chatTitle(_ rec: FileRec) -> String {
    if let t = nz(rec.customTitle) ?? nz(rec.aiTitle) { return t }
    let text = tagRx.sub(rec.first ?? "", " ")
    for raw in pySplitLines(text) {
        let line = pyStrip(raw)
        if !line.isEmpty { return pre(line, 90) + (line.unicodeScalars.count > 90 ? "…" : "") }
    }
    return "AI chat"
}

/// 'PR', 'Bug', 'Task' or 'Issue' — shown as a [Type] prefix on the Board item.
private func itemType(_ rec: FileRec, _ kind: String) -> String {
    if kind == "pr" { return "PR" }
    let title = rec.anyTitle
    let first = pre(rec.first ?? "", 600)
    let m = explicitTypeRx.search(first) ?? explicitTypeRx.search(title)
    let said = m.map { (($0[1] ?? nil) ?? ($0[2] ?? nil) ?? "").lowercased() } ?? ""
    let buggy = bugWordsRx.test(title) || bugWordsRx.test(first)
    if said == "bug" { return "Bug" }
    if said == "task" { return "Task" }
    if said == "issue" || said == "ticket" { return buggy ? "Bug" : "Issue" }
    return buggy ? "Bug" : "Task"
}

/// Linear ticket IDs (max 2) and the PR number found in the chat, e.g. (["ABC-123"], "4521").
private func itemIds(_ rec: FileRec, _ kind: String, _ key: String, _ commonPRs: Set<String>) -> ([String], String?) {
    let title = rec.anyTitle
    let first = pre(rec.first ?? "", 800)
    var ids: [String] = []
    let linear = linearURLRx.all(first).compactMap { $0[1]?.uppercased() }
    for t in tickets(title) + linear + tickets(first) where !ids.contains(t) { ids.append(t) }
    var pr: String?
    if kind == "pr" && !key.hasPrefix("chat:") {
        pr = key.components(separatedBy: "#").last
    } else {  // PR opened / linked during this chat (latest one that isn't a shared base PR)
        let own = (rec.prs ?? []).filter { !commonPRs.contains($0) }
        pr = own.last.flatMap { prURLRx.search($0) }.flatMap { $0[3] }
    }
    return (Array(ids.prefix(2)), pr)
}

/// '[Type] TICKET · #PR · chat title' — ticket and PR only when the chat has them.
private func itemTitle(_ rec: FileRec, _ kind: String, _ key: String, _ commonPRs: Set<String>) -> String {
    let title = chatTitle(rec)
    if title.hasPrefix("[") { return title }
    let (ids, prRaw) = itemIds(rec, kind, key, commonPRs)
    let pr = nz(prRaw)
    var rest = title
    for t in ids {  // don't repeat IDs that are already in the chat title
        if let rx = Rx(dynamic: #"\b"# + NSRegularExpression.escapedPattern(for: t) + #"\b"#) { rest = rx.sub(rest, " ") }
    }
    if let pr = pr, pr.unicodeScalars.count > 2,
       let rx = Rx(dynamic: #"(?:\bPR\s*|\bpull request\s*)?#?\b"# + pr + #"\b"#, ci: true) {
        rest = rx.sub(rest, " ")
    }
    rest = multiSpaceRx.sub(rest, " ")
    rest = edgePunctRx.sub(rest, "")
    if rest.isEmpty { rest = title }
    let parts = ["[\(itemType(rec, kind))]"] + ids + (pr.map { ["#" + $0] } ?? [])
    let head = parts[0] + (parts.count > 1 ? " " + parts[1...].joined(separator: " · ") : "")
    return parts.count > 1 ? "\(head) · \(rest)" : "\(head) \(rest)"
}

private func chatLink(_ rec: FileRec, _ kind: String, _ key: String, _ label: String, _ commonPRs: Set<String>) -> ChatLink {
    let cwd = nz(rec.cwd) ?? ""
    let sid = rec.sid ?? ""
    var project = ""
    if !cwd.isEmpty {
        var c = cwd
        while c.hasSuffix("/") { c.removeLast() }
        if let r = c.range(of: "/", options: .backwards) { project = String(c[r.upperBound...]) } else { project = c }
    }
    var l = ChatLink()
    l.type = ChatLink.kind; l.ref = sid; l.title = chatTitle(rec)
    l.meta = [
        "kind": .string(kind), "type": .string(itemType(rec, kind)), "key": .string(key), "about": .string(label),
        "project": .string(project), "branch": .string(nz(rec.branch) ?? ""),
        "startedAt": rec.startedAt.map { .string($0) } ?? .null,
        "autoTitle": .string(itemTitle(rec, kind, key, commonPRs)),
        "resume": .string(cwd.isEmpty ? "claude --resume \(sid)" : "cd \"\(cwd)\" && claude --resume \(sid)"),
    ]
    return l
}

/// Chat file id → (desktop session id 'local_…', archived) for chats started in the desktop app.
private func desktopSessions() -> [String: (String, Bool)] {
    var out: [String: (String, Bool)] = [:]
    let fm = FileManager.default
    for a in listDir(desktopSessionsDir) {
        let pa = desktopSessionsDir + "/" + a
        for b in listDir(pa) {
            let pb = pa + "/" + b
            for f in listDir(pb) where f.hasPrefix("local_") && f.hasSuffix(".json") {
                guard let data = fm.contents(atPath: pb + "/" + f),
                      let d = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
                else { continue }
                let sid = (d["sessionId"] as? String) ?? ""
                guard desktopIdRx.test(sid) else { continue }
                for key in ["cliSessionId", "lastAssistantCliSessionId"] {
                    if let cli = d[key] as? String, !cli.isEmpty { out[cli] = (sid, truthy(d["isArchived"])) }
                }
            }
        }
    }
    return out
}

/// Store the desktop session on a chat link; true if it changed.
private func setDesktop(_ l: inout ChatLink, _ desk: [String: (String, Bool)]) -> Bool {
    let entry = desk[l.ref]
    let sid = entry?.0, archived = entry?.1 ?? false
    let same: Bool
    switch l.meta["desktopSession"] {
    case nil, .null?: same = sid == nil
    case .string(let s)?: same = sid == s
    default: same = false
    }
    if same && truthy(l.meta["desktopArchived"]) == archived { return false }
    l.meta["desktopSession"] = sid.map { .string($0) } ?? .null
    l.meta["desktopArchived"] = .bool(archived)
    return true
}

private func isTwo(_ v: JSONValue?) -> Bool { if case .number(let n)? = v { return n == 2 }; return false }

/// PR reviews: In progress from the start. Tasks / bugs / issues: To do until the chat makes a plan
/// or starts changing code, then In progress (once — manual moves are kept).
private func applyStatusRule(_ t: inout DayTask, _ l: inout ChatLink, _ rec: FileRec) -> Bool {
    var changed = false
    if l.meta["kind"]?.string == "pr" {
        if !isTwo(l.meta["statusRule"]) { l.meta["statusRule"] = .number(2); changed = true }
        return changed
    }
    if !isTwo(l.meta["statusRule"]) {  // items added before this rule existed
        l.meta["statusRule"] = .number(2)
        l.meta["autoStarted"] = .bool(false)
        if t.status == "in_progress" && nz(rec.workAt) == nil { t.status = "todo" }
        changed = true
    }
    if nz(rec.workAt) != nil && !truthy(l.meta["autoStarted"]) {
        l.meta["autoStarted"] = .bool(true)
        if t.status == "todo" { t.status = "in_progress" }
        changed = true
    }
    if changed { t.updatedAt = nowLocal() }
    return changed
}

// MARK: - Transcript lines

/// Remember the first moment this chat made a plan or started changing code.
private func workSignal(_ raw: Bytes, _ rec: inout FileRec) {
    // TOOL_RE = '"type":"tool_use","id":"[^"]+","name":"([A-Za-z_]+)","input":\{(.{0,600})' (finditer, bytes)
    let n = raw.count
    var from = 0
    while let s = find(raw, toolHead, from: from) {
        var j = s + toolHead.count
        let idStart = j
        while j < n && raw[j] != 0x22 { j += 1 }
        guard j > idStart, startsWith(raw, at: j, toolName) else { from = s + 1; continue }
        j += toolName.count
        let nameStart = j
        while j < n && isNameByte(raw[j]) { j += 1 }
        guard j > nameStart, startsWith(raw, at: j, toolInput) else { from = s + 1; continue }
        let name = Array(raw[nameStart..<j])
        let argsStart = j + toolInput.count
        var k = argsStart
        while k < n && k - argsStart < 600 && raw[k] != 0x0A { k += 1 }
        let args = Bytes(rebasing: raw[argsStart..<k])
        from = k

        var how: String?
        if let h = startTools[name] {
            how = h
        } else if editTools.contains(name) {
            let path = quotedValue(args, keys: filePathKeys) ?? ""
            if path.range(of: "/.claude/plans/", options: .literal) != nil {
                how = "plan"
            } else if !path.isEmpty && !notWorkPaths.contains(where: { path.range(of: $0, options: .literal) != nil }) {
                how = "edit"
            }
        } else if name == bashTool && gitStarts.contains(where: { has(args, $0) }) {
            how = "git"
        }
        if let how = how {
            rec.workAt = quotedValue(raw, keys: timestampKey) ?? nowLocal()
            rec.workHow = how
            return
        }
    }
}

private func isNameByte(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F }

private func parseJSON(_ raw: Bytes) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(buffer: raw), options: [.fragmentsAllowed])) as? [String: Any]
}

private func parseLine(_ raw: Bytes, _ rec: inout FileRec) {
    if has(raw, bAiTitle) {
        if let o = parseJSON(raw), o["type"] as? String == "ai-title" { rec.aiTitle = o["aiTitle"] as? String }
        return
    }
    if has(raw, bCustomTitle) {
        if let o = parseJSON(raw), o["type"] as? String == "custom-title" { rec.customTitle = o["customTitle"] as? String }
        return
    }
    if has(raw, bPrLink) {
        if let o = parseJSON(raw), o["type"] as? String == "pr-link", let u = o["prUrl"] as? String, !u.isEmpty,
           !(rec.prs ?? []).contains(u) {
            rec.prs = (rec.prs ?? []) + [u]
        }
        return
    }
    if !has(raw, bTypeUser) || has(raw, bToolResult) { return }
    if nz(rec.first) != nil {  // later prompts: only look for "make a plan …"
        if nz(rec.workAt) == nil && has(raw, bPlan), let o = parseJSON(raw) {
            let c = (o["message"] as? [String: Any])?["content"]
            if o["type"] as? String == "user", !truthy(o["isMeta"]), let s = c as? String, planAskRx.test(pre(s, 2000)) {
                rec.workAt = nz(o["timestamp"] as? String) ?? nowLocal()
                rec.workHow = "plan"
            }
        }
        return
    }
    guard let o = parseJSON(raw) else { return }
    if o["type"] as? String != "user" || truthy(o["isMeta"]) || truthy(o["isSidechain"]) || truthy(o["isCompactSummary"]) {
        return
    }
    var content: Any? = (o["message"] as? [String: Any])?["content"]
    if let blocks = content as? [Any] {
        var texts: [String] = []
        for case let blk as [String: Any] in blocks where blk["type"] as? String == "text" {
            guard let v = blk["text"] else { texts.append(""); continue }
            guard let s = v as? String else { return }  // Python: join() raises on non-str
            texts.append(s)
        }
        content = texts.joined(separator: "\n")
    }
    guard let c = content as? String, !pyStrip(c).isEmpty else { return }
    if rec.startedAt == nil { rec.startedAt = nz(o["timestamp"] as? String) ?? "" }
    rec.cwd = nz(o["cwd"] as? String) ?? rec.cwd
    rec.branch = nz(o["gitBranch"] as? String) ?? rec.branch
    let text = pyStrip(c)
    if !noisePrefixes.contains(where: { text.hasPrefix($0) }) {
        rec.first = pre(text, 800)
        if nz(rec.workAt) == nil && planAskRx.test(pre(text, 2000)) {
            rec.workAt = nz(o["timestamp"] as? String) ?? nowLocal()
            rec.workHow = "plan"
        }
    }
}

/// Reads complete lines from `offset` to EOF in chunks; returns the new offset (stops before a partial last line).
private func readNewLines(path: String, offset: Int, rec: inout FileRec) -> Int {
    guard let fh = FileHandle(forReadingAtPath: path) else { return offset }
    defer { try? fh.close() }
    do { try fh.seek(toOffset: UInt64(offset)) } catch { return offset }
    var pos = offset
    var buf: [UInt8] = []
    var searchFrom = 0
    while true {
        guard let chunk = try? fh.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
        chunk.withUnsafeBytes { buf.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        var start = 0
        buf.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            while searchFrom < p.count, let nl = memchr(base + searchFrom, 0x0A, p.count - searchFrom) {
                let end = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(nl)) + 1
                let line = Bytes(rebasing: p[start..<end])
                if nz(rec.workAt) == nil && has(line, bToolUse) { workSignal(line, &rec) }
                if line.count < maxParsedLine { parseLine(line, &rec) }
                pos += end - start
                start = end
                searchFrom = end
            }
            searchFrom = p.count
        }
        if start > 0 { buf.removeSubrange(0..<start); searchFrom -= start }
    }
    return pos
}

/// Directory entries in readdir order (the order Python's glob returns them), hidden names left out like glob's `*`.
private func listDir(_ path: String) -> [String] {
    guard let d = opendir(path) else { return [] }
    defer { closedir(d) }
    var out: [String] = []
    while let e = readdir(d) {
        let n = Int(e.pointee.d_namlen)
        let name = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix(n), as: UTF8.self) }
        if !name.hasPrefix(".") { out.append(name) }
    }
    return out
}

/// Every transcript file: <chatProjects>/*/*.jsonl
private func transcriptPaths() -> [String] {
    var out: [String] = []
    for d in listDir(chatProjects) {
        let dp = chatProjects + "/" + d
        for f in listDir(dp) where f.hasSuffix(".jsonl") { out.append(dp + "/" + f) }
    }
    return out
}

/// Keys of the top-level "files" object in file order (Python dicts keep insertion order, and ties in
/// startedAt — forked chats share their parent's — are broken by that order).
private func filesKeyOrder(_ data: Data) -> [String] {
    let b = [UInt8](data)
    var i = 0
    func ws() { while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 } }
    func skipString() { // at '"'
        i += 1
        while i < b.count && b[i] != 0x22 { i += b[i] == 0x5C ? 2 : 1 }
        i += 1
    }
    func string() -> String? {
        guard i < b.count, b[i] == 0x22 else { return nil }
        let s = i
        skipString()
        guard i <= b.count else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(b[s..<i]), options: [.fragmentsAllowed])) as? String
    }
    func skipValue() {
        ws()
        guard i < b.count else { return }
        if b[i] == 0x22 { skipString(); return }
        if b[i] == 0x7B || b[i] == 0x5B {
            var depth = 0
            while i < b.count {
                let c = b[i]
                if c == 0x22 { skipString(); continue }
                if c == 0x7B || c == 0x5B { depth += 1 } else if c == 0x7D || c == 0x5D { depth -= 1 }
                i += 1
                if depth == 0 { return }
            }
            return
        }
        while i < b.count, !(b[i] == 0x2C || b[i] == 0x7D || b[i] == 0x5D) { i += 1 }
    }
    func object(_ onKey: (String) -> Bool) {  // onKey returns true when it consumed the value itself
        ws()
        guard i < b.count, b[i] == 0x7B else { return }
        i += 1
        while i < b.count {
            ws()
            if i < b.count && b[i] == 0x7D { i += 1; return }
            guard let k = string() else { return }
            ws()
            guard i < b.count, b[i] == 0x3A else { return }
            i += 1
            if !onKey(k) { skipValue() }
            ws()
            if i < b.count && b[i] == 0x2C { i += 1 }
        }
    }
    var keys: [String] = []
    object { k in
        guard k == "files" else { return false }
        object { fk in keys.append(fk); return false }
        return true
    }
    return keys
}

/// Writes the index with "files" in insertion order (JSONEncoder can't keep dictionary order).
private func writeIndex(order: [String], files: [String: FileRec], to url: URL) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var out = Data("{\n \"version\": \(indexVersion),\n \"files\": {".utf8)
    var n = 0
    for p in order {
        guard let r = files[p], let k = try? enc.encode(p), let v = try? enc.encode(r) else { continue }
        out.append(Data((n == 0 ? "\n  " : ",\n  ").utf8)); out.append(k); out.append(Data(": ".utf8)); out.append(v)
        n += 1
    }
    out.append(Data((n == 0 ? "}\n}\n" : "\n }\n}\n").utf8))
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? out.write(to: url, options: .atomic)
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? enc.encode(value) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
}

// MARK: - AIChats

final class AIChats: @unchecked Sendable {
    private let indexURL: URL
    private let stateURL: URL
    private let lock = NSLock()       // guards index and state (held briefly)
    private let scanLock = NSLock()   // one scan at a time
    private var files: [String: FileRec] = [:]   // ai-chats-index.json "files", by transcript path
    private var order: [String] = []             // … and their insertion order
    private var state: ChatState

    init(dataDir: URL) {
        indexURL = dataDir.appendingPathComponent("ai-chats-index.json")
        stateURL = dataDir.appendingPathComponent("ai-chats-state.json")
        for (old, new) in [("claude-index.json", indexURL), ("claude-state.json", stateURL)] {  // names used by older versions
            let o = dataDir.appendingPathComponent(old)
            if !FileManager.default.fileExists(atPath: new.path) && FileManager.default.fileExists(atPath: o.path) {
                try? FileManager.default.copyItem(at: o, to: new)
            }
        }
        if let raw = try? Data(contentsOf: indexURL), let idx = try? JSONDecoder().decode(IndexFile.self, from: raw),
           idx.version == indexVersion {  // older format → re-read chats
            let f = idx.files ?? [:]
            var seenKeys = Set<String>()
            let o = filesKeyOrder(raw).filter { f[$0] != nil && seenKeys.insert($0).inserted }
            files = f
            order = o + f.keys.filter { !seenKeys.contains($0) }.sorted()
        }
        state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(ChatState.self, from: $0) } ?? ChatState()
    }

    var status: ChatStatus {
        var isDir: ObjCBool = false
        let available = FileManager.default.fileExists(atPath: chatProjects, isDirectory: &isDir) && isDir.boolValue
        lock.lock(); defer { lock.unlock() }
        return ChatStatus(available: available, lastCheck: state.lastCheck, lastAdded: state.lastAdded ?? [],
                          skipped: state.skipped ?? [])
    }

    /// Slow part: reads only new transcript bytes and updates the index (writes ai-chats-index.json).
    func scan(since: String) {
        scanLock.lock(); defer { scanLock.unlock() }
        let sinceTs = isoTimestamp(since)
        lock.lock(); var files = self.files, order = self.order; lock.unlock()
        for path in transcriptPaths() {
            var st = stat()
            guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let size = Int(st.st_size)
            let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            let old = files[path]
            if old == nil && mtime < sinceTs { continue }
            if let o = old, o.size == size { continue }
            var rec = (old.map { ($0.offset ?? 0) <= size } ?? false) ? old! : FileRec()
            let name = (path as NSString).lastPathComponent
            rec.sid = String(name.dropLast(6))
            let pos = readNewLines(path: path, offset: rec.offset ?? 0, rec: &rec)
            rec.offset = pos
            rec.size = size
            if old == nil { order.append(path) }
            files[path] = rec
        }
        lock.lock()
        self.files = files
        self.order = order
        lock.unlock()
        writeIndex(order: order, files: files, to: indexURL)
    }

    /// Fast part (main thread, after scan): adds new items and updates existing ones in `data`.
    func apply(to data: inout DaybookData, since: String) -> ChatSyncResult {
        lock.lock(); let files = self.files, order = self.order; var state = self.state; lock.unlock()

        var counts: [String: Int] = [:]
        for r in files.values {
            if r.anyTitle.lowercased().hasPrefix("btw:") { continue }  // side chats repeat their parent chat's PRs
            for u in Set(r.prs ?? []) { counts[u, default: 0] += 1 }
        }
        let commonPRs = Set(counts.filter { $0.value >= 3 }.keys)  // PRs linked from many chats (shared base/release PRs)
        let chats = order.compactMap { files[$0] }.enumerated()  // stable sort by startedAt, ties in index order
            .filter { nz($0.element.sid) != nil && ($0.element.startedAt ?? "") >= since }
            .sorted { ($0.element.startedAt ?? "", $0.offset) < ($1.element.startedAt ?? "", $1.offset) }
            .map { $0.element }

        var added: [String] = [], updated = 0, skipped: [String] = []
        let desk = desktopSessions()
        var byChat: [String: (Int, Int)] = [:]
        for (ti, t) in data.tasks.enumerated() {
            for (li, l) in t.links.enumerated() where ChatLink.isChat(l.type) { byChat[l.ref] = (ti, li) }
        }
        let listId = data.lists.contains { $0.id == "work" } ? "work" : ""
        var keys = Set(byChat.values.compactMap { data.tasks[$0.0].links[$0.1].meta["key"]?.string })

        for rec in chats {
            let sid = rec.sid ?? ""
            var title = chatTitle(rec)
            if let (ti, li) = byChat[sid] {
                var t = data.tasks[ti], l = t.links[li]
                if let kind = nz(l.meta["kind"]?.string), let key = nz(l.meta["key"]?.string) {
                    title = itemTitle(rec, kind, key, commonPRs)
                }
                if l.meta["kind"]?.string == "pr" && !truthy(l.meta["estimateSet"]) {  // once; your own estimate is kept
                    l.meta["estimateSet"] = .bool(true)
                    if t.estimate == 0 { t.estimate = prReviewMinutes }
                    t.updatedAt = nowLocal()
                    updated += 1
                }
                if setDesktop(&l, desk) {
                    t.updatedAt = nowLocal()
                    updated += 1
                }
                if applyStatusRule(&t, &l, rec) { updated += 1 }
                if case .string(let oldAuto)? = l.meta["autoTitle"], !oldAuto.isEmpty, oldAuto != title {
                    // chat got its proper title later
                    if t.title == oldAuto { t.title = title }
                    l.title = chatTitle(rec)
                    l.meta["autoTitle"] = .string(title)
                    t.updatedAt = nowLocal()
                    updated += 1
                }
                t.links[li] = l
                data.tasks[ti] = t
                continue
            }
            if state.seen[sid] != nil { continue }  // already added once (maybe deleted since) → don't re-add
            guard let c = classify(rec) else {
                // not about a PR / task / issue → skip (re-checked later, e.g. once the chat gets its title)
                if nz(rec.customTitle) != nil || nz(rec.aiTitle) != nil || nz(rec.first) != nil { skipped.append(title) }
                continue
            }
            if keys.contains(c.key) {  // another chat about the same PR / ticket already has an item
                state.seen[sid] = nowLocal()
                continue
            }
            keys.insert(c.key)
            title = itemTitle(rec, c.kind, c.key, commonPRs)
            var link = chatLink(rec, c.kind, c.key, c.label, commonPRs)
            link.id = hexId()
            let started = c.kind == "pr" || nz(rec.workAt) != nil
            link.meta["statusRule"] = .number(2)
            link.meta["autoStarted"] = .bool(started)
            link.meta["estimateSet"] = .bool(c.kind == "pr")
            _ = setDesktop(&link, desk)
            var t = DayTask()
            t.id = hexId(); t.title = title; t.notes = ""; t.date = Day.localDay(ofTimestamp: rec.startedAt ?? "")
            t.time = ""; t.listId = listId; t.priority = 0; t.estimate = c.kind == "pr" ? prReviewMinutes : 0
            t.tags = []; t.subtasks = []; t.`repeat` = ""
            t.status = started ? "in_progress" : "todo"; t.done = false; t.doneAt = nil
            t.createdAt = nowLocal(); t.updatedAt = nowLocal()
            t.order = Int64(Date().timeIntervalSince1970 * 1000) + Int64(data.tasks.count)
            t.links = [link]
            data.tasks.append(t)
            state.seen[sid] = nowLocal()
            added.append(title)
        }

        state.lastCheck = nowLocal()
        state.skipped = Array(skipped.reversed().prefix(30))
        if !added.isEmpty { state.lastAdded = Array((added + (state.lastAdded ?? [])).prefix(10)) }
        lock.lock(); self.state = state; lock.unlock()
        writeJSON(state, to: stateURL)
        return ChatSyncResult(created: added.count, updated: updated, skipped: skipped.count, added: added)
    }
}
