// Daybook — the views: Today / Inbox / Upcoming / Completed / Lists / Search (sections), This Week, Board.

import SwiftUI
import AppKit

// MARK: - Headers

struct ViewHeader<Trailing: View>: View {
    let title: String
    var dot: Color? = nil
    var subtitle: Text = Text("")
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    if let dot { Circle().fill(dot).frame(width: 14, height: 14) }
                    Text(title).font(.system(size: 26, weight: .bold)).lineLimit(1)
                }
                subtitle.font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

struct TodayHeader: View {
    @ObservedObject var app = AppModel.shared

    var body: some View {
        let td = app.today
        let open = app.openTasks
        let todays = open.filter { $0.date == td }
        let doneToday = app.data.tasks.filter { $0.done && $0.doneDay == td }
        let total = todays.count + doneToday.count
        let planned = todays.reduce(0) { $0 + $1.estimate }
        let ws = Day.monday(td), we = Day.add(ws, 6)
        let wk = app.data.tasks.filter { $0.date >= ws && $0.date <= we }
        let wkDone = wk.filter(\.done).count
        let h = Calendar.current.component(.hour, from: Date())
        let greet = h < 5 ? "Working late" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
        let overdue = app.overdueCount
        let date = Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
        VStack(alignment: .leading, spacing: 16) {
            ViewHeader(title: greet,
                       subtitle: overdue > 0 ? date + Text(" · ") + Text("\(overdue) overdue").foregroundColor(.red) : date) { EmptyView() }
            HStack(spacing: 10) {
                StatCard(label: "Today", value: "\(doneToday.count)", small: " / \(total) done") {
                    ProgressRing(value: total > 0 ? Double(doneToday.count) / Double(total) : 0, size: 38, line: 4.5)
                }
                StatCard(label: "Planned time left", value: fmtMinutes(planned), small: "") {
                    StatIcon(icon: "timer", color: .accentColor)
                }
                StatCard(label: "This week", value: "\(wkDone)", small: " / \(wk.count) done",
                         bar: wk.isEmpty ? 0 : Double(wkDone) / Double(wk.count)) {
                    StatIcon(icon: "calendar", color: .green)
                }
                .onTapGesture { app.go(.week) }
                .help("Open This Week")
            }
        }
    }
}

struct StatIcon: View {
    let icon: String
    let color: Color
    var body: some View {
        Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(color)
            .frame(width: 38, height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.13)))
    }
}

struct StatCard<Icon: View>: View {
    let label: String
    let value: String
    let small: String
    var bar: Double? = nil
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(spacing: 11) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                (Text(value).font(.system(size: 19, weight: .semibold).monospacedDigit())
                 + Text(small).font(.system(size: 12)).foregroundColor(.secondary))
                if let bar { ProgressBar(value: bar).padding(.top, 3) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct PlainHeader: View {
    @ObservedObject var app = AppModel.shared

    var body: some View {
        switch app.nav {
        case .inbox:
            ViewHeader(title: "Inbox", subtitle: Text("Unscheduled tasks: capture now, plan later. Drag one onto Today in the sidebar.")) { EmptyView() }
        case .upcoming:
            let n = app.openTasks.filter { $0.date > app.today }.count
            ViewHeader(title: "Upcoming", subtitle: Text("Everything scheduled after today · \(n) task\(n == 1 ? "" : "s")")) { EmptyView() }
        case .completed:
            let n = app.data.tasks.filter(\.done).count
            ViewHeader(title: "Completed", subtitle: Text("\(n) task\(n == 1 ? "" : "s") done: your logbook")) { EmptyView() }
        case .list(let id):
            if let l = app.list(id) {
                let open = app.openTasks.filter { $0.listId == id }.count
                let done = app.data.tasks.filter { $0.done && $0.listId == id }.count
                ViewHeader(title: l.name, dot: Color(hex: l.color), subtitle: Text("\(open) open · \(done) completed")) { EmptyView() }
            }
        default: EmptyView()
        }
    }
}

struct SearchHeader: View {
    @ObservedObject var app = AppModel.shared
    var body: some View {
        let n = app.searchSections().reduce(0) { $0 + $1.tasks.count }
        ViewHeader(title: "Search", subtitle: Text("\(n) result\(n == 1 ? "" : "s") for “\(app.search.trimmed)”")) {
            Button("Clear") { app.search = "" }
        }
    }
}

// MARK: - Sectioned list views

struct SectionsView: View {
    @ObservedObject var app = AppModel.shared
    let sections: [TaskSection]
    let header: AnyView

    private var placeholder: String {
        switch app.nav {
        case .today: return "Add a task for today…"
        case .inbox: return "Capture a task without a date…"
        case .upcoming: return "Add a task for tomorrow… (or type a date)"
        case .list(let id): return "Add to \(app.list(id)?.name ?? "list")…"
        default: return "Add a task…"
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    QuickAddBar(placeholder: placeholder)
                    if sections.allSatisfy({ $0.tasks.isEmpty }) && app.nav != .today && app.search.isEmpty {
                        EmptyState(nav: app.nav)
                    } else {
                        ForEach(sections) { s in SectionBlock(section: s) }
                    }
                }
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 80)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: app.selected) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.selected = nil }
    }
}

