import Foundation

// Isolated from XTubee’s detail sheet; no downloads or application environment.
nonisolated struct FeedarrReleaseDetailMetadata: Sendable {
    let release: FeedarrRelease

    struct Row: Identifiable, Equatable, Sendable {
        let id: String
        let value: String
    }

    var title: String? { nonBlank(release.title) ?? nonBlank(release.titleClean) }
    var overview: String? { nonBlank(release.overview) }

    var releaseRows: [Row] {
        var rows: [Row] = []
        func add(_ key: String, _ value: String?) {
            if let value = nonBlank(value) { rows.append(Row(id: "feedarr.detail." + key, value: value)) }
        }
        if nonBlank(release.titleClean) != title { add("cleanTitle", release.titleClean) }
        add("year", release.year.flatMap { $0 > 0 ? $0.formatted(.number.grouping(.never)) : nil })
        add("category", [release.unifiedCategoryLabel, release.unifiedCategory, release.categoryName, release.unifiedCategoryKey].compactMap(nonBlank).first)
        add("season", release.season.flatMap { $0 >= 0 ? $0.formatted() : nil })
        add("episode", release.episode.flatMap { $0 >= 0 ? $0.formatted() : nil })
        add("resolution", release.resolution)
        add("codec", release.codec)
        add("source", release.source)
        add("group", release.releaseGroup)
        if let size = release.sizeBytes, size >= 0 {
            add("size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let timestamp = release.publishedAt, timestamp >= 0,
           Double(timestamp) <= Date.distantFuture.timeIntervalSince1970 {
            add("published", Date(timeIntervalSince1970: Double(timestamp)).formatted(date: .abbreviated, time: .shortened))
        }
        return rows
    }

    var mediaRows: [Row] {
        var rows: [Row] = []
        if let rating = release.rating, rating.isFinite, rating >= 0 {
            rows.append(Row(id: "feedarr.detail.rating", value: rating.formatted(.number.precision(.fractionLength(0...1)))))
        }
        if let votes = release.ratingVotes, votes >= 0 {
            rows.append(Row(id: "feedarr.detail.votes", value: votes.formatted()))
        }
        if let genres = nonBlank(release.genres) { rows.append(Row(id: "feedarr.detail.genres", value: genres)) }
        if let duration = release.runtimeMinutes, duration > 0 {
            rows.append(Row(id: "feedarr.detail.runtime", value: duration.formatted()))
        }
        if let date = nonBlank(release.releaseDate) { rows.append(Row(id: "feedarr.detail.releaseDate", value: date)) }
        return rows
    }

    var statisticsRows: [Row] {
        [("seeders", release.seeders), ("leechers", release.leechers), ("grabs", release.grabs)].compactMap { key, count in
            guard let count, count >= 0 else { return nil }
            return Row(id: "feedarr.detail." + key, value: count.formatted())
        }
    }

    private func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
