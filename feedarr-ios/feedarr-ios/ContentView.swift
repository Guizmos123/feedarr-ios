import SwiftUI

struct ContentView: View {
    @AppStorage(FeedarrAppearance.storageKey) private var appearance: FeedarrAppearance = .system
    @State private var sources = FeedarrSourcesManager()
    @State private var qbittorrentSources = QBittorrentSourcesManager()
    @State private var hasPresentedContent = false
    private let security = FeedarrAppSecurity.shared

    private var canPresentContent: Bool {
        !security.isLocked && (!security.isEnabled || security.isForegroundActive)
    }

    var body: some View {
        Group {
            // Defer the initial page tasks/Top entrance until the first successful unlock.
            // Afterwards keep the same hierarchy alive beneath the security window.
            if hasPresentedContent || canPresentContent {
                FeedarrTabView(manager: sources, qbittorrentSources: qbittorrentSources)
            } else {
                Color(uiColor: .systemBackground)
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .onChange(of: canPresentContent, initial: true) {
            if canPresentContent { hasPresentedContent = true }
        }
    }
}
