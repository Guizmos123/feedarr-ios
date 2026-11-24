//
//  FeedarrSourcesManager.swift
//  Yattee
//
//  Coordinates persistent Feedarr metadata and optional Basic Auth credentials.
//

import Foundation
import SwiftUI

nonisolated enum FeedarrSourcesManagerError: Error, LocalizedError, Equatable, Sendable {
    case sourceNotFound
    case insecureBasicAuth
    case incompleteCredentials
    case missingCredentials
    case persistenceFailure
    case credentialFailure
    case rollbackFailure

    var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            return "The Feedarr source was not found."
        case .insecureBasicAuth:
            return "Feedarr Basic Auth requires HTTPS."
        case .incompleteCredentials:
            return "Feedarr Basic Auth requires both a username and a password."
        case .missingCredentials:
            return "The Feedarr source credentials are missing."
        case .persistenceFailure:
            return "The Feedarr source could not be saved locally."
        case .credentialFailure:
            return "The local Feedarr credential store is unavailable."
        case .rollbackFailure:
            return "The Feedarr source update could not be rolled back safely."
        }
    }
}

nonisolated struct FeedarrSourcesConfiguration: Codable {
    var sources: [FeedarrSource] = []
    var activeSourceID: UUID?
}

@MainActor
protocol FeedarrSourcePersisting: AnyObject {
    func loadConfiguration() throws -> FeedarrSourcesConfiguration
    func saveConfiguration(_ configuration: FeedarrSourcesConfiguration) throws
}

@MainActor
final class UserDefaultsFeedarrSourcePersistence: FeedarrSourcePersisting {
    static let sourceKey = "feedarrServersConfiguration"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadConfiguration() throws -> FeedarrSourcesConfiguration {
        guard let data = defaults.data(forKey: Self.sourceKey) else { return .init() }
        do {
            let configuration = try JSONDecoder().decode(FeedarrSourcesConfiguration.self, from: data)
            let ids = Set(configuration.sources.map(\.id))
            guard ids.count == configuration.sources.count,
                  (configuration.sources.isEmpty ? configuration.activeSourceID == nil :
                    configuration.activeSourceID.map(ids.contains) == true) else {
                throw FeedarrSourcesManagerError.persistenceFailure
            }
            return configuration
        } catch { throw FeedarrSourcesManagerError.persistenceFailure }
    }

    func saveConfiguration(_ configuration: FeedarrSourcesConfiguration) throws {
        do { defaults.set(try JSONEncoder().encode(configuration), forKey: Self.sourceKey) }
        catch { throw FeedarrSourcesManagerError.persistenceFailure }
    }
}

@MainActor
@Observable
final class FeedarrSourcesManager {
    private(set) var sources: [FeedarrSource] = []
    private(set) var activeSourceID: UUID?
    var source: FeedarrSource? { sources.first { $0.id == activeSourceID } }
    private var configuration: FeedarrSourcesConfiguration {
        .init(sources: sources, activeSourceID: activeSourceID)
    }
    private var persistenceUnavailable = false
    private(set) var loadError: FeedarrSourcesManagerError?
    /// Cache consumers must also observe credentials-only changes (source metadata can remain equal).
    private(set) var configurationRevision = UUID()

    private let persistence: FeedarrSourcePersisting
    private let credentialsStore: FeedarrCredentialsStoring

    init() {
        persistence = UserDefaultsFeedarrSourcePersistence()
        credentialsStore = FeedarrCredentialsStore()
        loadInitialState()
    }

    init(
        persistence: FeedarrSourcePersisting,
        credentialsStore: FeedarrCredentialsStoring
    ) {
        self.persistence = persistence
        self.credentialsStore = credentialsStore
        loadInitialState()
    }

