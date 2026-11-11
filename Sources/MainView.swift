// Daybook — main window: sidebar, content, quick add, inspector, toasts.

import SwiftUI
import AppKit

struct MainView: View {
    @ObservedObject var app = AppModel.shared

    private var inspectorShown: Binding<Bool> {
        Binding(get: { app.inspecting != nil && app.task(app.inspecting) != nil },
                set: { if !$0 { app.inspecting = nil } })
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 228, max: 300)
        } detail: {
            ContentHost()
                .inspector(isPresented: inspectorShown) {
                    DetailView()
                        .inspectorColumnWidth(min: 320, ideal: 370, max: 520)
                }
        }
        .searchable(text: $app.search, placement: .toolbar, prompt: "Search tasks")
        .hideToolbarTitle()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { app.command("new") } label: { Label("New Task", systemImage: "plus") }
                    .help("New task (N)")
                Button { app.sheet = .aiChats } label: {
                    Label("AI chats", systemImage: app.data.aiChats.enabled ? "sparkles" : "sparkle")
                }
                .help("AI chats → Board")
                Button {
                    if app.inspecting != nil { app.inspecting = nil } else if let s = app.selected ?? app.visibleOrder().first { app.open(s) }
                } label: { Label("Details", systemImage: "sidebar.right") }
                .help("Show or hide task details (↩)")
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
        .overlay { if let e = app.loadError { LoadErrorView(message: e) } }
        .sheet(item: $app.sheet) { s in SheetHost(sheet: s) }
        .onChange(of: app.focusSearch) { _, _ in
            guard let w = NSApp.keyWindow, let tb = w.toolbar else { return }
            if let f = tb.items.compactMap({ ($0 as? NSSearchToolbarItem)?.searchField }).first { w.makeFirstResponder(f) }
        }
        .onChange(of: app.search) { _, _ in app.selected = nil }
        .onAppear { app.start() }
    }
}

extension View {
    @ViewBuilder func hideToolbarTitle() -> some View {
        if #available(macOS 15.0, *) { self.toolbar(removing: .title) } else { self }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var app = AppModel.shared

    private var selection: Binding<Nav?> {
        Binding(get: { app.search.isEmpty ? app.nav : nil }, set: { if let n = $0 { app.go(n) } })
    }

    var body: some View {
        List(selection: selection) {
            Section {
                navRow(.today, "Today", "sun.max.fill", .orange, zone: .date(app.today), badge: app.overdueCount)
                navRow(.week, "This Week", "calendar", .red)
                navRow(.board, "Board", "rectangle.split.3x1.fill", .indigo)
                navRow(.inbox, "Inbox", "tray.fill", .blue, zone: .inbox)
                navRow(.upcoming, "Upcoming", "calendar.badge.clock", .teal, zone: .date(Day.add(app.today, 1)))
                navRow(.completed, "Completed", "checkmark.circle.fill", .green)
            }
            Section {
                ForEach(app.data.lists) { l in ListRow(list: l).tag(Nav.list(l.id)) }
                    .onMove { app.moveLists(from: $0, to: $1) }
            } header: {
                HStack {
                    Text("Lists")
                    Spacer()
                    Button { newList() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("New list")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarFooter() }
    }

    private func navRow(_ n: Nav, _ title: String, _ icon: String, _ tint: Color, zone: Zone? = nil, badge: Int = 0) -> some View {
        let c = app.count(n)
        return HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
            Text(title)
            Spacer(minLength: 4)
            if badge > 0 {
                Text("\(badge)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.red))
                    .help("Overdue")
            }
            if c > 0 { Text("\(c)").foregroundStyle(.secondary).font(.system(size: 12).monospacedDigit()) }
        }
        .tag(n)
        .dropArea(zone, sortable: false, radius: 6)
    }

    private func newList() {
        let a = NSAlert()
        a.messageText = "New list"
        a.informativeText = "e.g. Work, Personal, Side project"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Create"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn { app.addList(f.stringValue) }
    }
}

struct ListRow: View {
    @ObservedObject var app = AppModel.shared
    let list: TaskList

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: list.color)).frame(width: 10, height: 10).frame(width: 18)
            Text(list.name).lineLimit(1)
            Spacer(minLength: 4)
            let c = app.count(.list(list.id))
            if c > 0 { Text("\(c)").foregroundStyle(.secondary).font(.system(size: 12).monospacedDigit()) }
        }
        .dropArea(.list(list.id), sortable: false, radius: 6)
        .contextMenu {
            Button("Rename…") { rename() }
            Menu("Colour") {
                ForEach(AppModel.listColors, id: \.self) { c in
                    Button { app.setListColor(list.id, c) } label: {
                        Label { Text(colorName(c)) } icon: { Image(systemName: list.color == c ? "checkmark.circle.fill" : "circle.fill") }
                    }
                }
            }
            Divider()
            Button("Delete List…", role: .destructive) { delete() }
        }
    }

    private func colorName(_ c: String) -> String {
        ["#5b5bf6": "Indigo", "#16a34a": "Green", "#e8930c": "Orange", "#e5484d": "Red", "#0ea5e9": "Sky",
         "#a855f7": "Purple", "#db2777": "Pink", "#64748b": "Slate", "#0d9488": "Teal"][c] ?? c
    }

