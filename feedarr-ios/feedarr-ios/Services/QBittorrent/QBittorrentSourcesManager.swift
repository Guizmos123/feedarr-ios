import Foundation
import Observation

nonisolated struct QBittorrentSourcesConfiguration: Codable {
    var version = 1
    var sources: [QBittorrentSource] = []
    var activeSourceID: UUID?
}

@MainActor
protocol QBittorrentSourcePersisting: AnyObject {
    func loadConfiguration() throws -> QBittorrentSourcesConfiguration
    func saveConfiguration(_ configuration: QBittorrentSourcesConfiguration) throws
}

@MainActor
final class UserDefaultsQBittorrentSourcePersistence: QBittorrentSourcePersisting {
    static let storageKey = "feedarr.qbittorrent.sources.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadConfiguration() throws -> QBittorrentSourcesConfiguration {
        guard let data = defaults.data(forKey: Self.storageKey) else { return .init() }
        do {
            let value = try JSONDecoder().decode(QBittorrentSourcesConfiguration.self, from: data)
            let ids = Set(value.sources.map(\.id))
            guard value.version == 1, ids.count == value.sources.count,
                  value.sources.isEmpty ? value.activeSourceID == nil : value.activeSourceID.map(ids.contains) == true else {
                throw QBittorrentError.configurationUnavailable
            }
            return value
        } catch { throw QBittorrentError.configurationUnavailable }
    }

    func saveConfiguration(_ configuration: QBittorrentSourcesConfiguration) throws {
        do { defaults.set(try JSONEncoder().encode(configuration), forKey: Self.storageKey) }
        catch { throw QBittorrentError.persistenceFailure }
    }
}

@MainActor
@Observable
final class QBittorrentSourcesManager {
    private(set) var sources: [QBittorrentSource] = []
    private(set) var activeSourceID: UUID?
    private(set) var configurationRevision = UUID()
    private(set) var loadError: QBittorrentError?
    var source: QBittorrentSource? { sources.first { $0.id == activeSourceID } }
    @ObservationIgnored private let persistence: any QBittorrentSourcePersisting
    @ObservationIgnored private let credentialsStore: any QBittorrentCredentialsStoring
    @ObservationIgnored private var persistenceUnavailable = false
    @ObservationIgnored private var sessions: [UUID: QBittorrentSession] = [:]

    init(persistence: any QBittorrentSourcePersisting = UserDefaultsQBittorrentSourcePersistence(),
         credentialsStore: any QBittorrentCredentialsStoring = QBittorrentCredentialsStore()) {
        self.persistence = persistence
        self.credentialsStore = credentialsStore
        do { try reload() } catch { /* reload preserves a non-sensitive error. */ }
    }

    private var configuration: QBittorrentSourcesConfiguration {
        .init(sources: sources, activeSourceID: activeSourceID)
    }

    func credentials(for id: UUID) throws -> QBittorrentCredentials {
        guard sources.contains(where: { $0.id == id }) else { throw QBittorrentError.sourceNotFound }
        do {
            guard let value = try credentialsStore.credentials(for: id) else { throw QBittorrentError.credentialsUnavailable }
            return value
        } catch { throw QBittorrentError.credentialsUnavailable }
    }

    /// New and modified configurations must originate from a successful WebUI validation.
    func save(_ validated: QBittorrentValidatedConfiguration, replacing id: UUID?, expectedRevision: UUID) throws {
        guard !persistenceUnavailable else { throw QBittorrentError.configurationUnavailable }
        guard configurationRevision == expectedRevision else { throw QBittorrentError.obsoleteResponse }
        let candidate = validated.source
        if let id {
            guard id == candidate.id, sources.contains(where: { $0.id == id }) else { throw QBittorrentError.sourceNotFound }
        } else if sources.contains(where: { $0.id == candidate.id }) { throw QBittorrentError.obsoleteResponse }
        var next = configuration
        if id != nil { next.sources = sources.map { $0.id == candidate.id ? candidate : $0 } }
        else { next.sources.append(candidate) }
        if next.activeSourceID == nil { next.activeSourceID = candidate.id }
        try commit(next, credentialID: candidate.id, credentials: validated.credentials)
    }

    func remove(id: UUID) throws {
        guard !persistenceUnavailable else { throw QBittorrentError.configurationUnavailable }
        guard sources.contains(where: { $0.id == id }) else { throw QBittorrentError.sourceNotFound }
        var next = configuration
        next.sources.removeAll { $0.id == id }
        if next.activeSourceID == id { next.activeSourceID = next.sources.first?.id }
        try commit(next, credentialID: id, credentials: nil)
    }

    func select(id: UUID) throws {
        guard !persistenceUnavailable else { throw QBittorrentError.configurationUnavailable }
        guard sources.contains(where: { $0.id == id }) else { throw QBittorrentError.sourceNotFound }
        var next = configuration
        next.activeSourceID = id
        try persistence.saveConfiguration(next)
        activeSourceID = id
        configurationRevision = UUID()
        refreshCredentialError()
    }

    func reload() throws {
        invalidateSessions()
        configurationRevision = UUID()
        do {
            let next = try persistence.loadConfiguration()
            sources = next.sources
            activeSourceID = next.activeSourceID
            persistenceUnavailable = false
            refreshCredentialError()
        } catch {
            persistenceUnavailable = true
            loadError = .configurationUnavailable
            throw QBittorrentError.configurationUnavailable
        }
    }

    func session(for source: QBittorrentSource) throws -> QBittorrentSession {
        guard !persistenceUnavailable, loadError == nil,
              sources.contains(source) else { throw QBittorrentError.configurationUnavailable }
        if let session = sessions[source.id] { return session }
        let session = QBittorrentSession(baseURL: source.serverURL, credentials: try credentials(for: source.id))
        sessions[source.id] = session
        return session
    }

    private func commit(_ next: QBittorrentSourcesConfiguration, credentialID: UUID,
                        credentials: QBittorrentCredentials?) throws {
        let old: QBittorrentCredentials?
        do { old = try credentialsStore.credentials(for: credentialID) }
        catch { throw QBittorrentError.credentialsUnavailable }
        do { try replaceCredentials(credentials, id: credentialID) }
        catch {
            invalidateSessions()
            configurationRevision = UUID()
            refreshCredentialError()
            throw QBittorrentError.credentialsUnavailable
        }
        do { try persistence.saveConfiguration(next) }
        catch {
            // Secrets may have changed even if a compensating transaction fails. Reject all old responses.
            invalidateSessions()
            configurationRevision = UUID()
            do { try replaceCredentials(old, id: credentialID) }
            catch {
                persistenceUnavailable = true
                loadError = .rollbackFailure
                throw QBittorrentError.rollbackFailure
            }
            throw QBittorrentError.persistenceFailure
        }
        invalidateSessions()
        sources = next.sources
        activeSourceID = next.activeSourceID
        configurationRevision = UUID()
        refreshCredentialError()
    }

    private func replaceCredentials(_ credentials: QBittorrentCredentials?, id: UUID) throws {
        if let credentials { try credentialsStore.setCredentials(credentials, for: id) }
        else { try credentialsStore.deleteCredentials(for: id) }
    }

    private func invalidateSessions() {
        let previous = Array(sessions.values)
        sessions = [:]
        for session in previous { Task { await session.invalidate() } }
    }

    private func refreshCredentialError() {
        guard let source else { loadError = nil; return }
        do { _ = try credentials(for: source.id); loadError = nil }
        catch { loadError = .credentialsUnavailable }
    }
}
