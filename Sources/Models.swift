// Daybook — data model. Mirrors data/tasks.json exactly (see README › Data format), so the
// file stays readable and editable by hand or by an AI assistant. Unknown keys are kept on save.

import Foundation

// MARK: - JSON value (for chat-link metadata and keys this version doesn't know about)

enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n):
            if n == n.rounded(), abs(n) < 9e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var number: Double? { if case .number(let n) = self { return n }; return nil }
}

/// Coding key that accepts any name, used to keep unknown keys.
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func readExtras(_ decoder: Decoder, known: Set<String>) -> [String: JSONValue] {
    guard let c = try? decoder.container(keyedBy: AnyKey.self) else { return [:] }
    var out: [String: JSONValue] = [:]
    for k in c.allKeys where !known.contains(k.stringValue) {
        if let v = try? c.decode(JSONValue.self, forKey: k) { out[k.stringValue] = v }
    }
    return out
}

private func writeExtras(_ extras: [String: JSONValue], _ encoder: Encoder) throws {
    guard !extras.isEmpty else { return }
    var c = encoder.container(keyedBy: AnyKey.self)
    for (k, v) in extras { try c.encode(v, forKey: AnyKey(k)) }
}

private extension KeyedDecodingContainer {
    func str(_ k: Key, _ d: String = "") -> String { (try? decodeIfPresent(String.self, forKey: k)) ?? nil ?? d }
    func int(_ k: Key) -> Int {
        if let i = try? decodeIfPresent(Int.self, forKey: k) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: k) { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: k), let i = Int(s) { return i }
        return 0
    }
    func bool(_ k: Key) -> Bool { (try? decodeIfPresent(Bool.self, forKey: k)) ?? nil ?? false }
}

// MARK: - Statuses

enum TaskStatus: String, CaseIterable, Identifiable {
    case todo, inProgress = "in_progress", review, blocked, done
    var id: String { rawValue }
    var label: String {
        switch self {
        case .todo: return "To do"
        case .inProgress: return "In progress"
        case .review: return "In review"
        case .blocked: return "Blocked"
        case .done: return "Done"
        }
    }
    var icon: String {
        switch self {
        case .todo: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .review: return "eye.circle"
        case .blocked: return "exclamationmark.octagon"
        case .done: return "checkmark.circle.fill"
        }
    }
}

enum Repeat: String, CaseIterable, Identifiable {
    case never = "", daily, weekdays, weekly, monthly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .never: return "Never"
        case .daily: return "Every day"
        case .weekdays: return "Every weekday"
        case .weekly: return "Every week"
        case .monthly: return "Every month"
        }
    }
}

let priorityNames = ["None", "Low", "Medium", "High"]

// MARK: - Task

struct Subtask: Codable, Hashable, Identifiable {
    var id: String = uid()
    var text: String = ""
    var done: Bool = false
}

/// A link from a task to the AI coding chat it was created from.
struct ChatLink: Codable, Hashable, Identifiable {
    var id: String = uid()
    var type: String = ChatLink.kind
    var ref: String = ""          // chat (session) id
    var title: String = ""
    var meta: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey { case id, type, ref, title, meta }
    static let kind = "ai-chat"
    static func isChat(_ type: String) -> Bool { type == kind || type == "claude" }   // "claude" = files from older versions

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.str(.id, uid()); type = ChatLink.isChat(c.str(.type, ChatLink.kind)) ? ChatLink.kind : c.str(.type); ref = c.str(.ref); title = c.str(.title)
        meta = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .meta)) ?? nil ?? [:]
    }

    func m(_ k: String) -> String { meta[k]?.string ?? "" }
    var desktopSession: String? {
        let s = m("desktopSession")
        return s.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil ? s : nil
    }
    var desktopArchived: Bool { meta["desktopArchived"]?.bool ?? false }
}