    private func rename() {
        let a = NSAlert()
        a.messageText = "Rename list"
        let f = NSTextField(string: list.name)
        f.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = f
        a.addButton(withTitle: "Rename"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn { app.renameList(list.id, f.stringValue) }
    }

    private func delete() {
        let n = app.data.tasks.filter { $0.listId == list.id }.count
        if n > 0 {
            let a = NSAlert()
            a.messageText = "Delete list “\(list.name)”?"
            a.informativeText = "Its \(n) task\(n == 1 ? " is" : "s are") kept, just without a list."
            a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
            a.buttons.first?.hasDestructiveAction = true
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        app.deleteList(list.id)
    }
}

struct SidebarFooter: View {
    @ObservedObject var app = AppModel.shared

    var body: some View {
        HStack(spacing: 6) {
            Group {
                switch app.saveState {
                case .saved: Label("Saved locally", systemImage: "checkmark.icloud.fill").foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                case .saving: Label("Saving…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                case .error(let e): Label("Not saved", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).help(e)
                }
            }
            .font(.system(size: 11))
            .symbolRenderingMode(.hierarchical)
            .onTapGesture { app.revealData() }
            .help("Stored only on this Mac: \(app.store.file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) (click to show)")
            Spacer()
            Menu {
                Picker("Appearance", selection: Binding(get: { app.data.theme }, set: { app.setTheme($0) })) {
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
                .pickerStyle(.inline)
            } label: { Image(systemName: "circle.lefthalf.filled") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Appearance")
            Button { app.sheet = .aiChats } label: {
                Image(systemName: "sparkle").foregroundStyle(app.data.aiChats.enabled ? Color.orange : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("AI chats → Board\(app.data.aiChats.enabled ? " (on)" : "")")
            Button { app.sheet = .shortcuts } label: { Image(systemName: "keyboard") }
                .buttonStyle(.borderless).help("Keyboard shortcuts (?)")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

// MARK: - Content

struct ContentHost: View {
    @ObservedObject var app = AppModel.shared

    var body: some View {
        VStack(spacing: 0) {
            if !app.search.trimmed.isEmpty {
                SectionsView(sections: app.searchSections(), header: AnyView(SearchHeader()))
            } else {
                switch app.nav {
                case .week: WeekView()
                case .board: BoardView()
                case .today: SectionsView(sections: app.sections(), header: AnyView(TodayHeader()))
                default: SectionsView(sections: app.sections(), header: AnyView(PlainHeader()))
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(app.nav.title)
    }
}

/// Big input on top of every view: natural language with a live preview of what it understood.
struct QuickAddBar: View {
    @ObservedObject var app = AppModel.shared
    @StateObject private var box = TextBox()
    @FocusState private var focused: Bool
    var placeholder = "Add a task…"

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(focused ? Color.accentColor : Color.secondary.opacity(0.6))
                TextField(placeholder, text: $box.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit {
                        if app.quickAdd(box.text) != nil { box.text = "" }
                    }
                    .onExitCommand { box.text = ""; focused = false }
                if focused && box.text.isEmpty {
                    Text("try “fri 2pm #work !high 30m”").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(focused ? 0.03 : 0.045)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: focused ? 1.5 : 1))
            if !box.text.trimmed.isEmpty { preview.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .animation(.snappy(duration: 0.2), value: box.text.trimmed.isEmpty)
        .onChange(of: app.focusQuickAdd) { _, _ in focused = true }
    }

    private var preview: some View {
        let p = QuickAdd.parse(box.text, lists: app.data.lists)
        let d = app.quickDefaults()
        let date = p.date ?? d.date
        let lid = p.listId ?? d.listId
        return FlowRow(spacing: 5) {
            if date.isEmpty { Chip(icon: "tray", text: "Inbox") }
            else { Chip(icon: "calendar", text: Day.label(date, long: true), color: p.date != nil ? .accentColor : .secondary, filled: p.date != nil) }
            if !p.time.isEmpty { Chip(icon: "clock", text: fmtTime(p.time), color: .accentColor, filled: true) }
            if let l = app.list(lid) { Chip(text: l.name, color: p.listId != nil ? .accentColor : .secondary, filled: p.listId != nil, dot: Color(hex: l.color)) }
            if let pr = p.priority { Chip(icon: "flag.fill", text: priorityNames[pr], color: .priority(pr), filled: true) }
            if p.estimate > 0 { Chip(icon: "timer", text: fmtMinutes(p.estimate), color: .accentColor, filled: true) }
            if let r = Repeat(rawValue: p.repeat), r != .never { Chip(icon: "repeat", text: r.label, color: .accentColor, filled: true) }
            ForEach(p.tags, id: \.self) { Chip(text: "#" + $0, color: .accentColor, filled: true) }
            Text("↩ to add").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 2).padding(.top, 2)
        }
        .padding(.leading, 4)
    }
}

// MARK: - Toast

struct ToastView: View {
    @ObservedObject var app = AppModel.shared

    var body: some View {
        if let t = app.toast {
            HStack(spacing: 12) {
                Text(t.text).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if t.undo {
                    Button("Undo") { app.toast = nil; app.undo() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(t.id)
        }
    }
}

struct LoadErrorView: View {
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36)).foregroundStyle(.orange)
            Text("Daybook couldn’t read its data").font(.title3.bold())
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            Button("Show Data Folder") { AppModel.shared.revealData() }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
