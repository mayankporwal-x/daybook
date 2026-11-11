// Daybook — the data file: load, atomic save, daily backups, outside-edit detection, first-run migration.
//
// Everything lives in ~/Library/Application Support/Daybook/:
//   tasks.json            all tasks, lists, week goals/notes, settings
//   backups/              previous tasks.json, one per day, last 21 days
//   ai-chats-index.json   what has been read from AI chat files
//   ai-chats-state.json   chats already added, last check

import Foundation

final class Store {
    static let dir: URL = {
        if let custom = ProcessInfo.processInfo.environment["DAYBOOK_DATA"], !custom.isEmpty {  // for testing on a copy
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Daybook", isDirectory: true)
    }()
    let file = Store.dir.appendingPathComponent("tasks.json")
    let backups = Store.dir.appendingPathComponent("backups", isDirectory: true)
    private(set) var diskStamp: Date?
    private(set) var migratedFrom: String?

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: backups, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) { migrateFromWebApp() }
    }

    /// The earlier web version kept its data in `data/` next to Daybook.app. Copy it (never move it).
    private func migrateFromWebApp() {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("data"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Developer/projects/daybook/data"),
        ]
        guard let src = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("tasks.json").path) }) else { return }
        for name in ["tasks.json", "claude-index.json", "claude-state.json"] {
            let from = src.appendingPathComponent(name), to = Store.dir.appendingPathComponent(name)
            if fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) { try? fm.copyItem(at: from, to: to) }
        }
        let oldBackups = src.appendingPathComponent("backups")
        for f in (try? fm.contentsOfDirectory(atPath: oldBackups.path)) ?? [] where f.hasSuffix(".json") {
            let to = backups.appendingPathComponent(f)
            if !fm.fileExists(atPath: to.path) { try? fm.copyItem(at: oldBackups.appendingPathComponent(f), to: to) }
        }
        migratedFrom = src.path
    }

    var modifiedOnDisk: Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// True when something other than this app (an AI assistant, an editor) wrote the file since we last read/wrote it.
    var changedOutside: Bool {
        guard let m = modifiedOnDisk else { return false }
        return m != diskStamp
    }

    func load() throws -> DaybookData {
        guard FileManager.default.fileExists(atPath: file.path) else {
            diskStamp = nil
            return DaybookData()
        }
        let raw = try Data(contentsOf: file)
        diskStamp = modifiedOnDisk
        return try JSONDecoder().decode(DaybookData.self, from: raw)
    }

    func save(_ data: DaybookData) throws {
        backupOncePerDay()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let raw = try enc.encode(data)
        try raw.write(to: file, options: .atomic)
        diskStamp = modifiedOnDisk
    }

    private func backupOncePerDay() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return }
        let target = backups.appendingPathComponent("tasks-\(Day.today).json")
        if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: file, to: target) }
        let all = ((try? fm.contentsOfDirectory(atPath: backups.path)) ?? [])
            .filter { $0.hasPrefix("tasks-") && $0.hasSuffix(".json") }.sorted()
        for old in all.dropLast(21) { try? fm.removeItem(at: backups.appendingPathComponent(old)) }
    }
}
