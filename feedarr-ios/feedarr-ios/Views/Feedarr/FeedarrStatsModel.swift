import Foundation
import Observation

@MainActor
@Observable
final class FeedarrStatsModel {
    private(set) var revision: UUID
    private(set) var status: FeedarrSystemStatus?
    private(set) var summary: FeedarrStatsSummary?
    private(set) var releases: FeedarrStatsReleases?
    private(set) var overviews: [Int: FeedarrStatsOverview] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var isLoading = false
    @ObservationIgnored private let manager: FeedarrSourcesManager
    @ObservationIgnored private let api: FeedarrAPIClient
    @ObservationIgnored private var expirations: [String: Date] = [:]
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token = UUID()

    init(manager: FeedarrSourcesManager) {
        self.manager = manager
        api = FeedarrAPIClient(sources: manager)
        revision = manager.configurationRevision
    }

    func load(days: Int, force: Bool = false) async {
        cancel()
        if revision != manager.configurationRevision {
            revision = manager.configurationRevision
            status = nil; summary = nil; releases = nil; overviews = [:]
            errors = [:]; expirations = [:]; retryAfter = [:]
        }
        guard manager.source != nil, manager.loadError == nil else { return }
        let id = token
        let periodKey = "feedarr-\(days)"
        isLoading = true
        let flight = Task { [weak self] in
            guard let self else { return }
            defer { if self.token == id { self.isLoading = false; self.task = nil } }
            // Sequential requests limit bursts against the stats-heavy rate limiter.
            if self.shouldFetch("summary", force: force) {
                do {
                    let value = try await self.api.statsSummary()
                    guard self.accepts(id) else { return }
                    self.summary = value
                    self.succeeded("summary")
                } catch { if self.accepts(id) { self.failed("summary", error) } }
            }
            guard self.accepts(id) else { return }
            if self.shouldFetch("status", force: force) {
                do {
                    let value = try await self.api.systemStatus()
                    guard self.accepts(id) else { return }
                    self.status = value
                    self.succeeded("status")
                } catch { if self.accepts(id) { self.failed("status", error) } }
            }
            guard self.accepts(id) else { return }
            if self.shouldFetch(periodKey, force: force) {
                do {
                    let value = try await self.api.statsFeedarr(days: days)
                    guard self.accepts(id) else { return }
                    self.overviews[days] = value
                    self.succeeded(periodKey)
                } catch { if self.accepts(id) { self.failed(periodKey, error) } }
            }
            guard self.accepts(id) else { return }
            if self.shouldFetch("releases", force: force) {
                do {
                    let value = try await self.api.statsReleases()
                    guard self.accepts(id) else { return }
                    self.releases = value
                    self.succeeded("releases")
                } catch { if self.accepts(id) { self.failed("releases", error) } }
            }
        }
        task = flight
        await withTaskCancellationHandler { await flight.value } onCancel: { flight.cancel() }
    }

    func cancel() {
        token = UUID()
        task?.cancel()
        task = nil
        isLoading = false
    }

    private func accepts(_ id: UUID) -> Bool {
        !Task.isCancelled && token == id && revision == manager.configurationRevision && manager.loadError == nil
    }
    private func shouldFetch(_ key: String, force: Bool) -> Bool {
        if let retry = retryAfter[key], retry > Date() { return false }
        return force || (expirations[key] ?? .distantPast) <= Date()
    }
    private func succeeded(_ key: String) {
        expirations[key] = Date().addingTimeInterval(300)
        retryAfter[key] = nil
        errors[key] = nil
    }
    private func failed(_ key: String, _ error: Error) {
        var delay: TimeInterval = 30
        let message: String
        switch error {
        case FeedarrAPIError.http(.rateLimited(let seconds), _), FeedarrAPIError.transport(.rateLimited(let seconds)):
            delay = max(30, Double(seconds ?? 60))
            message = "Serveur sollicité : réessayez dans quelques instants."
        case FeedarrAPIError.http(.notFound, _):
            message = "Statistiques indisponibles sur cette version du serveur."
        case FeedarrAPIError.http(.unauthorized, _), FeedarrAPIError.http(.forbidden, _),
             FeedarrAPIError.credentialsMissing, FeedarrAPIError.credentialsUnavailable:
            message = "Vérifiez l’authentification du serveur dans Réglages."
        default:
            message = "Impossible de charger ces statistiques. Vérifiez le serveur puis réessayez."
        }
        errors[key] = message
        retryAfter[key] = Date().addingTimeInterval(delay)
    }
}
