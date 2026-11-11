// Daybook — app entry point, menus, single-key shortcuts, settings window.

import SwiftUI
import AppKit

@main
struct DaybookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Daybook", id: "main") {
            MainView()
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1360, height: 880)
        .commands { DaybookCommands() }

        Settings { SettingsView() }
    }
}

struct DaybookCommands: Commands {
    @ObservedObject var app = AppModel.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") { app.command("new") }.keyboardShortcut("n")
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Search Tasks") { app.command("search") }.keyboardShortcut("f")
        }
        CommandGroup(before: .sidebar) {
            Button("Command Palette…") { app.command("palette") }.keyboardShortcut("k")
            Divider()
            Button("Today") { app.command("goToday") }.keyboardShortcut("1")
            Button("This Week") { app.command("goWeek") }.keyboardShortcut("2")
            Button("Inbox") { app.command("goInbox") }.keyboardShortcut("3")
            Button("Upcoming") { app.command("goUpcoming") }.keyboardShortcut("4")
            Button("Completed") { app.command("goCompleted") }.keyboardShortcut("5")
            Button("Board") { app.command("goBoard") }.keyboardShortcut("6")
            Divider()
            Button("Previous Week") { app.command("weekPrev") }.keyboardShortcut("[", modifiers: [.command])
            Button("Next Week") { app.command("weekNext") }.keyboardShortcut("]", modifiers: [.command])
            Divider()
        }
        CommandMenu("Task") {
            let has = app.task(app.selected) != nil
            Group {
                Button("Complete") { app.command("complete") }
                Button("Show Details") { app.command("open") }
                Divider()
                Button("Do Today") { app.command("today") }
                Button("Do Tomorrow") { app.command("tomorrow") }
                Button("Next Week") { app.command("nextWeek") }
                Button("Remove Date") { app.command("noDate") }
                Divider()
                Button("Next Status") { app.command("status") }
                Button("Cycle Priority") { app.command("priority") }
                Divider()
                Button("Duplicate") { app.command("duplicate") }.keyboardShortcut("d")
                Button("Open AI Chat") { app.command("openChat") }.keyboardShortcut("o")
                    .disabled(app.task(app.selected)?.chat?.desktopSession == nil)
                Divider()
                Button("Delete") { app.command("delete") }.keyboardShortcut(.delete, modifiers: .command)
            }
            .disabled(!has)
            Divider()
            Button("Move Overdue to Today") { app.moveOverdueToToday() }
            Button("AI Chats → Board…") { app.command("aiChats") }
            Button("Check AI Chats Now") { app.command("syncChats") }.disabled(!app.data.aiChats.enabled)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { app.command("shortcuts") }.keyboardShortcut("/")
            Button("Show Data File in Finder") { app.revealData() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handle(e) ?? e }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.checkDayChange(); AppModel.shared.syncChats() }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.start() } }
    }

    // Closing the window keeps Daybook in the Dock (badge stays current); ⌘Q quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.checkDayChange(); AppModel.shared.pollDisk() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let w = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") ?? false }) {
            w.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.saveNow() }
    }

    // MARK: single-key shortcuts (only when no text field has focus)

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard let w = NSApp.keyWindow, w.identifier?.rawValue.contains("main") ?? false, w.attachedSheet == nil else { return e }
        let typing = w.firstResponder is NSText || w.firstResponder is NSTextField
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let run = { (c: String) in MainActor.assumeIsolated { AppModel.shared.command(c) } }
        if typing { return e }
        if mods == .command && e.charactersIgnoringModifiers == "z" { run("undo"); return nil }
        if !mods.subtracting([.shift]).isEmpty { return e }

        switch e.keyCode {
        case 53: run("close"); return nil                    // Esc
        case 51, 117: run("delete"); return nil              // ⌫ / ⌦
        case 125: run("next"); return nil                    // ↓
        case 126: run("prev"); return nil                    // ↑
        case 36, 76: run("open"); return nil                 // ↩
        default: break
        }
        switch e.charactersIgnoringModifiers ?? "" {
        case "n", "N", "q": run("new")
        case "/": run("search")
        case "?": run("shortcuts")
        case "1": run("goToday")
        case "2": run("goWeek")
        case "3": run("goInbox")
        case "4": run("goUpcoming")
        case "5": run("goCompleted")
        case "6": run("goBoard")
        case "j": run("next")
        case "k": run("prev")
        case "e": run("edit")
        case "x", " ": run("complete")
        case "t": run("today")
        case "m": run("tomorrow")
        case "w": run("nextWeek")
        case "i": run("noDate")
        case "p": run("priority")
        case "s": run("status")
        case "d": run("delete")
        case "[": run("weekPrev")
        case "]": run("weekNext")
        default: return e
        }
        return nil
    }
}

// MARK: - Settings (⌘,)

struct SettingsView: View {
    @ObservedObject var app = AppModel.shared

    var body: some View {
        Form {
            Picker("Appearance", selection: Binding(get: { app.data.theme }, set: { app.setTheme($0) })) {
                Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            Toggle("Add AI work chats to the Board", isOn: Binding(get: { app.data.aiChats.enabled }, set: { app.setAIChatsEnabled($0) }))
            LabeledContent("Data") {
                HStack {
                    Text(app.store.file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    Button("Show") { app.revealData() }
                }
            }
            Text("Everything stays on this Mac. A copy of the file is kept each day in backups/ (last 21 days).")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize()
    }
}