struct SectionBlock: View {
    @ObservedObject var app = AppModel.shared
    let section: TaskSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if section.collapsed != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(section.collapsed == true ? 0 : 90))
                        .foregroundStyle(.secondary)
                }
                Text(section.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(section.danger ? Color.red : Color.primary)
                Text("\(section.tasks.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.tertiary)
                Spacer()
                if section.id == "overdue" && app.nav == .today {
                    Button { app.moveOverdueToToday() } label: { Label("Move all to today", systemImage: "sun.max") }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 2)
            .contentShape(Rectangle())
            .onTapGesture { if let k = section.toggleKey { app.toggleSection(k) } }

            Divider().padding(.horizontal, 10).padding(.bottom, 2)

            if section.collapsed != true {
                VStack(spacing: 1) {
                    ForEach(section.tasks) { t in
                        TaskRow(t: t, hideDate: section.hideDate, hideList: { if case .list = app.nav { return true }; return false }(),
                                zone: section.zone)
                            .id(t.id)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
                    }
                    if section.tasks.isEmpty && !section.empty.isEmpty {
                        Text(section.empty).font(.system(size: 12.5)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.bottom, 6)
                .dropArea(section.zone)
            }
        }
    }
}

struct EmptyState: View {
    let nav: Nav
    var body: some View {
        let (icon, title, text): (String, String, String) = {
            switch nav {
            case .inbox: return ("tray", "Inbox zero", "Anything you add without a date lands here.")
            case .upcoming: return ("calendar", "Nothing upcoming", "Tasks scheduled after today show up here.")
            case .completed: return ("checkmark.circle", "Nothing completed yet", "Finished tasks show up here as your log.")
            case .list: return ("number", "No open tasks in this list", "Type a task above, or add #listname to any task.")
            default: return ("sparkle", "Nothing here", "")
            }
        }()
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }
}

// MARK: - This Week

struct WeekView: View {
    @ObservedObject var app = AppModel.shared

    var body: some View {
        let ws = app.weekStart, td = app.today
        let days = (0..<7).map { Day.add(ws, $0) }
        let we = days[6]
        let inWeek = app.data.tasks.filter { $0.date >= ws && $0.date <= we }
        let done = inWeek.filter(\.done).count
        let planned = inWeek.filter { !$0.done }.reduce(0) { $0 + $1.estimate }
        let isThis = ws == Day.monday(td)

        GeometryReader { geo in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    ViewHeader(title: isThis ? "This Week" : (ws < Day.monday(td) ? "Past Week" : "Week Ahead"),
                               subtitle: Text("\(Day.range(ws, we)) · \(done)/\(inWeek.count) done\(planned > 0 ? " · \(fmtMinutes(planned)) planned" : "")")) {
                        HStack(spacing: 8) {
                            Toggle(isOn: $app.weekInbox) { Label("Inbox", systemImage: "tray") }
                                .toggleStyle(.button).help("Show unscheduled tasks next to the week")
                            ControlGroup {
                                Button { app.command("weekPrev") } label: { Image(systemName: "chevron.left") }.help("Previous week ([)")
                                Button("This Week") { app.command("weekThis") }
                                Button { app.command("weekNext") } label: { Image(systemName: "chevron.right") }.help("Next week (])")
                            }
                            .fixedSize()
                        }
                    }
                    QuickAddBar(placeholder: "Add a task to this week… (try “fri 2pm #work”)")
                    HStack(alignment: .top, spacing: 12) {
                        GoalsPanel(ws: ws)
                        NotesPanel(ws: ws)
                    }
                    let n = app.weekInbox ? 8 : 7
                    let colW = max(132, (geo.size.width - 48 - CGFloat(n - 1) * 8) / CGFloat(n))
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(alignment: .top, spacing: 8) {
                            if app.weekInbox { InboxColumn().frame(width: colW) }
                            ForEach(days, id: \.self) { d in DayColumn(day: d).frame(width: colW) }
                        }
                        .padding(.bottom, 6)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 60)
            }
        }
    }
}

