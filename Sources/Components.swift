// Daybook — shared pieces: task row / card, chips, checkbox, progress ring, drop targets.

import SwiftUI
import AppKit

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0x8e8e93
        self.init(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    static func status(_ s: TaskStatus) -> Color {
        switch s {
        case .todo: return .secondary
        case .inProgress: return .blue
        case .review: return .purple
        case .blocked: return .red
        case .done: return .green
        }
    }

    static func priority(_ p: Int) -> Color {
        switch p {
        case 3: return .red
        case 2: return .orange
        case 1: return .blue
        default: return .secondary
        }
    }
}

/// Small per-view flag (hover, focus…) — SwiftUI's @State isn't available with the Command Line Tools compiler.
final class Flag: ObservableObject { @Published var on = false }
final class TextBox: ObservableObject { @Published var text = "" }

// MARK: - Checkbox

struct CheckButton: View {
    let done: Bool
    let priority: Int
    var size: CGFloat = 18
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(done ? Color.accentColor : (priority > 0 ? Color.priority(priority) : Color.secondary.opacity(0.55)),
                                  lineWidth: 1.5)
                    .background(Circle().fill(done ? Color.accentColor : (priority > 0 ? Color.priority(priority).opacity(0.1) : .clear)))
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .help(done ? "Mark not done" : "Complete (X)")
        .animation(.spring(duration: 0.25, bounce: 0.4), value: done)
    }
}

// MARK: - Chips

struct Chip: View {
    var icon: String? = nil
    var text: String = ""
    var color: Color = .secondary
    var filled = false
    var dot: Color? = nil
    var compact = false

    var body: some View {
        HStack(spacing: 3) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            if let icon { Image(systemName: icon).font(.system(size: compact ? 9 : 9.5, weight: .semibold)) }
            if !text.isEmpty { Text(text).lineLimit(1) }
        }
        .font(.system(size: compact ? 10.5 : 11, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, compact ? (filled ? 4 : 1) : 6).padding(.vertical, compact ? 1 : 2)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(filled ? color.opacity(0.14) : (compact ? Color.clear : Color.primary.opacity(0.05))))
    }
}

struct TaskMeta: View {
    @ObservedObject var app = AppModel.shared
    let t: DayTask
    var hideDate = false
    var hideList = false
    var card = false

    var body: some View {
        let chips = items
        if !chips.isEmpty {
            FlowRow(spacing: card ? 5 : 4) { ForEach(chips.indices, id: \.self) { chips[$0] } }
        }
    }

    private var items: [Chip] {
        if card && t.done { return [] }
        return full.map { var x = $0; x.compact = card; return x }
    }

    private var full: [Chip] {
        var c: [Chip] = []
        if !t.done && t.st != .todo { c.append(Chip(icon: t.st.icon, text: t.st.label, color: .status(t.st), filled: true)) }
        if !hideDate && !t.date.isEmpty {
            let overdue = !t.done && t.date < app.today
            c.append(Chip(icon: "calendar", text: Day.label(t.date), color: overdue ? .red : (t.date == app.today ? .green : .secondary), filled: overdue || t.date == app.today))
        }
        if !t.time.isEmpty { c.append(Chip(icon: "clock", text: fmtTime(t.time))) }
        if t.estimate > 0 { c.append(Chip(icon: "timer", text: fmtMinutes(t.estimate))) }
        if !t.subtasks.isEmpty { c.append(Chip(icon: "checklist", text: "\(t.subtasks.filter(\.done).count)/\(t.subtasks.count)")) }
        if t.repeatRule != .never { c.append(Chip(icon: "repeat")) }
        if !t.notes.isEmpty && !card { c.append(Chip(icon: "note.text")) }
        if !hideList, let l = app.list(t.listId) { c.append(Chip(text: card ? "" : l.name, dot: Color(hex: l.color))) }
        for tag in t.tags { c.append(Chip(text: "#" + tag)) }
        if t.chat != nil { c.append(Chip(icon: "sparkle", text: card ? "" : "Chat", color: .orange, filled: !card)) }
        return c
    }
}

