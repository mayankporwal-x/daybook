// Daybook — sheets: AI chats → Board, keyboard shortcuts, ⌘K command palette.

import SwiftUI
import AppKit

struct SheetHost: View {
    let sheet: SheetKind
    var body: some View {
        switch sheet {
        case .aiChats: AIChatsSheet()
        case .shortcuts: ShortcutsSheet()
        case .palette: PaletteSheet()
        }
    }
}

// MARK: - AI chats

struct AIChatsSheet: View {
    @ObservedObject var app = AppModel.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let c = app.data.aiChats, s = app.chatStatus
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(.orange)
                    .frame(width: 44, height: 44).background(RoundedRectangle(cornerRadius: 11).fill(Color.orange.opacity(0.13)))
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI chats → Board").font(.title3.bold())
                    Text("New AI coding chats about a **PR**, a **task** or an **issue** become items on your Board for the day they started. Other chats (stand-ups, questions, personal things) are skipped. Daybook only reads the chat files saved on this Mac. Nothing leaves your computer.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: Binding(get: { c.enabled }, set: { app.setAIChatsEnabled($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add work chats to the Board").font(.system(size: 13, weight: .medium))
                            Text(!s.available ? "No AI chats found on this Mac."
                                 : c.enabled ? "Watching for new chats (checks every minute)\(c.since.isEmpty ? "" : ", from \(Day.label(Day.localDay(ofTimestamp: c.since), long: true)) onward")."
                                 : "Off")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(!s.available)

                    if c.enabled {
                        HStack(spacing: 10) {
                            Button { app.syncChats(manual: true) } label: {
                                if app.syncing { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") } }
                                else { Label("Check now", systemImage: "arrow.clockwise") }
                            }
                            .disabled(app.syncing)
                            Text("Last checked \(ago(s.lastCheck))").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    if !app.lastSyncMsg.isEmpty {
                        Text(app.lastSyncMsg).font(.system(size: 12)).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.green.opacity(0.08)))
                    }
                    if c.enabled && !s.lastAdded.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recently added").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(Array(s.lastAdded.prefix(5).enumerated()), id: \.offset) { _, x in
                                Label(x, systemImage: "plus.circle").font(.system(size: 12)).lineLimit(1)
                            }
                        }
                    }
                    if c.enabled && !s.skipped.isEmpty {
                        DisclosureGroup("Skipped \(s.skipped.count) chat\(s.skipped.count == 1 ? "" : "s") (not about a PR, task or issue)") {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(s.skipped.prefix(15).enumerated()), id: \.offset) { _, x in
                                    Text("• " + x).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                        }
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }

            Text("A chat counts as work when it mentions a PR or ticket (like `ABC-123`), links a GitHub PR or Linear issue, or says a task or bug was assigned. Several chats about the same PR or ticket give one item, titled like **[PR] ABC-123 · #4521 · …**. PR reviews start **In progress** with a 30m estimate; tasks and bugs stay **To do** until the chat makes a plan or starts changing code. Each chat is added once; delete its item and it won’t come back.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func ago(_ ts: String?) -> String {
        guard let ts, let d = DateFormatter.localStamp.date(from: ts) else { return "never" }
        let m = Date().timeIntervalSince(d) / 60
        if m < 1 { return "just now" }
        if m < 60 { return "\(Int(m))m ago" }
        if m < 1440 { return "\(Int(m / 60))h ago" }
        return Day.label(String(ts.prefix(10)))
    }
}

extension DateFormatter {
    static let localStamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f
    }()
}

