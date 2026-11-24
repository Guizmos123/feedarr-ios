import Foundation

/// Independent of FeedarrAPIClient. Future endpoints share this source/revision boundary.
@MainActor
final class QBittorrentAPIClient {
    private let sources: QBittorrentSourcesManager

    init(sources: QBittorrentSourcesManager) { self.sources = sources }

    func activeServerVersions() async throws -> QBittorrentServerVersions {
        guard let source = sources.source else { throw QBittorrentError.sourceNotFound }
        let revision = sources.configurationRevision
        let session = try sources.session(for: source)
        do {
            let result = try await session.versions()
            try Task.checkCancellation()
            try validate(source: source, revision: revision)
            return result
        } catch {
            try Task.checkCancellation()
            try validate(source: source, revision: revision)
            throw error
        }
    }

    private func validate(source: QBittorrentSource, revision: UUID) throws {
        guard sources.configurationRevision == revision, sources.source == source, sources.loadError == nil else {
            throw QBittorrentError.obsoleteResponse
        }
    }
}
