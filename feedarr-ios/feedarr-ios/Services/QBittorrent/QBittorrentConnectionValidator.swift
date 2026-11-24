import Foundation

nonisolated struct QBittorrentServerVersions: Equatable, Sendable {
    let application: String
    let api: String

    init(application: Data, api: Data) throws {
        guard let app = String(data: application, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let api = String(data: api, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              app.range(of: #"^v?(4\.6\.[0-9]+|5\.[0-9]+\.[0-9]+)([a-zA-Z][a-zA-Z0-9.-]*)?$"#,
                        options: .regularExpression) != nil,
              api.range(of: #"^2\.[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else {
            throw QBittorrentError.incompatibleServer
        }
        self.application = app
        self.api = api
    }
}

/// Only the validator can mint a successful configuration. The manager saves exactly this snapshot.
nonisolated struct QBittorrentValidatedConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let source: QBittorrentSource
    let versions: QBittorrentServerVersions
    let credentials: QBittorrentCredentials
    fileprivate init(source: QBittorrentSource, credentials: QBittorrentCredentials, versions: QBittorrentServerVersions) {
        self.source = source
        self.credentials = credentials
        self.versions = versions
    }
    var description: String { "QBittorrentValidatedConfiguration(redacted)" }
    var debugDescription: String { description }
}

nonisolated struct QBittorrentConnectionValidator: Sendable {
    private let makeTransport: @Sendable () -> any QBittorrentHTTPTransport
    private let loginGate: QBittorrentLoginGate

    init(loginGate: QBittorrentLoginGate = .shared,
         makeTransport: @escaping @Sendable () -> any QBittorrentHTTPTransport = { QBittorrentURLSessionTransport() }) {
        self.loginGate = loginGate
        self.makeTransport = makeTransport
    }

    func validate(source: QBittorrentSource, credentials: QBittorrentCredentials) async throws -> QBittorrentValidatedConfiguration {
        let session = QBittorrentSession(baseURL: source.serverURL, credentials: credentials,
                                        transport: makeTransport(), loginGate: loginGate)
        do {
            let versions = try await session.versions()
            await session.invalidate()
            try Task.checkCancellation()
            return QBittorrentValidatedConfiguration(source: source, credentials: credentials, versions: versions)
        } catch {
            await session.invalidate()
            throw error
        }
    }
}
