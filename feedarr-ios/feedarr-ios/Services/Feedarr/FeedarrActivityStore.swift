import Foundation
import Observation

/// Excludes server names, URLs, free-form errors, artwork and credentials.
/// The optional bounded release title is the only persisted display text.
nonisolated struct FeedarrActivityEvent: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case releaseOpened, download }
    enum Outcome: String, Codable, Sendable {
        // An interrupted app cannot know whether an external transfer completed.
        case unknown, exportSucceeded, failed, cancelled, magnetCopied
    }
    let id: UUID
    var date: Date
    let kind: Kind
    let serverID: UUID
    let releaseID: Int64
    let year: Int?
    let title: String?
    var outcome: Outcome?
}

@MainActor
@Observable
final class FeedarrActivityStore {
    static let shared = FeedarrActivityStore()
    static let maximumEvents = 500
    static let retention: TimeInterval = 90 * 24 * 60 * 60
    private static let storageKey = "feedarr.activity.v1"
    private var events: [FeedarrActivityEvent] = []
    private var generation = UUID()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey), data.count <= 1_024 * 1_024,
           let saved = try? JSONDecoder().decode([FeedarrActivityEvent].self, from: data) {
            var seen: Set<UUID> = []
            events = saved.filter { seen.insert($0.id).inserted }
            purge()
        }
    }

    var history: [FeedarrActivityEvent] {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        return events.filter { $0.date >= cutoff }
    }
    // Counters always derive from retained records, never from independent totals.
    var openingCount: Int { history.filter { $0.kind == .releaseOpened }.count }
    var downloadCount: Int { history.filter { $0.kind == .download }.count }
    func count(_ outcome: FeedarrActivityEvent.Outcome) -> Int {
        history.filter { $0.kind == .download && $0.outcome == outcome }.count
    }

    func recordOpening(serverID: UUID, release: FeedarrRelease) {
        append(kind: .releaseOpened, serverID: serverID, release: release, outcome: nil)
    }

    func beginDownload(serverID: UUID, release: FeedarrRelease) -> FeedarrActivityDownload {
        let id = append(kind: .download, serverID: serverID, release: release, outcome: .unknown)
        return FeedarrActivityDownload(id: id, generation: generation, store: self)
    }

    @discardableResult
    private func append(kind: FeedarrActivityEvent.Kind, serverID: UUID, release: FeedarrRelease,
                        outcome: FeedarrActivityEvent.Outcome?) -> UUID {
        let event = FeedarrActivityEvent(id: UUID(), date: Date(), kind: kind, serverID: serverID,
                                         releaseID: release.id, year: release.year, title: Self.safeTitle(release), outcome: outcome)
        events.append(event)
        purge()
        return event.id
    }

    private static func safeTitle(_ release: FeedarrRelease) -> String? {
        guard let raw = release.titleClean ?? release.title else { return nil }
        let title = raw.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep only the requested display title, never embedded links or credentials.
        guard !title.isEmpty, !title.contains("://"), !title.lowercased().contains("magnet:"),
              !title.contains("@") else { return nil }
        return String(title.prefix(200))
    }

    fileprivate func finish(id: UUID, generation: UUID, outcome: FeedarrActivityEvent.Outcome) {
        // Clearing or purging history must not be undone by a late UIKit callback.
        guard self.generation == generation,
              let index = events.firstIndex(where: { $0.id == id && $0.outcome == .unknown }) else { return }
        events[index].outcome = outcome
        events[index].date = Date()
        purge()
    }

    /// Explicitly supports an earlier purge date; automatic retention is always enforced.
    func purge(before date: Date? = nil) {
        let cutoff = max(date ?? .distantPast, Date().addingTimeInterval(-Self.retention))
        events = Array(events.filter { $0.date >= cutoff }.sorted { $0.date > $1.date }.prefix(Self.maximumEvents))
        persist()
    }

    func clear() {
        generation = UUID()
        events = []
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(events) { defaults.set(data, forKey: Self.storageKey) }
    }
}

/// One terminal outcome per user attempt, independent of view updates and repeated callbacks.
@MainActor
final class FeedarrActivityDownload {
    private let id: UUID
    private let generation: UUID
    private let store: FeedarrActivityStore
    private var finished = false

    fileprivate init(id: UUID, generation: UUID, store: FeedarrActivityStore) {
        self.id = id
        self.generation = generation
        self.store = store
    }

    func finish(_ outcome: FeedarrActivityEvent.Outcome) {
        guard !finished, outcome != .unknown else { return }
        finished = true
        store.finish(id: id, generation: generation, outcome: outcome)
    }
}