/// Wrapping row of small views (chips).
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0 && x + z.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += z.width + spacing; rowH = max(rowH, z.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + z.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z))
            x += z.width + spacing; rowH = max(rowH, z.height)
        }
    }
}

// MARK: - Task row (lists) and card (week / board columns)

struct TaskRow: View {
    @ObservedObject var app = AppModel.shared
    @StateObject private var hover = Flag()
    @StateObject private var dropHere = Flag()
    let t: DayTask
    var card = false
    var hideDate = false
    var hideList = false
    var zone: Zone? = nil          // set when rows here can be reordered by dragging

    private var isSelected: Bool { app.selected == t.id }
    private var isDone: Bool { t.done || app.completing.contains(t.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CheckButton(done: isDone, priority: t.priority, size: card ? 16 : 18) { app.complete(t.id) }
                .padding(.top, card ? 1 : 0)
            VStack(alignment: .leading, spacing: 4) {
                Text(t.title)
                    .font(.system(size: card ? 12.5 : 13.5, weight: .regular))
                    .strikethrough(isDone, color: .secondary)
                    .foregroundStyle(isDone ? .secondary : .primary)
                    .lineLimit(card ? (t.done ? 2 : 4) : 2)
                    .fixedSize(horizontal: false, vertical: true)
                TaskMeta(t: t, hideDate: hideDate, hideList: hideList, card: card)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hover.on && !card && !t.done { quickActions }
        }
        .padding(.horizontal, card ? 9 : 10)
        .padding(.vertical, card ? 8 : 7)
        .background(background)
        .overlay(alignment: .top) {
            if dropHere.on { Capsule().fill(Color.accentColor).frame(height: 2.5).offset(y: card ? -5 : -2) }
        }
        .contentShape(Rectangle())
        .opacity(app.completing.contains(t.id) ? 0.55 : 1)
        .onHover { h in hover.on = h }
        .onTapGesture(count: 2) { app.open(t.id); app.focusTitle += 1 }
        .onTapGesture { app.open(t.id) }
        .draggable(t.id) {
            Text(t.title).font(.system(size: 13)).padding(8).frame(maxWidth: 260, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.background))
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, let zone, id != t.id else { return false }
            app.drop(id, on: zone, before: t.done ? nil : t.id)
            return true
        } isTargeted: { on in dropHere.on = on && zone != nil }
        .contextMenu { TaskMenu(t: t) }
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: card ? 9 : 8, style: .continuous)
        if card {
            shape.fill(Color(nsColor: .controlBackgroundColor))
                .overlay(shape.strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1))
                .shadow(color: .black.opacity(hover.on ? 0.10 : 0.04), radius: hover.on ? 4 : 1.5, y: 1)
                .overlay(alignment: .leading) {
                    if t.priority > 0 && !t.done {
                        UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 9).fill(Color.priority(t.priority)).frame(width: 3)
                    }
                }
        } else {
            shape.fill(isSelected ? Color.accentColor.opacity(0.13)
                       : app.flashId == t.id ? Color.accentColor.opacity(0.10)
                       : hover.on ? Color.primary.opacity(0.045) : .clear)
        }
    }

    private var quickActions: some View {
        HStack(spacing: 2) {
            if t.date != app.today {
                IconButton(icon: "sun.max", help: "Do today (T)") { app.schedule(t.id, app.today) }
            } else {
                IconButton(icon: "arrow.right", help: "Move to tomorrow (M)") { app.schedule(t.id, Day.add(app.today, 1)) }
            }
            IconButton(icon: "trash", help: "Delete (D)", tint: .red) { app.delete(t.id) }
        }
        .transition(.opacity)
    }
}

struct IconButton: View {
    let icon: String
    var help = ""
    var tint: Color = .secondary
    let action: () -> Void
    @StateObject private var hover = Flag()

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hover.on ? tint : .secondary)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover.on ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .help(help)
    }
}

