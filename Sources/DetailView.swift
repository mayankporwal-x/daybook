// Daybook — task inspector (right-hand panel): every field of the selected task.

import SwiftUI
import AppKit

struct DetailView: View {
    @ObservedObject var app = AppModel.shared

    var body: some View {
        if let id = app.inspecting, let t = app.task(id) {
            TaskDetail(t: t).id(id)
        } else {
            Text("No task selected").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct FieldRow<Content: View>: View {
    let icon: String
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(label, systemImage: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TaskDetail: View {
    @ObservedObject var app = AppModel.shared
    @StateObject private var newStep = TextBox()
    @FocusState private var titleFocused: Bool
    let t: DayTask

    private func b<T>(_ kp: WritableKeyPath<DayTask, T>, _ fallback: T) -> Binding<T> { app.binding(t.id, kp, fallback: fallback) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                titleRow
                statusPicker
                fields
                if let l = t.chat { chatSection(l) }
                checklist
                notes
                footer
            }
            .padding(18)
        }
        .onChange(of: app.focusTitle) { _, _ in titleFocused = true }
        .onAppear { if app.focusTitle > 0 { DispatchQueue.main.async { titleFocused = true } } }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let l = app.list(t.listId) {
                Circle().fill(Color(hex: l.color)).frame(width: 8, height: 8)
                Text(l.name)
            } else { Text("No list") }
            Text("·")
            Text(t.date.isEmpty ? "Inbox" : Day.label(t.date, long: true))
            Spacer()
            Menu { TaskMenu(t: t) } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            IconButton(icon: "xmark", help: "Close (Esc)") { app.closeInspector() }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
    }

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 10) {
            CheckButton(done: t.done, priority: t.priority, size: 20) { app.complete(t.id) }.padding(.top, 3)
            TextField("Title", text: Binding(get: { t.title }, set: { v in app.update(t.id) { $0.title = v.replacingOccurrences(of: "\n", with: " ") } }),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold))
                .strikethrough(t.done)
                .focused($titleFocused)
                .onSubmit { titleFocused = false }
                .onChange(of: titleFocused) { _, f in
                    if !f && t.title.trimmed.isEmpty { app.update(t.id) { $0.title = "Untitled" } }
                }
        }
    }

