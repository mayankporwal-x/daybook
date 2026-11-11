// Daybook — engine: state, task operations, undo, saving, outside-edit merge, AI chats sync.

import SwiftUI
import AppKit

enum Nav: Hashable, Codable {
    case today, week, board, inbox, upcoming, completed, list(String)

    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "This Week"
        case .board: return "Board"
        case .inbox: return "Inbox"
        case .upcoming: return "Upcoming"
        case .completed: return "Completed"
        case .list: return "List"
        }
    }
}

/// Where a dragged task can land.
enum Zone: Hashable {
    case date(String), inbox, list(String), status(TaskStatus)
}

struct TaskSection: Identifiable {
    let id: String
    var title: String
    var tasks: [DayTask]
    var zone: Zone? = nil
    var danger = false
    var collapsed: Bool? = nil        // nil = not collapsible
    var toggleKey: String? = nil      // UserDefaults key that stores the collapsed state
    var hideDate = false
    var empty = ""
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var undo = false
}

enum SheetKind: String, Identifiable {
    case aiChats, shortcuts, palette
    var id: String { rawValue }
}

enum SaveState: Equatable { case saved, saving, error(String) }

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store = Store()
    let chats = AIChats(dataDir: Store.dir)

    @Published var data = DaybookData()
    @Published var nav: Nav = .today { didSet { saveNav() } }
    @Published var search = ""
    @Published var selected: String?
    @Published var inspecting: String?
    @Published var weekStart = Day.monday(Day.today)
    @Published var today = Day.today
    @Published var toast: Toast?
    @Published var sheet: SheetKind?
    @Published var saveState: SaveState = .saved
    @Published var completing: Set<String> = []
    @Published var flashId: String?
    @Published var loadError: String?
    @Published var syncing = false
    @Published var lastSyncMsg = ""
    @Published var chatStatus = ChatStatus(available: false, lastCheck: nil, lastAdded: [], skipped: [])

    // Focus requests (views watch these counters)
    @Published var focusQuickAdd = 0
    @Published var focusSearch = 0
    @Published var focusTitle = 0

    // Small view preferences
    @Published var showDoneToday = UserDefaults.standard.bool(forKey: "showDoneToday") { didSet { UserDefaults.standard.set(showDoneToday, forKey: "showDoneToday") } }
    @Published var showInboxPick = UserDefaults.standard.object(forKey: "showInboxPick") as? Bool ?? true { didSet { UserDefaults.standard.set(showInboxPick, forKey: "showInboxPick") } }
    @Published var weekInbox = UserDefaults.standard.bool(forKey: "weekInbox") { didSet { UserDefaults.standard.set(weekInbox, forKey: "weekInbox") } }
    @Published var boardList = UserDefaults.standard.string(forKey: "boardList") ?? "" { didSet { UserDefaults.standard.set(boardList, forKey: "boardList") } }

    private var undoStack: [DaybookData] = []
    private var saveTimer: Timer?
    private var dirty = false
    private var knownIds: Set<String> = []
    private var deletedLocal: Set<String> = []
    private var started = false
    private var toastTimer: Timer?

    // MARK: start

    func start() {
        guard !started else { return }
        started = true
        if let raw = UserDefaults.standard.data(forKey: "nav"), let n = try? JSONDecoder().decode(Nav.self, from: raw) { nav = n }
        reload()
        if case .list(let id) = nav, list(id) == nil { nav = .today }
        if let from = store.migratedFrom {
            showToast("Imported your tasks from \(from.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.pollDisk() }
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.checkDayChange() }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.syncChats() }
        }
        chatStatus = chats.status
        syncChats()
        applyTestHook()
    }

    /// DAYBOOK_TEST="nav=week;open=<task id>;sheet=aiChats" — opens a view/task/sheet at launch (for screenshots).
    private func applyTestHook() {
        guard let spec = ProcessInfo.processInfo.environment["DAYBOOK_TEST"] else { return }
        for part in spec.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "nav": go(["week": .week, "board": .board, "inbox": .inbox, "upcoming": .upcoming, "completed": .completed][kv[1]] ?? (kv[1].hasPrefix("list:") ? .list(String(kv[1].dropFirst(5))) : .today))
            case "open": open(kv[1])
            case "sheet": sheet = SheetKind(rawValue: kv[1])
            case "search": search = kv[1]
            case "theme": data.theme = kv[1]; applyTheme()
            default: break
            }
        }
    }

    private func reload() {
        do {
            data = try store.load()
            knownIds = Set(data.tasks.map(\.id))
            loadError = nil
        } catch {
            loadError = "Couldn’t read \(store.file.path): \(error.localizedDescription). Nothing was changed; fix or restore the file from backups/."
        }
        applyTheme()
        updateBadge()
    }

    private func saveNav() {
        if let raw = try? JSONEncoder().encode(nav) { UserDefaults.standard.set(raw, forKey: "nav") }
    }

    func checkDayChange() {
        let t = Day.today
        if t != today {
            today = t
            weekStart = Day.monday(t)
            updateBadge()
        }
    }

    // MARK: saving

    /// Call after every change. Saves shortly after (changes are batched while typing).
    func commit() {
        dirty = true
        saveState = .saving
        updateBadge()
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            MainActor.assumeIsolated { AppModel.shared.saveNow() }
        }
    }

    func saveNow() {
        saveTimer?.invalidate()
        guard dirty, loadError == nil else { return }
        if store.changedOutside { mergeFromDisk() }
        do {
            try store.save(data)
            dirty = false
            deletedLocal.removeAll()
            knownIds = Set(data.tasks.map(\.id))
            saveState = .saved
        } catch {
            saveState = .error(error.localizedDescription)
            saveTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
                MainActor.assumeIsolated { AppModel.shared.saveNow() }
            }
        }
    }

    /// An AI assistant (or an editor) changed tasks.json. With nothing unsaved here, just reload.
    func pollDisk() {
        guard !dirty, loadError == nil || store.modifiedOnDisk != nil, store.changedOutside else { return }
        reload()
        undoStack.removeAll()
        if let id = inspecting, task(id) == nil { inspecting = nil }
        showToast("Updated from an outside edit")
    }

    /// Both sides changed: keep their changes and ours (newest updatedAt wins per task).
    private func mergeFromDisk() {
        guard let disk = try? store.load() else { return }
        var map = Dictionary(disk.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var order = disk.tasks.map(\.id)
        for t in data.tasks {
            if let d = map[t.id] {
                if (t.updatedAt ?? "") > (d.updatedAt ?? "") { map[t.id] = t }
            } else if !knownIds.contains(t.id) {
                map[t.id] = t; order.append(t.id)
            }
        }
        for id in deletedLocal { map[id] = nil }
        var merged = data
        merged.tasks = order.compactMap { map[$0] }
        data = merged
        undoStack.removeAll()
    }

    // MARK: undo

    func snapshot() {
        undoStack.append(data)
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    func undo() {
        guard let prev = undoStack.popLast() else { showToast("Nothing to undo"); return }
        withAnimation(.snappy) { data = prev }
        deletedLocal.subtract(data.tasks.map(\.id))
        if let id = inspecting, task(id) == nil { inspecting = nil }
        applyTheme()
        commit()
        showToast("Undone")
    }

    // MARK: lookups

    func task(_ id: String?) -> DayTask? { id.flatMap { id in data.tasks.first { $0.id == id } } }
    func list(_ id: String) -> TaskList? { data.lists.first { $0.id == id } }
    var openTasks: [DayTask] { data.tasks.filter { !$0.done } }

    static func byOrder(_ a: DayTask, _ b: DayTask) -> Bool {
        a.order != b.order ? a.order < b.order : a.createdAt < b.createdAt
    }
    static func byDoneAt(_ a: DayTask, _ b: DayTask) -> Bool { (a.doneAt ?? "") > (b.doneAt ?? "") }

    /// Change one task. `undoable` takes a snapshot first (not done for each keystroke).
    func update(_ id: String, undoable: Bool = false, _ f: (inout DayTask) -> Void) {
        guard let i = data.tasks.firstIndex(where: { $0.id == id }) else { return }
        if undoable { snapshot() }
        f(&data.tasks[i])
        data.tasks[i].touch()
        commit()
    }

    func binding<T>(_ id: String, _ kp: WritableKeyPath<DayTask, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.task(id)?[keyPath: kp] ?? fallback },
                set: { v in self.update(id) { $0[keyPath: kp] = v } })
    }

    // MARK: task operations

    @discardableResult
    func add(_ t: DayTask) -> DayTask {
        snapshot()
        var t = t
        t.normalize()
        withAnimation(.snappy) { data.tasks.append(t) }
        commit()
        flash(t.id)
        return t
    }

    func quickDefaults() -> (date: String, listId: String) {
        switch nav {
        case .today, .completed, .board: return (today, "")
        case .week:
            let we = Day.add(weekStart, 6)
            return (today >= weekStart && today <= we ? today : weekStart, "")
        case .inbox: return ("", "")
        case .upcoming: return (Day.add(today, 1), "")
        case .list(let id): return ("", id)
        }
    }

    /// Adds a task from natural text. `date`/`listId` override the current view's defaults.
    @discardableResult
    func quickAdd(_ raw: String, date: String? = nil, listId: String? = nil, status: TaskStatus? = nil) -> DayTask? {
        guard !raw.trimmed.isEmpty else { return nil }
        let p = QuickAdd.parse(raw, lists: data.lists)
        let d = quickDefaults()
        var t = DayTask()
        t.title = p.title
        t.date = p.date ?? date ?? d.date
        t.listId = p.listId ?? listId ?? d.listId
        if case .board = nav, boardList != "", p.listId == nil, listId == nil { t.listId = boardList }
        t.priority = p.priority ?? 0
        t.estimate = p.estimate
        t.time = p.time
        t.tags = p.tags
        t.repeat = p.repeat
        if !t.repeat.isEmpty && t.date.isEmpty { t.date = today }
        if let status { t.status = status.rawValue }
        let added = add(t)
        showToast(t.date.isEmpty ? "Added to Inbox" : "Added to \(Day.label(t.date))", undo: true)
        return added
    }

    static func nextRepeatDate(_ date: String, _ rep: Repeat, today: String) -> String {
        func step(_ d: String) -> String {
            switch rep {
            case .weekly: return Day.add(d, 7)
            case .weekdays:
                var n = Day.add(d, 1)
                while [0, 6].contains(Day.weekday(n)) { n = Day.add(n, 1) }
                return n
            case .monthly:
                guard let x = Day.date(d) else { return Day.add(d, 30) }
                return Day.iso(Day.cal.date(byAdding: .month, value: 1, to: x) ?? x)
            default: return Day.add(d, 1)
            }
        }
        var n = step(date.isEmpty ? today : date)
        var guardN = 0
        while n < today && guardN < 1000 { n = step(n); guardN += 1 }
        return n
    }

    func toggle(_ id: String) {
        guard let t = task(id) else { return }
        snapshot()
        if t.done {
            update(id) { $0.setStatus(.todo) }
            return
        }
        var msg = "Completed"
        update(id) { $0.doneAt = nil; $0.setStatus(.done) }
        if t.repeatRule != .never {
            var n = t
            n.id = uid(); n.status = "todo"; n.done = false; n.doneAt = nil
            n.date = Self.nextRepeatDate(t.date, t.repeatRule, today: today)
            n.createdAt = nowLocal(); n.updatedAt = nowLocal(); n.order = Int64(Date().timeIntervalSince1970 * 1000)
            n.subtasks = t.subtasks.map { Subtask(text: $0.text) }
            n.links = []
            update(id) { $0.repeat = "" }
            data.tasks.append(n)
            commit()
            msg = "Completed · next one \(Day.label(n.date).lowercased() == "tomorrow" ? "tomorrow" : "on " + Day.label(n.date))"
        }
        showToast(msg, undo: true)
    }

    /// Ticks the box first, then lets the row leave the list.
    func complete(_ id: String) {
        guard let t = task(id) else { return }
        if t.done { withAnimation(.snappy) { toggle(id) }; return }
        NSSound(named: "Pop")?.play()
        withAnimation(.easeOut(duration: 0.15)) { _ = completing.insert(id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.snappy) {
                self.completing.remove(id)
                self.toggle(id)
            }
        }
    }

    func delete(_ id: String) {
        guard let t = task(id) else { return }
        let order = visibleOrder()
        snapshot()
        withAnimation(.snappy) { data.tasks.removeAll { $0.id == id } }
        deletedLocal.insert(id)
        if inspecting == id { inspecting = nil }
        if selected == id {
            let i = order.firstIndex(of: id) ?? 0
            selected = order.indices.contains(i + 1) ? order[i + 1] : (i > 0 ? order[i - 1] : nil)
        }
        commit()
        showToast("Deleted “\(t.title.count > 40 ? String(t.title.prefix(38)) + "…" : t.title)”", undo: true)
    }

    func schedule(_ id: String, _ date: String) {
        guard task(id) != nil else { return }
        withAnimation(.snappy) {
            update(id, undoable: true) { $0.date = date; $0.order = Int64(Date().timeIntervalSince1970 * 1000) }
        }
        showToast(date.isEmpty ? "Moved to Inbox" : "Moved to \(Day.label(date))", undo: true)
    }

    func setStatus(_ id: String, _ s: TaskStatus) {
        withAnimation(.snappy) { update(id, undoable: true) { $0.setStatus(s) } }
    }

    func cycleStatus(_ id: String) {
        guard let t = task(id) else { return }
        let order: [TaskStatus] = [.todo, .inProgress, .review, .blocked]
        let next = order[((order.firstIndex(of: t.st) ?? -1) + 1) % order.count]
        setStatus(id, next)
        showToast("Status: \(next.label)")
    }

    func cyclePriority(_ id: String) {
        guard let t = task(id) else { return }
        update(id, undoable: true) { $0.priority = (t.priority + 1) % 4 }
        showToast("Priority: \(priorityNames[(t.priority + 1) % 4])")
    }

    func duplicate(_ id: String) {
        guard var n = task(id) else { return }
        n.id = uid(); n.status = "todo"; n.done = false; n.doneAt = nil; n.links = []
        n.createdAt = nowLocal(); n.order = Int64(Date().timeIntervalSince1970 * 1000)
        n.subtasks = n.subtasks.map { Subtask(text: $0.text) }
        add(n)
        open(n.id)
        showToast("Duplicated", undo: true)
    }

    func moveOverdueToToday() {
        let ids = openTasks.filter { !$0.date.isEmpty && $0.date < today }.map(\.id)
        guard !ids.isEmpty else { return }
        snapshot()
        withAnimation(.snappy) {
            for i in data.tasks.indices where ids.contains(data.tasks[i].id) {
                data.tasks[i].date = today; data.tasks[i].touch()
            }
        }
        commit()
        showToast("Moved \(ids.count) task\(ids.count == 1 ? "" : "s") to today", undo: true)
    }

    /// Drag and drop: put task `id` into `zone`, before task `before` (or at the end).
    func drop(_ id: String, on zone: Zone, before: String? = nil, sortable: Bool = true) {
        guard let t = task(id), id != before else { return }
        snapshot()
        let oldDate = t.date
        var siblings: [DayTask] = []
        withAnimation(.snappy) {
            update(id) { t in
                switch zone {
                case .date(let d): t.date = d
                case .inbox: t.date = ""
                case .list(let l): t.listId = l
                case .status(let s): t.setStatus(s)
                }
            }
            if sortable {
                siblings = tasks(in: zone).filter { $0.id != id && !$0.done }
                var ids = siblings.map(\.id)
                if let before, let i = ids.firstIndex(of: before) { ids.insert(id, at: i) } else { ids.append(id) }
                for (n, x) in ids.enumerated() {
                    if let i = data.tasks.firstIndex(where: { $0.id == x }) { data.tasks[i].order = Int64(n + 1) }
                }
            } else if case .date = zone, task(id)?.date != oldDate {
                update(id) { $0.order = Int64(Date().timeIntervalSince1970 * 1000) }
            }
        }
        commit()
        switch zone {
        case .list(let l): showToast("Moved to \(list(l)?.name ?? "list")", undo: true)
        case .status(let s): if t.st != s { showToast("Moved to \(s.label)", undo: true) }
        default:
            let nd = task(id)?.date ?? ""
            if nd != oldDate { showToast(nd.isEmpty ? "Moved to Inbox" : "Moved to \(Day.label(nd))", undo: true) }
        }
    }

    /// Tasks currently shown in a drop zone, in display order.
    func tasks(in zone: Zone) -> [DayTask] {
        switch zone {
        case .date(let d): return data.tasks.filter { $0.date == d }.sorted(by: Self.byOrder)
        case .inbox: return openTasks.filter { $0.date.isEmpty }.sorted(by: Self.byOrder)
        case .list(let l): return openTasks.filter { $0.listId == l }.sorted(by: Self.byOrder)
        case .status(let s): return boardPool.filter { $0.st == s }.sorted(by: Self.byOrder)
        }
    }

    // MARK: lists

    static let listColors = ["#5b5bf6", "#16a34a", "#e8930c", "#e5484d", "#0ea5e9", "#a855f7", "#db2777", "#64748b", "#0d9488"]

    func addList(_ name: String) {
        let name = name.trimmed
        guard !name.isEmpty else { return }
        let base = QuickAdd.slug(name).replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
        var id = base.isEmpty ? "list" : base, i = 2
        while list(id) != nil { id = "\(base.isEmpty ? "list" : base)-\(i)"; i += 1 }
        snapshot()
        data.lists.append(TaskList(id: id, name: name, color: Self.listColors[data.lists.count % Self.listColors.count]))
        commit()
        nav = .list(id)
    }

    func renameList(_ id: String, _ name: String) {
        guard let i = data.lists.firstIndex(where: { $0.id == id }), !name.trimmed.isEmpty else { return }
        snapshot(); data.lists[i].name = name.trimmed; commit()
    }

    func setListColor(_ id: String, _ color: String) {
        guard let i = data.lists.firstIndex(where: { $0.id == id }) else { return }
        snapshot(); data.lists[i].color = color; commit()
    }

    func deleteList(_ id: String) {
        guard let l = list(id) else { return }
        snapshot()
        data.lists.removeAll { $0.id == id }
        for i in data.tasks.indices where data.tasks[i].listId == id { data.tasks[i].listId = ""; data.tasks[i].touch() }
        if nav == .list(id) { nav = .today }
        if boardList == id { boardList = "" }
        commit()
        showToast("Deleted list “\(l.name)”", undo: true)
    }

    func moveLists(from: IndexSet, to: Int) {
        snapshot(); data.lists.move(fromOffsets: from, toOffset: to); commit()
    }

    // MARK: week goals and notes

    func week(_ ws: String) -> WeekData { data.weeks[ws] ?? WeekData() }

    func editWeek(_ ws: String, undoable: Bool = false, _ f: (inout WeekData) -> Void) {
        if undoable { snapshot() }
        var w = week(ws); f(&w); data.weeks[ws] = w
        commit()
    }

    // MARK: navigation & selection

    func go(_ n: Nav) {
        search = ""
        if n == .week && nav != .week { weekStart = Day.monday(today) }
        nav = n
        selected = nil
    }

    func open(_ id: String) {
        selected = id
        inspecting = id
    }

    func closeInspector() { inspecting = nil }

    /// Task ids in the order they appear on screen (for J/K).
    func visibleOrder() -> [String] {
        if !search.trimmed.isEmpty { return searchSections().flatMap { $0.tasks.map(\.id) } }
        switch nav {
        case .week:
            var cols = (0..<7).map { Day.add(weekStart, $0) }.map { d -> [DayTask] in
                let ts = data.tasks.filter { $0.date == d }
                return ts.filter { !$0.done }.sorted(by: Self.byOrder) + ts.filter(\.done).sorted(by: Self.byDoneAt)
            }
            if weekInbox { cols.insert(tasks(in: .inbox), at: 0) }
            return cols.flatMap { $0.map(\.id) }
        case .board:
            return TaskStatus.allCases.flatMap { s in boardColumn(s).map(\.id) }
        default:
            return sections().filter { $0.collapsed != true }.flatMap { $0.tasks.map(\.id) }
        }
    }

    func moveSelection(_ dir: Int) {
        let ids = visibleOrder()
        guard !ids.isEmpty else { return }
        var i = selected.flatMap { ids.firstIndex(of: $0) } ?? (dir > 0 ? -1 : ids.count)
        i = min(ids.count - 1, max(0, i + dir))
        selected = ids[i]
        if inspecting != nil { inspecting = ids[i] }
    }

    func flash(_ id: String) {
        flashId = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if self.flashId == id { self.flashId = nil } }
    }

    // MARK: view content

    var boardPool: [DayTask] {
        let weekAgo = Day.add(today, -7)
        return data.tasks.filter { (boardList.isEmpty || $0.listId == boardList) && (!$0.done || $0.doneDay >= weekAgo) }
    }

    func boardColumn(_ s: TaskStatus) -> [DayTask] {
        boardPool.filter { $0.st == s }.sorted(by: s == .done ? Self.byDoneAt : Self.byOrder)
    }

    func sections() -> [TaskSection] {
        let td = today
        let open = openTasks
        switch nav {
        case .today:
            let overdue = open.filter { !$0.date.isEmpty && $0.date < td }.sorted { $0.date != $1.date ? $0.date < $1.date : Self.byOrder($0, $1) }
            let todays = open.filter { $0.date == td }.sorted(by: Self.byOrder)
            let doneToday = data.tasks.filter { $0.done && $0.doneDay == td }.sorted(by: Self.byDoneAt)
            let inbox = open.filter { $0.date.isEmpty }.sorted(by: Self.byOrder)
            var s: [TaskSection] = []
            if !overdue.isEmpty { s.append(TaskSection(id: "overdue", title: "Overdue", tasks: overdue, danger: true)) }
            let allDone = !doneToday.isEmpty && todays.isEmpty
            s.append(TaskSection(id: "today", title: "Today", tasks: todays, zone: .date(td), hideDate: true,
                                 empty: allDone ? "🎉 All done for today. Nice work!" : "Nothing planned yet. Add a task above or pull one in from your Inbox."))
            if !inbox.isEmpty {
                s.append(TaskSection(id: "pick", title: "Pick from Inbox", tasks: showInboxPick ? Array(inbox.prefix(8)) : inbox,
                                     zone: .inbox, collapsed: !showInboxPick, toggleKey: "showInboxPick"))
            }
            if !doneToday.isEmpty {
                s.append(TaskSection(id: "doneToday", title: "Completed today", tasks: doneToday, collapsed: !showDoneToday, toggleKey: "showDoneToday"))
            }
            return s
        case .inbox:
            return [TaskSection(id: "inbox", title: "No date", tasks: open.filter { $0.date.isEmpty }.sorted(by: Self.byOrder), zone: .inbox)]
        case .upcoming:
            return byDate(open.filter { !$0.date.isEmpty && $0.date > td }, fillDays: 7, fillFrom: 1)
        case .list(let id):
            return byDate(open.filter { $0.listId == id }, showNoDate: true)
        case .completed:
            let done = data.tasks.filter(\.done).sorted(by: Self.byDoneAt).prefix(400)
            var groups: [(String, [DayTask])] = []
            for t in done {
                let d = t.doneDay.isEmpty ? "Earlier" : t.doneDay
                if let i = groups.firstIndex(where: { $0.0 == d }) { groups[i].1.append(t) } else { groups.append((d, [t])) }
            }
            return groups.map { TaskSection(id: "c-\($0.0)", title: $0.0 == "Earlier" ? "Earlier" : Day.label($0.0, long: true), tasks: $0.1) }
        case .week, .board:
            return []
        }
    }

    private func byDate(_ tasks: [DayTask], fillDays: Int = 0, fillFrom: Int = 0, showNoDate: Bool = false) -> [TaskSection] {
        let td = today
        var out: [TaskSection] = []
        let overdue = tasks.filter { !$0.date.isEmpty && $0.date < td }.sorted { $0.date != $1.date ? $0.date < $1.date : Self.byOrder($0, $1) }
        if !overdue.isEmpty { out.append(TaskSection(id: "overdue", title: "Overdue", tasks: overdue, danger: true)) }
        var dates = Set(tasks.filter { $0.date >= td }.map(\.date))
        for i in 0..<fillDays { dates.insert(Day.add(td, i + fillFrom)) }
        for d in dates.sorted() {
            out.append(TaskSection(id: "d-\(d)", title: Day.label(d, long: true), tasks: tasks.filter { $0.date == d }.sorted(by: Self.byOrder),
                                   zone: .date(d), hideDate: true, empty: fillDays > 0 ? "Nothing yet" : ""))
        }
        let nodate = tasks.filter { $0.date.isEmpty }.sorted(by: Self.byOrder)
        if !nodate.isEmpty || showNoDate && !tasks.isEmpty {
            out.append(TaskSection(id: "nodate", title: "No date", tasks: nodate, zone: .inbox, empty: "Nothing here"))
        }
        return out
    }

    func searchSections() -> [TaskSection] {
        let q = search.lowercased().trimmed
        guard !q.isEmpty else { return [] }
        let res = data.tasks.filter { t in
            [t.title, t.notes, t.tags.joined(separator: " "), list(t.listId)?.name ?? "", t.subtasks.map(\.text).joined(separator: " "),
             t.chat?.title ?? ""].joined(separator: " ").lowercased().contains(q)
        }
        let open = res.filter { !$0.done }.sorted { ($0.date.isEmpty ? "9999" : $0.date) < ($1.date.isEmpty ? "9999" : $1.date) }
        let done = Array(res.filter(\.done).sorted(by: Self.byDoneAt).prefix(50))
        var s = [TaskSection(id: "s-open", title: "Open", tasks: open, empty: "No open tasks match")]
        if !done.isEmpty { s.append(TaskSection(id: "s-done", title: "Completed", tasks: done)) }
        return s
    }

    func toggleSection(_ key: String) {
        withAnimation(.snappy) {
            if key == "showDoneToday" { showDoneToday.toggle() } else if key == "showInboxPick" { showInboxPick.toggle() }
        }
    }

    // MARK: counts for the sidebar & Dock

    var overdueCount: Int { openTasks.filter { !$0.date.isEmpty && $0.date < today }.count }

    func count(_ n: Nav) -> Int {
        let open = openTasks
        switch n {
        case .today: return open.filter { $0.date == today }.count
        case .week: let we = Day.add(Day.monday(today), 6); return open.filter { $0.date >= Day.monday(today) && $0.date <= we }.count
        case .board: return open.filter { [.inProgress, .review, .blocked].contains($0.st) }.count
        case .inbox: return open.filter { $0.date.isEmpty }.count
        case .upcoming: return open.filter { $0.date > today }.count
        case .completed: return 0
        case .list(let id): return open.filter { $0.listId == id }.count
        }
    }

    func updateBadge() {
        let n = openTasks.filter { !$0.date.isEmpty && $0.date <= today }.count
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    // MARK: theme

    func setTheme(_ th: String) {
        data.theme = th
        applyTheme()
        commit()
    }

    func applyTheme() {
        switch data.theme {
        case "light": NSApp?.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp?.appearance = NSAppearance(named: .darkAqua)
        default: NSApp?.appearance = nil
        }
    }

    // MARK: toast

    func showToast(_ text: String, undo: Bool = false) {
        withAnimation(.spring(duration: 0.3)) { toast = Toast(text: text, undo: undo) }
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: undo ? 5 : 2.6, repeats: false) { _ in
            MainActor.assumeIsolated { withAnimation(.easeOut(duration: 0.25)) { AppModel.shared.toast = nil } }
        }
    }

    // MARK: AI chats → Board

    func setAIChatsEnabled(_ on: Bool) {
        data.aiChats.enabled = on
        if on && data.aiChats.since.isEmpty {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            data.aiChats.since = f.string(from: Date().addingTimeInterval(-86400))
        }
        lastSyncMsg = ""
        commit()
        if on { syncChats(manual: true) }
    }

    func syncChats(manual: Bool = false) {
        guard data.aiChats.enabled, !syncing, loadError == nil else { return }
        syncing = true
        let since = data.aiChats.since
        let chats = self.chats
        DispatchQueue.global(qos: .utility).async {
            chats.scan(since: since)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppModel.shared.finishSync(manual: manual) }
            }
        }
    }

    private func finishSync(manual: Bool) {
        defer { syncing = false; chatStatus = chats.status }
        if dirty { saveNow() }
        if store.changedOutside { reload() }
        var d = data
        let r = chats.apply(to: &d, since: d.aiChats.since)
        if r.created + r.updated > 0 {
            withAnimation(.snappy) { data = d }
            commit()
            saveNow()
        }
        if r.created > 0 {
            showToast("Added \(r.created) work chat\(r.created == 1 ? "" : "s") from AI chats")
        }
        if manual || r.created > 0 {
            lastSyncMsg = (r.created > 0 ? "Added \(r.created) work chat\(r.created == 1 ? "" : "s") to the Board" : "No new work chats")
                + (r.skipped > 0 ? " · skipped \(r.skipped) other chat\(r.skipped == 1 ? "" : "s")" : "")
        }
    }

    func openChat(_ link: ChatLink) {
        guard let s = link.desktopSession, let url = URL(string: "claude://code/continue?session=\(s)&source=daybook") else { return }
        NSWorkspace.shared.open(url)
    }

    func copy(_ text: String, _ msg: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(msg)
    }

    func revealData() { NSWorkspace.shared.activateFileViewerSelecting([store.file]) }

    // MARK: commands (menus and single-key shortcuts)

    func command(_ c: String) {
        let sel = task(selected)?.id
        switch c {
        case "new": focusQuickAdd += 1
        case "search": focusSearch += 1
        case "palette": sheet = .palette
        case "shortcuts": sheet = .shortcuts
        case "aiChats": sheet = .aiChats
        case "undo": undo()
        case "goToday": go(.today)
        case "goWeek": go(.week)
        case "goInbox": go(.inbox)
        case "goUpcoming": go(.upcoming)
        case "goCompleted": go(.completed)
        case "goBoard": go(.board)
        case "next": moveSelection(1)
        case "prev": moveSelection(-1)
        case "weekPrev": weekStart = Day.add(weekStart, -7)
        case "weekNext": weekStart = Day.add(weekStart, 7)
        case "weekThis": weekStart = Day.monday(today)
        case "close":
            if sheet != nil { sheet = nil } else if inspecting != nil { inspecting = nil } else if !search.isEmpty { search = "" } else { selected = nil }
        case "open": if let sel { open(sel) }
        case "edit": if let sel { open(sel); focusTitle += 1 }
        case "complete": if let sel { complete(sel) }
        case "today": if let sel { schedule(sel, today) }
        case "tomorrow": if let sel { schedule(sel, Day.add(today, 1)) }
        case "nextWeek": if let sel { schedule(sel, Day.add(Day.monday(today), 7)) }
        case "noDate": if let sel { schedule(sel, "") }
        case "priority": if let sel { cyclePriority(sel) }
        case "status": if let sel { cycleStatus(sel) }
        case "delete": if let sel { delete(sel) }
        case "duplicate": if let sel { duplicate(sel) }
        case "openChat": if let l = task(sel)?.chat { openChat(l) }
        case "syncChats": syncChats(manual: true)
        default: break
        }
    }
}