/// Right-click menu for a task (also used in the inspector's ⋯ menu).
struct TaskMenu: View {
    @ObservedObject var app = AppModel.shared
    let t: DayTask

    var body: some View {
        Button(t.done ? "Mark Not Done" : "Complete") { app.complete(t.id) }
        Button("Open Details") { app.open(t.id) }
        Divider()
        Menu("Status") {
            ForEach(TaskStatus.allCases) { s in
                Button { app.setStatus(t.id, s) } label: { Label(s.label, systemImage: t.st == s ? "checkmark" : s.icon) }
            }
        }
        Menu("Schedule") {
            Button("Today") { app.schedule(t.id, app.today) }
            Button("Tomorrow") { app.schedule(t.id, Day.add(app.today, 1)) }
            Button("Next Week") { app.schedule(t.id, Day.add(Day.monday(app.today), 7)) }
            Button("No Date (Inbox)") { app.schedule(t.id, "") }
        }
        Menu("Priority") {
            ForEach((0...3).reversed(), id: \.self) { p in
                Button { app.update(t.id, undoable: true) { $0.priority = p } } label: {
                    Label(priorityNames[p], systemImage: t.priority == p ? "checkmark" : "flag")
                }
            }
        }
        Menu("Move to List") {
            Button("No List") { app.drop(t.id, on: .list(""), sortable: false) }
            ForEach(app.data.lists) { l in Button(l.name) { app.drop(t.id, on: .list(l.id), sortable: false) } }
        }
        if let l = t.chat {
            Divider()
            if l.desktopSession != nil { Button("Open Chat in Desktop App") { app.openChat(l) } }
            if let r = l.meta["resume"]?.string { Button("Copy CLI Resume Command") { app.copy(r, "CLI command copied. Paste it into Terminal") } }
        }
        Divider()
        Button("Duplicate") { app.duplicate(t.id) }
        Button("Delete", role: .destructive) { app.delete(t.id) }
    }
}

// MARK: - Progress ring & bar

struct ProgressRing: View {
    let value: Double
    var size: CGFloat = 40
    var line: CGFloat = 5
    var color: Color = .accentColor

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: line)
            Circle().trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(value >= 1 ? Color.green : color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if value >= 1 { Image(systemName: "checkmark").font(.system(size: size * 0.32, weight: .bold)).foregroundStyle(.green) }
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.5), value: value)
    }
}

struct ProgressBar: View {
    let value: Double
    var color: Color = .green

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(color).frame(width: g.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: 4)
        .animation(.spring(duration: 0.5), value: value)
    }
}

/// A whole-area drop target (column body, section, sidebar row) with a highlight while hovering.
struct DropArea: ViewModifier {
    @ObservedObject var app = AppModel.shared
    @StateObject private var hot = Flag()
    let zone: Zone?
    var sortable = true
    var radius: CGFloat = 10

    func body(content: Content) -> some View {
        if let zone {
            content
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hot.on ? Color.accentColor.opacity(0.08) : .clear))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(hot.on ? Color.accentColor.opacity(0.6) : .clear, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first else { return false }
                    app.drop(id, on: zone, sortable: sortable)
                    return true
                } isTargeted: { hot.on = $0 }
        } else {
            content
        }
    }
}

extension View {
    func dropArea(_ zone: Zone?, sortable: Bool = true, radius: CGFloat = 10) -> some View {
        modifier(DropArea(zone: zone, sortable: sortable, radius: radius))
    }
}

/// Plain borderless text field for inline "+ Add task" inputs.
struct InlineAdd: View {
    @StateObject private var box = TextBox()
    let placeholder: String
    let onSubmit: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            TextField(placeholder, text: $box.text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .onSubmit {
                    let v = box.text
                    guard !v.trimmed.isEmpty else { return }
                    onSubmit(v)
                    box.text = ""
                }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
    }
}
