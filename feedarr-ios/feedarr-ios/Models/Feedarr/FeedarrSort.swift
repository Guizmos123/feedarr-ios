//
//  FeedarrSort.swift
//  Yattee
//
//  Distinct API sort values and explicit client defaults for each Feedarr page.
//

import Foundation

nonisolated enum FeedarrTopSort: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case recent
    case seeders
    case grabs
    case score

    /// XTubee's choice; the backend defaults to recent when the parameter is omitted.
    static let defaultSort: Self = .score
    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .recent: "Récent"
        case .seeders: "Seeders"
        case .grabs: "Téléchargements"
        case .score: "Score"
        }
    }
}

nonisolated enum FeedarrReleasesSort: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case date
    case seeders
    case grabs
    case score

    static let defaultSort: Self = .date
    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .date: "Date"
        case .seeders: "Seeders"
        case .grabs: "Téléchargements"
        case .score: "Score"
        }
    }
}
