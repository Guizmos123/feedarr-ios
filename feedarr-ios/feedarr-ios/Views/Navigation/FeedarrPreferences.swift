import SwiftUI

// AppStorage persists these raw values in the application's UserDefaults.
enum FeedarrAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Système"
        case .light: "Clair"
        case .dark: "Sombre"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static let storageKey = "feedarr.appearance"
}

enum FeedarrDisplayMode: String, CaseIterable, Identifiable {
    case grid, list
    var id: String { rawValue }
    var title: String { self == .grid ? "Grille" : "Liste" }

    static let storageKey = "feedarr.displayMode"
}

// Boolean defaults live at each AppStorage declaration; absent landscape permission is false.
enum FeedarrNavigationPreferences {
    static let minimizesTabBarKey = "feedarr.minimizesTabBar"
    static let allowsLandscapeKey = "feedarr.allowsLandscape"
}

// Stable IDs are shared by persistence, the settings rows and TabView.
enum FeedarrMainTab: String, CaseIterable, Identifiable {
    case top, library, stats
    var id: String { rawValue }
    var title: String {
        switch self {
        case .top: "Top"
        case .library: "Librairie"
        case .stats: "Stats"
        }
    }
    var symbol: String {
        switch self {
        case .top: "flame"
        case .library: "square.grid.2x2"
        case .stats: "chart.bar"
        }
    }
}

struct FeedarrTabConfiguration: RawRepresentable, Equatable {
    static let storageKey = "feedarr.navigation.tabs"
    static let defaultValue = Self(rawValue: "top:1,library:1,stats:1")
    private(set) var order: [FeedarrMainTab]
    private var hidden: Set<FeedarrMainTab>

    init(rawValue: String) {
        order = []
        hidden = []
        for entry in rawValue.split(separator: ",") {
            let parts = entry.split(separator: ":")
            guard parts.count == 2, let tab = FeedarrMainTab(rawValue: String(parts[0])),
                  parts[1] == "0" || parts[1] == "1", !order.contains(tab) else { continue }
            order.append(tab)
            if parts[1] == "0" { hidden.insert(tab) }
        }
        for tab in FeedarrMainTab.allCases where !order.contains(tab) { order.append(tab) }
        if visibleTabs.isEmpty, let first = order.first { hidden.remove(first) }
    }

    var rawValue: String {
        order.map { "\($0.rawValue):\(isVisible($0) ? "1" : "0")" }.joined(separator: ",")
    }
    var visibleTabs: [FeedarrMainTab] { order.filter { !hidden.contains($0) } }
    func isVisible(_ tab: FeedarrMainTab) -> Bool { !hidden.contains(tab) }
    mutating func setVisible(_ visible: Bool, for tab: FeedarrMainTab) {
        if visible { hidden.remove(tab) }
        else if visibleTabs.count > 1 { hidden.insert(tab) }
    }
    mutating func move(from offsets: IndexSet, to destination: Int) {
        order.move(fromOffsets: offsets, toOffset: destination)
    }
}


enum FeedarrSecurityPreferences {
    // Absent preference means disabled. Writes require LocalAuthentication success.
    static let requiresFaceIDKey = "feedarr.security.requiresFaceID"
}