struct Panel<Content: View>: View {
    let icon: String
    let title: String
    var trailing = ""
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(trailing).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct GoalsPanel: View {
    @ObservedObject var app = AppModel.shared
    let ws: String

    var body: some View {
        let wk = app.week(ws)
        Panel(icon: "target", title: "Weekly focus", trailing: wk.goals.isEmpty ? "" : "\(wk.goals.filter(\.done).count)/\(wk.goals.count)") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(wk.goals) { g in GoalRow(ws: ws, goal: g) }
                InlineAdd(placeholder: wk.goals.isEmpty ? "What 1–3 things would make this week a win?" : "Add another goal") { text in
                    app.editWeek(ws, undoable: true) { $0.goals.append(WeekGoal(text: text.trimmed)) }
                }
                .padding(.leading, -9)
            }
        }
    }
}

struct GoalRow: View {
    @ObservedObject var app = AppModel.shared
    @StateObject private var hover = Flag()
    let ws: String
    let goal: WeekGoal

    var body: some View {
        HStack(spacing: 8) {
            CheckButton(done: goal.done, priority: 0, size: 16) {
                app.editWeek(ws, undoable: true) { w in if let i = w.goals.firstIndex(where: { $0.id == goal.id }) { w.goals[i].done.toggle() } }
            }
            TextField("Goal", text: Binding(get: { goal.text }, set: { v in
                app.editWeek(ws) { w in if let i = w.goals.firstIndex(where: { $0.id == goal.id }) { w.goals[i].text = v } }
            }))
            .textFieldStyle(.plain).font(.system(size: 13))
            .strikethrough(goal.done).foregroundStyle(goal.done ? .secondary : .primary)
            if hover.on {
                IconButton(icon: "xmark", help: "Remove goal") {
                    app.editWeek(ws, undoable: true) { $0.goals.removeAll { $0.id == goal.id } }
                }
            }
        }
        .frame(minHeight: 24)
        .onHover { hover.on = $0 }
    }
}

struct NotesPanel: View {
    @ObservedObject var app = AppModel.shared
    let ws: String

    var body: some View {
        Panel(icon: "note.text", title: "Week notes") {
            ZStack(alignment: .topLeading) {
                if app.week(ws).notes.isEmpty {
                    Text("Meetings, deadlines, reminders, reflections…").font(.system(size: 13)).foregroundStyle(.tertiary)
                        .padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: Binding(get: { app.week(ws).notes }, set: { v in app.editWeek(ws) { $0.notes = v } }))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 70, maxHeight: 160)
            }
        }
    }
}

struct DayColumn: View {
    @ObservedObject var app = AppModel.shared
    let day: String

