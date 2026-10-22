import Foundation

public struct HistoryEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let raw: String
    public let cleaned: String
    public init(raw: String, cleaned: String, date: Date = Date()) { id = UUID(); self.date = date; self.raw = raw; self.cleaned = cleaned }
}

/// Opt-in plaintext local history. Disabled state deletes history; retention is seven days / at most 100 entries.
public actor HistoryStore {
    public let file: URL
    public init(file: URL) { self.file = file }
    public func entries(enabled: Bool, now: Date = Date()) throws -> [HistoryEntry] {
        guard enabled else { try clear(); return [] }
        let decoded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
        let retained = Array(decoded.filter { $0.date > now.addingTimeInterval(-7 * 86400) && $0.date <= now }.prefix(100))
        if retained.count != decoded.count { try save(retained) }
        return retained
    }
    public func append(_ entry: HistoryEntry, enabled: Bool) throws {
        try Task.checkCancellation()
        guard enabled else { try clear(); return }
        var all = try entries(enabled: true); all.insert(entry, at: 0); try save(Array(all.prefix(100)))
    }
    public func clear() throws { if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }
    private func save(_ entries: [HistoryEntry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