struct DayTask: Codable, Hashable, Identifiable {
    var id: String = uid()
    var title: String = "Untitled"
    var notes: String = ""
    var date: String = ""          // "YYYY-MM-DD" or "" (Inbox)
    var time: String = ""          // "HH:MM" or ""
    var listId: String = ""
    var priority: Int = 0          // 0 none … 3 high
    var estimate: Int = 0          // minutes
    var tags: [String] = []
    var subtasks: [Subtask] = []
    var `repeat`: String = ""
    var done: Bool = false
    var doneAt: String? = nil
    var createdAt: String = nowLocal()
    var updatedAt: String? = nowLocal()
    var order: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var status: String = TaskStatus.todo.rawValue
    var links: [ChatLink] = []
    var extras: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case id, title, notes, date, time, listId, priority, estimate, tags, subtasks, `repeat`, done, doneAt
        case createdAt, updatedAt, order, status, links
    }
    static let known = Set(["id", "title", "notes", "date", "time", "listId", "priority", "estimate", "tags", "subtasks",
                            "repeat", "done", "doneAt", "createdAt", "updatedAt", "order", "status", "links"])

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.str(.id, uid()); title = c.str(.title, "Untitled"); notes = c.str(.notes)
        date = c.str(.date); time = c.str(.time); listId = c.str(.listId)
        priority = max(0, min(3, c.int(.priority))); estimate = max(0, c.int(.estimate))
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? nil ?? []
        subtasks = (try? c.decodeIfPresent([Subtask].self, forKey: .subtasks)) ?? nil ?? []
        `repeat` = c.str(.repeat); done = c.bool(.done)
        doneAt = (try? c.decodeIfPresent(String.self, forKey: .doneAt)) ?? nil
        createdAt = c.str(.createdAt, nowLocal())
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? nil
        if let o = try? c.decodeIfPresent(Int64.self, forKey: .order) { order = o }
        else if let o = try? c.decodeIfPresent(Double.self, forKey: .order) { order = Int64(o) }
        status = c.str(.status)
        links = ((try? c.decodeIfPresent([ChatLink].self, forKey: .links)) ?? nil ?? []).filter { ChatLink.isChat($0.type) }
        extras = readExtras(decoder, known: Self.known)
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title); try c.encode(notes, forKey: .notes)
        try c.encode(date, forKey: .date); try c.encode(time, forKey: .time); try c.encode(listId, forKey: .listId)
        try c.encode(priority, forKey: .priority); try c.encode(estimate, forKey: .estimate)
        try c.encode(tags, forKey: .tags); try c.encode(subtasks, forKey: .subtasks); try c.encode(`repeat`, forKey: .repeat)
        try c.encode(done, forKey: .done); try c.encode(doneAt, forKey: .doneAt)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(order, forKey: .order); try c.encode(status, forKey: .status); try c.encode(links, forKey: .links)
        try writeExtras(extras, encoder)
    }

    /// done ⇔ status "done" (same rule as the old web app).
    mutating func normalize() {
        if TaskStatus(rawValue: status) == nil { status = done ? "done" : "todo" }
        else if done && status != "done" { status = "done" }
        done = status == "done"
        if !done { doneAt = nil }
    }

    var st: TaskStatus { TaskStatus(rawValue: status) ?? .todo }
    var repeatRule: Repeat { Repeat(rawValue: `repeat`) ?? .never }
    var chat: ChatLink? { links.first }
    var doneDay: String { String((doneAt ?? "").prefix(10)) }

    mutating func touch() { updatedAt = nowLocal() }
    mutating func setStatus(_ s: TaskStatus) {
        status = s.rawValue
        done = s == .done
        doneAt = done ? (doneAt ?? nowLocal()) : nil
        touch()
    }
}

// MARK: - Lists, weeks, settings

struct TaskList: Codable, Hashable, Identifiable {
    var id: String
    var name: String = "List"
    var color: String = "#5b5bf6"
}

struct WeekGoal: Codable, Hashable, Identifiable {
    var id: String = uid()
    var text: String = ""
    var done: Bool = false
}

struct WeekData: Codable, Hashable {
    var goals: [WeekGoal] = []
    var notes: String = ""
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goals = (try? c.decodeIfPresent([WeekGoal].self, forKey: .goals)) ?? nil ?? []
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? nil ?? ""
    }
}

struct AIChatSettings: Codable, Hashable {
    var enabled = false
    var since = ""      // ISO timestamp; chats started before it are ignored
}