    var body: some View {
        let ts = app.data.tasks.filter { $0.date == day }
        let open = ts.filter { !$0.done }.sorted(by: AppModel.byOrder)
        let done = ts.filter(\.done).sorted(by: AppModel.byDoneAt)
        let est = open.reduce(0) { $0 + $1.estimate }
        let isToday = day == app.today, isPast = day < app.today
        let d = Day.date(day) ?? Date()

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(isToday ? "TODAY" : d.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 10.5, weight: .bold)).foregroundStyle(isToday ? Color.accentColor : .secondary)
                    Text(d.formatted(.dateTime.day()))
                        .font(.system(size: 22, weight: isToday ? .bold : .semibold))
                        .foregroundStyle(isToday ? Color.accentColor : (isPast ? .secondary : .primary))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    if !ts.isEmpty { Text("\(done.count)/\(ts.count) done") }
                    if est > 0 { Text(fmtMinutes(est)) }
                }
                .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
            }
            if !ts.isEmpty { ProgressBar(value: Double(done.count) / Double(ts.count)) }
            VStack(spacing: 6) {
                ForEach(open + done) { t in
                    TaskRow(t: t, card: true, hideDate: true, zone: .date(day))
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .top)
            InlineAdd(placeholder: "Add task") { app.quickAdd($0, date: day) }
                .padding(.horizontal, -4)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isToday ? Color.accentColor.opacity(0.06) : Color.primary.opacity(isPast ? 0.02 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isToday ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06)))
        .opacity(isPast && !isToday ? 0.85 : 1)
        .dropArea(.date(day), radius: 12)
    }
}

struct InboxColumn: View {
    @ObservedObject var app = AppModel.shared

    var body: some View {
        let inbox = app.tasks(in: .inbox)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("UNSCHEDULED").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary)
                    Text("Inbox").font(.system(size: 22, weight: .semibold))
                }
                Spacer()
                if !inbox.isEmpty { Text("\(inbox.count)").font(.system(size: 10.5)).foregroundStyle(.secondary) }
            }
            VStack(spacing: 6) {
                ForEach(inbox) { t in TaskRow(t: t, card: true, zone: .inbox) }
                if inbox.isEmpty { Text("Drag tasks here to unschedule").font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(6) }
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .top)
            InlineAdd(placeholder: "Add to inbox") { app.quickAdd($0, date: "") }.padding(.horizontal, -4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.blue.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.blue.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .dropArea(.inbox, radius: 12)
    }
}

// MARK: - Board

struct BoardView: View {
    @ObservedObject var app = AppModel.shared

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 16) {
                ViewHeader(title: "Board", subtitle: Text("Drag cards between columns to change status · Done shows the last 7 days")) {
                    Picker("List", selection: $app.boardList) {
                        Text("All").tag("")
                        ForEach(app.data.lists) { l in Text(l.name).tag(l.id) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                QuickAddBar(placeholder: "Add a task…")
                let colW = max(200, (geo.size.width - 48 - 4 * 10) / 5)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(TaskStatus.allCases) { s in StatusColumn(status: s).frame(width: colW) }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
        }
    }
}

struct StatusColumn: View {
    @ObservedObject var app = AppModel.shared
    let status: TaskStatus

    var body: some View {
        let ts = app.boardColumn(status)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: status.icon).foregroundStyle(Color.status(status)).font(.system(size: 12, weight: .semibold))
                Text(status.label).font(.system(size: 13, weight: .semibold))
                Text("\(ts.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 2)
            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    ForEach(ts) { t in
                        TaskRow(t: t, card: true, zone: .status(status))
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                    if ts.isEmpty {
                        Text("Drop tasks here").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                    }
                    if status != .done {
                        InlineAdd(placeholder: "Add task") { app.quickAdd($0, status: status) }.padding(.horizontal, -4)
                    }
                }
                .padding(2)
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.status(status).opacity(status == .todo ? 0.035 : 0.05)))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12).fill(Color.status(status).opacity(0.7)).frame(height: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .dropArea(.status(status), radius: 12)
    }
}