    private var statusPicker: some View {
        HStack(spacing: 4) {
            ForEach(TaskStatus.allCases) { s in
                let on = t.st == s
                Button { app.setStatus(t.id, s) } label: {
                    Text(s.label)
                        .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .padding(.vertical, 5).frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? (s == .todo ? Color.gray : Color.status(s)) : Color.primary.opacity(0.05)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.snappy(duration: 0.2), value: t.status)
    }

    private var fields: some View {
        let td = app.today
        return VStack(alignment: .leading, spacing: 11) {
            FieldRow(icon: "calendar", label: "Date") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if !t.date.isEmpty {
                            DatePicker("", selection: Binding(get: { Day.date(t.date) ?? Date() }, set: { v in
                                app.update(t.id, undoable: true) { $0.date = Day.iso(v); $0.order = Int64(Date().timeIntervalSince1970 * 1000) }
                            }), displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.field).fixedSize()
                        } else {
                            Text("No date").foregroundStyle(.secondary).font(.system(size: 13))
                        }
                    }
                    Seg(options: [("Today", td), ("Tomorrow", Day.add(td, 1)), ("Next week", Day.add(Day.monday(td), 7)), ("None", "")],
                        value: t.date) { v in app.update(t.id, undoable: true) { $0.date = v; $0.order = Int64(Date().timeIntervalSince1970 * 1000) } }
                }
            }
            FieldRow(icon: "clock", label: "Time") {
                HStack(spacing: 6) {
                    if t.time.isEmpty {
                        Button("Add time") { app.update(t.id, undoable: true) { $0.time = "09:00" } }.controlSize(.small)
                    } else {
                        DatePicker("", selection: Binding(get: { timeDate }, set: { v in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: v)
                            app.update(t.id) { $0.time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) }
                        }), displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.field).fixedSize()
                        Button("Clear") { app.update(t.id, undoable: true) { $0.time = "" } }.controlSize(.small).buttonStyle(.borderless)
                    }
                }
            }
            FieldRow(icon: "number", label: "List") {
                Picker("", selection: Binding(get: { t.listId }, set: { v in app.update(t.id, undoable: true) { $0.listId = v } })) {
                    Text("No list").tag("")
                    ForEach(app.data.lists) { l in Text(l.name).tag(l.id) }
                }
                .labelsHidden().fixedSize()
            }
            FieldRow(icon: "flag", label: "Priority") {
                Seg(options: (0...3).map { (priorityNames[$0], "\($0)") }, value: "\(t.priority)",
                    tint: { Color.priority(Int($0) ?? 0) }) { v in app.update(t.id, undoable: true) { $0.priority = Int(v) ?? 0 } }
            }
            FieldRow(icon: "timer", label: "Estimate") {
                HStack(spacing: 6) {
                    Seg(options: [15, 30, 60, 120].map { (fmtMinutes($0), "\($0)") }, value: "\(t.estimate)") { v in
                        app.update(t.id, undoable: true) { $0.estimate = Int(v) ?? 0 }
                    }
                    TextField("min", value: Binding(get: { t.estimate }, set: { v in app.update(t.id) { $0.estimate = max(0, v) } }), format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 52).controlSize(.small)
                }
            }
            FieldRow(icon: "repeat", label: "Repeat") {
                Picker("", selection: Binding(get: { t.repeat }, set: { v in
                    app.update(t.id, undoable: true) { $0.repeat = v; if !v.isEmpty && $0.date.isEmpty { $0.date = app.today } }
                })) {
                    ForEach(Repeat.allCases) { r in Text(r.label).tag(r.rawValue) }
                }
                .labelsHidden().fixedSize()
            }
            FieldRow(icon: "tag", label: "Tags") {
                TextField("e.g. urgent, follow-up", text: Binding(get: { t.tags.joined(separator: ", ") }, set: { v in
                    app.update(t.id) {
                        $0.tags = v.split(whereSeparator: { $0 == "," || $0 == " " })
                            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }.filter { !$0.isEmpty }
                    }
                }))
                .textFieldStyle(.roundedBorder).controlSize(.small)
            }
        }
    }

    private var timeDate: Date {
        let p = t.time.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 9, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }

    private func chatSection(_ l: ChatLink) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(icon: "sparkle", title: "From AI chat")
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "sparkle").foregroundStyle(.orange)
                        .frame(width: 26, height: 26).background(Circle().fill(Color.orange.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.title.isEmpty ? "AI chat" : l.title).font(.system(size: 12.5, weight: .medium)).lineLimit(2)
                        let sub = [l.m("about"), l.m("project"), l.m("branch"),
                                   l.m("startedAt").isEmpty ? "" : "started " + Day.label(Day.localDay(ofTimestamp: l.m("startedAt"))).lowercased()]
                            .filter { !$0.isEmpty }.joined(separator: " · ")
                        if !sub.isEmpty { Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
                HStack(spacing: 6) {
                    if l.desktopSession != nil {
                        Button { app.openChat(l) } label: {
                            Label(l.desktopArchived ? "Open chat (archived)" : "Open chat", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
                        .help(l.desktopArchived ? "This chat is archived: unarchive it in the desktop app first" : "Opens this chat in the desktop app")
                    }
                    if let r = l.meta["resume"]?.string {
                        Button { app.copy(r, "CLI command copied. Paste it into Terminal") } label: {
                            Label(l.desktopSession != nil ? "CLI" : "Copy CLI command", systemImage: "terminal")
                        }
                        .controlSize(.small)
                        .help("Copies a Terminal command that resumes this chat in the CLI")
                    }
                    Spacer()
                    IconButton(icon: "link.badge.plus", help: "Unlink chat") {
                        app.update(t.id, undoable: true) { $0.links.removeAll { $0.id == l.id } }
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.2)))
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(icon: "checklist", title: "Checklist",
                         trailing: t.subtasks.isEmpty ? "" : "\(t.subtasks.filter(\.done).count)/\(t.subtasks.count)")
            if !t.subtasks.isEmpty {
                ProgressBar(value: Double(t.subtasks.filter(\.done).count) / Double(t.subtasks.count), color: .accentColor)
            }
            ForEach(t.subtasks) { s in StepRow(taskId: t.id, step: s) }
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 16)
                TextField("Add a step", text: $newStep.text)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .onSubmit {
                        let v = newStep.text.trimmed
                        guard !v.isEmpty else { return }
                        app.update(t.id) { $0.subtasks.append(Subtask(text: v)) }
                        newStep.text = ""
                    }
            }
            .padding(.vertical, 3)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(icon: "note.text", title: "Notes")
            TextEditor(text: Binding(get: { t.notes }, set: { v in app.update(t.id) { $0.notes = v } }))
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 110)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
            let links = urls(in: t.notes)
            if !links.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(links, id: \.self) { u in
                        Link(destination: u) { Label(u.absoluteString, systemImage: "link").lineLimit(1).truncationMode(.middle) }
                            .font(.system(size: 11.5))
                    }
                }
            }
        }
    }

    private func urls(in s: String) -> [URL] {
        guard let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return d.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap(\.url).filter { ["http", "https"].contains($0.scheme ?? "") }
    }

    private var footer: some View {
        HStack {
            Text("Created \(Day.label(String(t.createdAt.prefix(10))))" + (t.done && !t.doneDay.isEmpty ? " · Done \(Day.label(t.doneDay))" : ""))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button { app.duplicate(t.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }.controlSize(.small)
            Button(role: .destructive) { app.delete(t.id) } label: { Label("Delete", systemImage: "trash") }.controlSize(.small)
        }
        .padding(.top, 4)
    }
}