struct DaybookData: Codable, Hashable {
    var version = 1
    var lists: [TaskList] = [TaskList(id: "work", name: "Work", color: "#5b6cff"),
                             TaskList(id: "personal", name: "Personal", color: "#16a34a")]
    var tasks: [DayTask] = []
    var weeks: [String: WeekData] = [:]
    var settings: [String: JSONValue] = ["theme": .string("system")]
    var aiChats = AIChatSettings()
    var integrationsExtra: [String: JSONValue] = [:]
    var extras: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey { case version, lists, tasks, weeks, settings, integrations }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? nil ?? 1
        lists = (try? c.decodeIfPresent([TaskList].self, forKey: .lists)) ?? nil ?? []
        tasks = (try? c.decodeIfPresent([DayTask].self, forKey: .tasks)) ?? nil ?? []
        weeks = (try? c.decodeIfPresent([String: WeekData].self, forKey: .weeks)) ?? nil ?? [:]
        settings = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .settings)) ?? nil ?? [:]
        var integ = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .integrations)) ?? nil ?? [:]
        let old = integ.removeValue(forKey: "claude")          // key used by older versions
        if case .object(let o)? = integ.removeValue(forKey: "aiChats") ?? old {
            aiChats.enabled = o["enabled"]?.bool ?? false
            aiChats.since = o["since"]?.string ?? ""
        }
        integrationsExtra = integ
        extras = readExtras(decoder, known: ["version", "lists", "tasks", "weeks", "settings", "integrations"])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(lists, forKey: .lists); try c.encode(tasks, forKey: .tasks)
        try c.encode(weeks, forKey: .weeks); try c.encode(settings, forKey: .settings)
        var integ = integrationsExtra
        integ["aiChats"] = .object(["enabled": .bool(aiChats.enabled), "since": .string(aiChats.since)])
        try c.encode(integ, forKey: .integrations)
        try writeExtras(extras, encoder)
    }

    var theme: String {
        get { settings["theme"]?.string ?? "system" }
        set { settings["theme"] = .string(newValue) }
    }
}

// MARK: - Helpers: ids, local timestamps, ISO day strings

func uid() -> String {
    let a = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    return String((0..<11).map { _ in a.randomElement()! })
}

private let localStamp: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f
}()
private let isoDay: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
}()

/// Local time as "YYYY-MM-DDTHH:MM:SS" (the format used throughout tasks.json).
func nowLocal() -> String { localStamp.string(from: Date()) }

enum Day {
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; return c }
    static func iso(_ d: Date) -> String { isoDay.string(from: d) }
    static func date(_ s: String) -> Date? { s.count >= 10 ? isoDay.date(from: String(s.prefix(10))) : nil }
    static var today: String { iso(Date()) }
    static func add(_ s: String, _ n: Int) -> String {
        guard let d = date(s), let r = cal.date(byAdding: .day, value: n, to: d) else { return s }
        return iso(r)
    }
    static func monday(_ s: String) -> String {
        guard let d = date(s) else { return s }
        let wd = cal.component(.weekday, from: d)       // 1 = Sunday
        return add(s, -((wd + 5) % 7))
    }
    static func weekday(_ s: String) -> Int { date(s).map { cal.component(.weekday, from: $0) - 1 } ?? 0 } // 0 = Sun
    static func diff(_ a: String, _ b: String) -> Int {
        guard let x = date(a), let y = date(b) else { return 0 }
        return cal.dateComponents([.day], from: x, to: y).day ?? 0
    }

    /// "Today", "Tomorrow", "Yesterday", "Fri", "Mon 24 Nov" (long: "Friday 14 Nov")
    static func label(_ s: String, long: Bool = false) -> String {
        guard let d = date(s) else { return s }
        let n = diff(today, s)
        if n == 0 { return "Today" }
        if n == 1 { return "Tomorrow" }
        if n == -1 { return "Yesterday" }
        let f = DateFormatter()
        if long { f.setLocalizedDateFormatFromTemplate(n > 0 && n < 7 ? "EEEEdMMMM" : "EEEEdMMMMy") }
        else if n > 0 && n < 7 { f.setLocalizedDateFormatFromTemplate("EEE") }
        else { f.setLocalizedDateFormatFromTemplate(cal.component(.year, from: d) == cal.component(.year, from: Date()) ? "EEEdMMM" : "dMMMy") }
        return f.string(from: d)
    }
    static func range(_ a: String, _ b: String) -> String {
        guard let x = date(a), let y = date(b) else { return "" }
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("dMMM")
        return "\(f.string(from: x)) – \(f.string(from: y))"
    }
    /// Local calendar day of an ISO timestamp (UTC "…Z" or local).
    static func localDay(ofTimestamp ts: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: ts) { return iso(d) }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: ts) { return iso(d) }
        return String(ts.prefix(10)).count == 10 ? String(ts.prefix(10)) : today
    }
}

func fmtMinutes(_ m: Int) -> String {
    if m <= 0 { return "0m" }
    if m < 60 { return "\(m)m" }
    return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
}

func fmtTime(_ t: String) -> String {
    let p = t.split(separator: ":").compactMap { Int($0) }
    guard p.count == 2 else { return t }
    let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("jmm")
    var c = DateComponents(); c.hour = p[0]; c.minute = p[1]
    return Calendar.current.date(from: c).map { f.string(from: $0) } ?? t
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