    @discardableResult
    func add(
        name: String,
        serverURL: String,
        usesBasicAuth: Bool,
        username: String? = nil,
        password: String? = nil,
        dateAdded: Date = Date()
    ) throws -> FeedarrSource {
        defer { configurationRevision = UUID() }
        guard !persistenceUnavailable else { throw FeedarrSourcesManagerError.persistenceFailure }
        let newSource = try FeedarrSource(
            name: name,
            serverURL: serverURL,
            dateAdded: dateAdded,
            usesBasicAuth: usesBasicAuth
        )
        let credentials = try validatedCredentials(
            for: newSource,
            username: username,
            password: password,
            existing: nil,
            mayReuseExisting: false
        )

        if let credentials {
            do {
                try credentialsStore.setCredentials(credentials, for: newSource.id)
            } catch {
                throw FeedarrSourcesManagerError.credentialFailure
            }
        }

        do {
            var next = configuration
            next.sources.append(newSource)
            if next.activeSourceID == nil { next.activeSourceID = newSource.id }
            try persistence.saveConfiguration(next)
        } catch {
            do {
                if credentials != nil {
                    try credentialsStore.deleteCredentials(for: newSource.id)
                }
            } catch {
                throw FeedarrSourcesManagerError.rollbackFailure
            }
            throw FeedarrSourcesManagerError.persistenceFailure
        }

        sources.append(newSource)
        if activeSourceID == nil { activeSourceID = newSource.id }
        refreshActiveError()
        return newSource
    }

    @discardableResult
    func update(
        id: UUID,
        name: String,
        serverURL: String,
        usesBasicAuth: Bool,
        username: String? = nil,
        password: String? = nil
    ) throws -> FeedarrSource {
        defer { configurationRevision = UUID() }
        guard !persistenceUnavailable else { throw FeedarrSourcesManagerError.persistenceFailure }
        guard let previous = sources.first(where: { $0.id == id }) else {
            throw FeedarrSourcesManagerError.sourceNotFound
        }
        let updated = try FeedarrSource(
            id: previous.id,
            name: name,
            serverURL: serverURL,
            dateAdded: previous.dateAdded,
            usesBasicAuth: usesBasicAuth
        )

        let oldCredentials: FeedarrCredentials?
        do {
            oldCredentials = try credentialsStore.credentials(for: id)
        } catch {
            throw FeedarrSourcesManagerError.credentialFailure
        }
        let mayReuse = previous.serverURL == updated.serverURL && previous.usesBasicAuth
        let newCredentials = try validatedCredentials(
            for: updated,
            username: username,
            password: password,
            existing: oldCredentials,
            mayReuseExisting: mayReuse
        )
        let credentialsChanged = newCredentials != oldCredentials

        if credentialsChanged {
            do {
                try replaceCredentials(newCredentials, for: id)
            } catch let error as FeedarrSourcesManagerError {
                throw error
            } catch {
                throw FeedarrSourcesManagerError.credentialFailure
            }
        }

        do {
            var next = configuration
            next.sources = sources.map { $0.id == id ? updated : $0 }
            try persistence.saveConfiguration(next)
        } catch {
            if credentialsChanged {
                do {
                    try replaceCredentials(oldCredentials, for: id)
                } catch {
                    throw FeedarrSourcesManagerError.rollbackFailure
                }
            }
            throw FeedarrSourcesManagerError.persistenceFailure
        }

        sources = sources.map { $0.id == id ? updated : $0 }
        refreshActiveError()
        return updated
    }

    func remove(id: UUID) throws {
        defer { configurationRevision = UUID() }
        guard !persistenceUnavailable else { throw FeedarrSourcesManagerError.persistenceFailure }
        guard sources.contains(where: { $0.id == id }) else {
            throw FeedarrSourcesManagerError.sourceNotFound
        }
        let oldCredentials: FeedarrCredentials?
        do {
            oldCredentials = try credentialsStore.credentials(for: id)
            try credentialsStore.deleteCredentials(for: id)
        } catch {
            throw FeedarrSourcesManagerError.credentialFailure
        }

        do {
            var next = configuration
            next.sources.removeAll { $0.id == id }
            if next.activeSourceID == id { next.activeSourceID = next.sources.first?.id }
            try persistence.saveConfiguration(next)
        } catch {
            do {
                if let oldCredentials {
                    try credentialsStore.setCredentials(oldCredentials, for: id)
                }
            } catch {
                throw FeedarrSourcesManagerError.rollbackFailure
            }
            throw FeedarrSourcesManagerError.persistenceFailure
        }

        sources.removeAll { $0.id == id }
        if activeSourceID == id { activeSourceID = sources.first?.id }
        refreshActiveError()
    }

