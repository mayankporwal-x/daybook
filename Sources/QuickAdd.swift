// Daybook — natural-language quick add: "Review PR tomorrow 3pm #work !high 30m every weekday".

import Foundation

struct QuickParse: Equatable {
    var title = ""
    var date: String? = nil       // nil = not given in the text
    var time = ""
    var listId: String? = nil
    var priority: Int? = nil
    var estimate = 0
    var tags: [String] = []
    var `repeat` = ""
}

enum QuickAdd {
    private static let dowIndex = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
    private static let dowRx = "mon(?:day)?|tue(?:s|sday)?|wed(?:s|nesday)?|thu(?:r|rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?"
    private static let monRx = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"
    private static func monthIndex(_ m: String) -> Int {
        ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: String(m.lowercased().prefix(3))) ?? 0
    }

    static func slug(_ s: String) -> String {
        s.lowercased().trimmed.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
    }

    static func nextWeekday(_ idx: Int, includeToday: Bool) -> String {
        let td = Day.today
        var diff = (idx - Day.weekday(td) + 7) % 7
        if diff == 0 && !includeToday { diff = 7 }
        return Day.add(td, diff)
    }

    private static func monthDay(_ mi: Int, _ day: Int) -> String? {
        let cal = Day.cal
        let y = cal.component(.year, from: Date())
        guard let d = cal.date(from: DateComponents(year: y, month: mi + 1, day: day)),
              cal.component(.month, from: d) == mi + 1 else { return nil }
        var s = Day.iso(d)
        if s < Day.today, let n = cal.date(from: DateComponents(year: y + 1, month: mi + 1, day: day)) { s = Day.iso(n) }
        return s
    }

    static func parse(_ raw: String, lists: [TaskList]) -> QuickParse {
        var s = " " + raw + " "
        var r = QuickParse()

        /// Finds the first match of `pattern`; if `fn` accepts it (returns true) the match is cut out of the text.
        func take(_ pattern: String, caseless: Bool = true, _ fn: ([String]) -> Bool) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: caseless ? [.caseInsensitive] : []) else { return }
            let ns = s as NSString
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return }
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let rg = m.range(at: i); return rg.location == NSNotFound ? "" : ns.substring(with: rg)
            }
            if fn(groups) { s = ns.replacingCharacters(in: m.range, with: " ") }
        }
        func setDate(_ v: String?) -> Bool {
            guard r.date == nil, let v else { return false }
            r.date = v; return true
        }

        take(#"\severy\s+(day|weekday|week|month|\#(dowRx))(?=\s)"#) { m in
            let w = m[1].lowercased()
            switch w {
            case "day": r.repeat = "daily"
            case "weekday": r.repeat = "weekdays"
            case "week": r.repeat = "weekly"
            case "month": r.repeat = "monthly"
            default: r.repeat = "weekly"; r.date = nextWeekday(dowIndex[String(w.prefix(3))] ?? 1, includeToday: true)
            }
            return true
        }
        take(#"\s!(high|hi|h|1|medium|med|m|2|low|lo|l|3)(?=\s)"#) { m in
            let v = m[1].lowercased()
            r.priority = ["high", "hi", "h", "1"].contains(v) ? 3 : ["medium", "med", "m", "2"].contains(v) ? 2 : 1
            return true
        }
        take(#"\s(?:at\s+)?(\d{1,2})(?::([0-5]\d))?\s?(am|pm)(?=\s)"#) { m in
            guard var h = Int(m[1]), h >= 1, h <= 12 else { return false }
            h = h % 12 + (m[3].lowercased() == "pm" ? 12 : 0)
            r.time = String(format: "%02d:%@", h, m[2].isEmpty ? "00" : m[2])
            return true
        }
        if r.time.isEmpty {
            take(#"\s(?:at\s+)?([01]?\d|2[0-3]):([0-5]\d)(?=\s)"#) { m in
                r.time = String(format: "%02d:%@", Int(m[1]) ?? 0, m[2]); return true
            }
        }
        take(#"\s(\d{1,2})h\s?(\d{1,2})m(?:in)?(?=\s)"#) { m in r.estimate = (Int(m[1]) ?? 0) * 60 + (Int(m[2]) ?? 0); return true }
        if r.estimate == 0 { take(#"\s(\d+(?:\.\d+)?)(?:h|hr|hrs)(?=\s)"#) { m in r.estimate = Int(((Double(m[1]) ?? 0) * 60).rounded()); return true } }
        if r.estimate == 0 { take(#"\s(\d+)(?:m|min|mins)(?=\s)"#) { m in r.estimate = Int(m[1]) ?? 0; return true } }

        // #list or #tag (several allowed)
        for _ in 0..<10 {
            var found = false
            take(#"\s#([\p{L}\p{N}_\-]+)(?=\s)"#, caseless: false) { m in
                found = true
                let key = slug(m[1])
                let list = lists.first { slug($0.name) == key } ?? (key.count >= 2 ? lists.first { slug($0.name).hasPrefix(key) } : nil)
                if let list, r.listId == nil { r.listId = list.id } else { r.tags.append(m[1]) }
                return true
            }
            if !found { break }
        }

        let td = Day.today
        if r.date == nil { take(#"\s(today|tod|tonight)(?=\s)"#) { _ in setDate(td) } }
        if r.date == nil { take(#"\s(tomorrow|tmrw|tmr)(?=\s)"#) { _ in setDate(Day.add(td, 1)) } }
        if r.date == nil { take(#"\snext\s+week(?=\s)"#) { _ in setDate(Day.add(Day.monday(td), 7)) } }
        if r.date == nil { take(#"\s(?:this\s+)?weekend(?=\s)"#) { _ in setDate(nextWeekday(6, includeToday: true)) } }
        if r.date == nil {
            take(#"\sin\s+(\d+)\s*(d|days?|w|wks?|weeks?)(?=\s)"#) { m in
                setDate(Day.add(td, (Int(m[1]) ?? 0) * (m[2].lowercased().hasPrefix("w") ? 7 : 1)))
            }
        }
        if r.date == nil {
            take(#"\s(?:on\s+|by\s+)?(next\s+)?(\#(dowRx))(?=\s)"#) { m in
                let idx = dowIndex[String(m[2].lowercased().prefix(3))] ?? 1
                if !m[1].isEmpty { return setDate(Day.add(Day.monday(td), 7 + (idx + 6) % 7)) }
                return setDate(nextWeekday(idx, includeToday: false))
            }
        }
        if r.date == nil {
            take(#"\s(?:on\s+|by\s+)?(\#(monRx))\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?=\s)"#) { m in setDate(monthDay(monthIndex(m[1]), Int(m[2]) ?? 1)) }
        }
        if r.date == nil {
            take(#"\s(?:on\s+|by\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+(\#(monRx))(?=\s)"#) { m in setDate(monthDay(monthIndex(m[2]), Int(m[1]) ?? 1)) }
        }
        if r.date == nil { take(#"\s(?:on\s+|by\s+)?(\d{4}-\d{2}-\d{2})(?=\s)"#, caseless: false) { m in setDate(m[1]) } }

        let t = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
        r.title = t.isEmpty ? raw.trimmed : t
        return r
    }
}
