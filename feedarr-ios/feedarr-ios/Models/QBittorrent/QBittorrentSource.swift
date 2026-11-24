import Foundation

/// Non-sensitive metadata only. Credentials and cookies are never encoded here.
nonisolated struct QBittorrentSource: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let serverURL: URL
    let dateAdded: Date

    init(id: UUID = UUID(), name: String, serverURL: String, dateAdded: Date = Date()) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw QBittorrentError.invalidName }
        self.id = id
        self.name = name
        self.serverURL = try QBittorrentServerURL.normalize(serverURL)
        self.dateAdded = dateAdded
    }

    private enum CodingKeys: String, CodingKey { case id, name, serverURL, dateAdded }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id),
                      name: values.decode(String.self, forKey: .name),
                      serverURL: values.decode(String.self, forKey: .serverURL),
                      dateAdded: values.decode(Date.self, forKey: .dateAdded))
    }
}
