import SwiftUI

struct FeedarrTabView: View {
    let manager: FeedarrSourcesManager
    let qbittorrentSources: QBittorrentSourcesManager
    @AppStorage(FeedarrNavigationPreferences.minimizesTabBarKey) private var minimizesTabBar = true
    @State private var syncStatus = FeedarrSyncStatus()
    @AppStorage(FeedarrTabConfiguration.storageKey) private var configuration = FeedarrTabConfiguration.defaultValue
    @State private var selectedTab: Destination
    @State private var showingSettings = false
    @Namespace private var settingsTransition

    private enum Destination: Hashable {
        case main(FeedarrMainTab), search
    }

    init(manager: FeedarrSourcesManager, qbittorrentSources: QBittorrentSourcesManager) {
        self.manager = manager
        self.qbittorrentSources = qbittorrentSources
        let saved = UserDefaults.standard.string(forKey: FeedarrTabConfiguration.storageKey)
            ?? FeedarrTabConfiguration.defaultValue.rawValue
        let first = FeedarrTabConfiguration(rawValue: saved).visibleTabs.first ?? .top
        _selectedTab = State(initialValue: .main(first))
    }

    var body: some View {
        // System rendering provides Liquid Glass and the separate search control.
        TabView(selection: $selectedTab) {
            ForEach(configuration.order) { tab in
                Tab(tab.title, systemImage: tab.symbol, value: Destination.main(tab)) {
                    NavigationStack {
                        mainPage(tab)
                            .toolbar {
                                if tab == configuration.visibleTabs.first {
                                    ToolbarItem(placement: .topBarPinnedTrailing) {
                                        Button { showingSettings = true } label: {
                                            Label("Réglages", systemImage: "gear")
                                                .labelStyle(.iconOnly)
                                                .font(.system(size: 17, weight: .regular))
                                                .foregroundStyle(.tint)
                                                .frame(width: 44, height: 44)
                                                .contentShape(Circle())
                                        }
                                        .buttonStyle(.plain)
                                        .glassEffect(.regular.interactive(), in: .circle)
                                        .matchedTransitionSource(id: "settings", in: settingsTransition)
                                    }
                                    // The button supplies its own glass; never join Options' background.
                                    .sharedBackgroundVisibility(.hidden)
                                }
                            }
                    }
                }
                // Keep each tab's identity and page state when hiding or reordering it.
                .hidden(!configuration.isVisible(tab))
            }
            Tab(value: Destination.search, role: .search) {
                NavigationStack {
                    FeedarrSearchView(manager: manager, isVisible: selectedTab == .search)
                }
            } label: {
                Label("Recherche", systemImage: "magnifyingglass")
            }
        }
        .onChange(of: configuration) {
            if case .main(let tab) = selectedTab, !configuration.isVisible(tab),
               let first = configuration.visibleTabs.first {
                selectedTab = .main(first)
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { FeedarrSettingsView(manager: manager, qbittorrentSources: qbittorrentSources) }
                .navigationTransition(.zoom(sourceID: "settings", in: settingsTransition))
        }
        .onChange(of: selectedTab) { syncStatus.cancel() }
        .onChange(of: manager.configurationRevision) { syncStatus.cancel() }
        .onDisappear { syncStatus.cancel() }
        .tabBarMinimizeBehavior(minimizesTabBar ? .onScrollDown : .never)
        .tabViewSearchActivation(.searchTabSelection)
    }

    @ViewBuilder
    private func mainPage(_ tab: FeedarrMainTab) -> some View {
        switch tab {
        case .top:
            FeedarrTopView(manager: manager, syncStatus: syncStatus, isVisible: selectedTab == .main(.top),
                           onOpenSettings: configuration.visibleTabs.first == .top ? { showingSettings = true } : nil)
        case .library:
            FeedarrLibraryView(manager: manager, syncStatus: syncStatus, isVisible: selectedTab == .main(.library))
        case .stats:
            FeedarrStatsView(manager: manager, isVisible: selectedTab == .main(.stats))
        }
    }

}