// MARK: - Keyboard shortcuts

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let groups: [(String, [(String, String)])] = [
        ("Anywhere", [("N", "New task (quick add)"), ("/  or  ⌘F", "Search"), ("⌘K", "Command palette"), ("1 – 6", "Today · Week · Inbox · Upcoming · Completed · Board"),
                      ("[  ]", "Previous / next week"), ("⌘Z", "Undo"), ("?", "This list"), ("Esc", "Close / clear")]),
        ("Selected task", [("J / K  or  ↓ ↑", "Move selection"), ("↩  or  E", "Open details / edit title"), ("X  or  Space", "Complete"),
                           ("T · M · W · I", "Today · Tomorrow · Next week · No date"), ("S", "Next status"), ("P", "Cycle priority"),
                           ("D  or  ⌫", "Delete"), ("⌘D", "Duplicate"), ("⌘O", "Open its AI chat")]),
        ("Quick add", [("tomorrow, fri, next week, nov 20", "Date"), ("3pm, 9:30", "Time"), ("#work", "List (other #words become tags)"),
                       ("!high  !med  !low", "Priority"), ("30m  1h  1h30m", "Estimate"), ("every day / weekday / week / mon", "Repeat")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard shortcuts").font(.title3.bold())
            HStack(alignment: .top, spacing: 28) {
                ForEach(groups, id: \.0) { g in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(g.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(g.1, id: \.0) { k in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(k.0).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                                Text(k.1).font(.system(size: 12.5))
                            }
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
    }
}

// MARK: - ⌘K command palette

final class PaletteModel: ObservableObject {
    @Published var query = ""
    @Published var index = 0
}

struct PaletteItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    var subtitle = ""
    var tint: Color = .secondary
    let run: () -> Void
}

struct PaletteSheet: View {
    @ObservedObject var app = AppModel.shared
    @StateObject private var m = PaletteModel()
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var items: [PaletteItem] {
        let q = m.query.lowercased().trimmed
        var cmds: [PaletteItem] = [
            PaletteItem(id: "c-today", icon: "sun.max.fill", title: "Go to Today", tint: .orange) { app.go(.today) },
            PaletteItem(id: "c-week", icon: "calendar", title: "Go to This Week", tint: .red) { app.go(.week) },
            PaletteItem(id: "c-board", icon: "rectangle.split.3x1.fill", title: "Go to Board", tint: .indigo) { app.go(.board) },
            PaletteItem(id: "c-inbox", icon: "tray.fill", title: "Go to Inbox", tint: .blue) { app.go(.inbox) },
            PaletteItem(id: "c-up", icon: "calendar.badge.clock", title: "Go to Upcoming", tint: .teal) { app.go(.upcoming) },
            PaletteItem(id: "c-done", icon: "checkmark.circle.fill", title: "Go to Completed", tint: .green) { app.go(.completed) },
            PaletteItem(id: "c-new", icon: "plus", title: "New task") { app.command("new") },
            PaletteItem(id: "c-aichats", icon: "sparkles", title: "AI chats → Board…", tint: .orange) { app.sheet = .aiChats },
            PaletteItem(id: "c-sync", icon: "arrow.clockwise", title: "Check AI chats now") { app.syncChats(manual: true) },
            PaletteItem(id: "c-overdue", icon: "sun.max", title: "Move overdue tasks to today") { app.moveOverdueToToday() },
            PaletteItem(id: "c-theme", icon: "circle.lefthalf.filled", title: "Toggle light / dark appearance") {
                app.setTheme(NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "light" : "dark")
            },
            PaletteItem(id: "c-data", icon: "folder", title: "Show data file in Finder") { app.revealData() },
            PaletteItem(id: "c-keys", icon: "keyboard", title: "Keyboard shortcuts") { app.sheet = .shortcuts },
        ]
        cmds += app.data.lists.map { l in
            PaletteItem(id: "l-\(l.id)", icon: "circle.fill", title: "Go to \(l.name)", tint: Color(hex: l.color)) { app.go(.list(l.id)) }
        }
        if q.isEmpty { return cmds }
        let c = cmds.filter { $0.title.lowercased().contains(q) }
        let tasks = app.data.tasks
            .filter { $0.title.lowercased().contains(q) || $0.notes.lowercased().contains(q) }
            .sorted { a, b in a.done != b.done ? !a.done : (a.updatedAt ?? "") > (b.updatedAt ?? "") }
            .prefix(12)
            .map { t in
                PaletteItem(id: "t-\(t.id)", icon: t.done ? "checkmark.circle.fill" : "circle", title: t.title,
                            subtitle: [t.date.isEmpty ? "Inbox" : Day.label(t.date), app.list(t.listId)?.name ?? "", t.st == .todo ? "" : t.st.label]
                                .filter { !$0.isEmpty }.joined(separator: " · "),
                            tint: t.done ? .green : .priority(t.priority)) {
                    if let ws = Day.date(t.date).map({ Day.monday(Day.iso($0)) }), app.nav == .week { app.weekStart = ws }
                    else if !t.done && t.date.isEmpty { app.go(.inbox) }
                    else if t.done { app.go(.completed) }
                    else if t.date <= app.today { app.go(.today) }
                    else { app.go(.upcoming) }
                    app.open(t.id)
                }
            }
        return c + tasks
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a task or run a command…", text: $m.query)
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { run(list) }
                    .onKeyPress(.downArrow) { m.index = min(m.index + 1, max(0, list.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { m.index = max(m.index - 1, 0); return .handled }
                    .onChange(of: m.query) { _, _ in m.index = 0 }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, it in
                            HStack(spacing: 10) {
                                Image(systemName: it.icon).foregroundStyle(it.tint).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(it.title).font(.system(size: 13)).lineLimit(1)
                                    if !it.subtitle.isEmpty { Text(it.subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(i == m.index ? Color.accentColor.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { m.index = i; run(list) }
                            .id(it.id)
                        }
                        if list.isEmpty { Text("No matches").foregroundStyle(.secondary).padding(20) }
                    }
                    .padding(6)
                }
                .onChange(of: m.index) { _, i in if list.indices.contains(i) { proxy.scrollTo(list[i].id) } }
            }
            .frame(height: 340)
        }
        .frame(width: 560)
        .onAppear { focused = true }
    }

    private func run(_ list: [PaletteItem]) {
        guard list.indices.contains(m.index) else { return }
        let it = list[m.index]
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { it.run() }
    }
}