private struct SectionTitle: View {
    let icon: String
    let title: String
    var trailing = ""
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(trailing).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private struct StepRow: View {
    @ObservedObject var app = AppModel.shared
    @StateObject private var hover = Flag()
    let taskId: String
    let step: Subtask

    private func edit(_ f: @escaping (inout Subtask) -> Void) {
        app.update(taskId) { t in if let i = t.subtasks.firstIndex(where: { $0.id == step.id }) { f(&t.subtasks[i]) } }
    }

    var body: some View {
        HStack(spacing: 8) {
            CheckButton(done: step.done, priority: 0, size: 15) { edit { $0.done.toggle() } }.frame(width: 16)
            TextField("Step", text: Binding(get: { step.text }, set: { v in edit { $0.text = v } }))
                .textFieldStyle(.plain).font(.system(size: 13))
                .strikethrough(step.done).foregroundStyle(step.done ? .secondary : .primary)
            if hover.on {
                IconButton(icon: "xmark", help: "Remove step") {
                    app.update(taskId, undoable: true) { $0.subtasks.removeAll { $0.id == step.id } }
                }
            }
        }
        .frame(minHeight: 22)
        .onHover { hover.on = $0 }
    }
}

/// Compact segmented buttons (Today / Tomorrow / …), highlighting the current value.
struct Seg: View {
    let options: [(String, String)]
    let value: String
    var tint: ((String) -> Color)? = nil
    let set: (String) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.1) { o in
                let on = o.1 == value
                Button { set(o.1) } label: {
                    Text(o.0).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(on ? (tint?(o.1) ?? Color.accentColor) : Color.primary.opacity(0.8))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(on ? (tint?(o.1) ?? Color.accentColor).opacity(0.15) : Color.primary.opacity(0.05)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