    func select(id: UUID) throws {
        guard !persistenceUnavailable else { throw FeedarrSourcesManagerError.persistenceFailure }
        guard sources.contains(where: { $0.id == id }) else {
            throw FeedarrSourcesManagerError.sourceNotFound
        }
        var next = configuration
        next.activeSourceID = id
        try persistence.saveConfiguration(next)
        activeSourceID = id
        configurationRevision = UUID()
        refreshActiveError()
    }

    /// Reuse secrets only for the same server, as in update().
    func credentialsForValidation(
        id: UUID?, serverURL: String, usesBasicAuth: Bool,
        username: String?, password: String?
    ) throws -> FeedarrCredentials? {
        let candidate = try FeedarrSource(name: "Validation", serverURL: serverURL, usesBasicAuth: usesBasicAuth)
        let previous = sources.first { $0.id == id }
        let mayReuse = previous?.serverURL == candidate.serverURL && previous?.usesBasicAuth == true
        let existing: FeedarrCredentials?
        do {
            if mayReuse, let previous { existing = try credentialsStore.credentials(for: previous.id) }
            else { existing = nil }
        }
        catch { throw FeedarrSourcesManagerError.credentialFailure }
        return try validatedCredentials(for: candidate, username: username, password: password,
                                        existing: existing, mayReuseExisting: mayReuse)
    }

    func reload() throws {
        defer { configurationRevision = UUID() }
        do {
            let loaded = try persistence.loadConfiguration()
            sources = loaded.sources
            activeSourceID = loaded.activeSourceID
            persistenceUnavailable = false
        } catch {
            persistenceUnavailable = true
            loadError = .persistenceFailure
            throw FeedarrSourcesManagerError.persistenceFailure
        }
        refreshActiveError()
    }

    private func refreshActiveError() {
        guard let loaded = source else { loadError = nil; return }
        guard loaded.usesBasicAuth else {
            loadError = nil
            return
        }
        guard loaded.serverURL.scheme == "https" else {
            loadError = .insecureBasicAuth
            return
        }
        do {
            if try credentialsStore.credentials(for: loaded.id) == nil {
                loadError = .missingCredentials
            } else {
                loadError = nil
            }
        } catch {
            loadError = .credentialFailure
        }
    }

    private func loadInitialState() {
        do {
            try reload()
        } catch {
            // reload records a non-sensitive error while preserving the prior in-memory state.
        }
    }

    private func validatedCredentials(
        for source: FeedarrSource,
        username: String?,
        password: String?,
        existing: FeedarrCredentials?,
        mayReuseExisting: Bool
    ) throws -> FeedarrCredentials? {
        if source.usesBasicAuth, source.serverURL.scheme != "https" {
            throw FeedarrSourcesManagerError.insecureBasicAuth
        }

        let supplied: FeedarrCredentials?
        switch (username, password) {
        case (nil, nil):
            supplied = nil
        case let (username?, password?):
            do {
                supplied = try FeedarrCredentials(username: username, password: password)
            } catch {
                throw FeedarrSourcesManagerError.incompleteCredentials
            }
        default:
            throw FeedarrSourcesManagerError.incompleteCredentials
        }

        guard source.usesBasicAuth else { return nil }
        if let supplied { return supplied }
        if mayReuseExisting, let existing { return existing }
        throw FeedarrSourcesManagerError.missingCredentials
    }

    private func replaceCredentials(
        _ credentials: FeedarrCredentials?,
        for sourceID: UUID
    ) throws {
        do {
            if let credentials {
                try credentialsStore.setCredentials(credentials, for: sourceID)
            } else {
                try credentialsStore.deleteCredentials(for: sourceID)
            }
        } catch {
            throw FeedarrSourcesManagerError.credentialFailure
        }
    }
}
