import Foundation

// Minimal projections of SystemApiCore.Stats; omitted server fields stay unavailable.
nonisolated struct FeedarrStatsSummary: Decodable, Sendable {
    let version: String?
    let uptimeSeconds: Int64?
    let activeIndexers: Int?
    let releasesCount: Int?
    let matchingPercent: Int?
}

nonisolated struct FeedarrStatsOverview: Decodable, Sendable {
    let releasesCount: Int?
    let releasesWithPoster: Int?
    let matchingPercent: Int?
    let sonarrMatchedCount: Int?
    let radarrMatchedCount: Int?
    let releasesPerDay: [Day]?
    let arrApps: [ArrApp]?

    struct Day: Decodable, Identifiable, Sendable {
        let date: String
        let count: Int
        var id: String { date }
        var timestamp: Date? {
            // Backend date(created_at_ts, 'unixepoch') is a UTC calendar day.
            ISO8601DateFormatter().date(from: date + "T00:00:00Z")
        }
    }
    struct ArrApp: Decodable, Identifiable, Sendable {
        let id: Int64
        let name: String
        let type: String
        let enabled: Bool
        let libraryCount: Int?
        let lastSyncAt: String?
        let lastSyncCount: Int?
    }
}

nonisolated struct FeedarrStatsReleases: Decodable, Sendable {
    let withPoster: Int?
    let releasesByCategory: [Category]?
    struct Category: Decodable, Identifiable, Sendable {
        let key: String
        let label: String
        let count: Int
        var id: String { key }
    }
}

// GET /api/system/status: intentionally discard all unrelated status fields.
nonisolated struct FeedarrSystemStatus: Decodable, Sendable {
    let lastSyncAtTs: Int64?
}
