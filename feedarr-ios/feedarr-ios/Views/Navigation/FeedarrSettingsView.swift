import SwiftUI

struct FeedarrSettingsView: View {
    let manager: FeedarrSourcesManager
    let qbittorrentSources: QBittorrentSourcesManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FeedarrAppearance.storageKey) private var appearance: FeedarrAppearance = .system
    @AppStorage(FeedarrNavigationPreferences.minimizesTabBarKey) private var minimizesTabBar = true
    @AppStorage(FeedarrNavigationPreferences.allowsLandscapeKey) private var allowsLandscape = false
    // Mirrors XTubee's iOS SettingsView: native list sections and navigation labels.
    var body: some View {
        List {
            Section {
                NavigationLink {
                    sourcesSettings
                } label: {
                    Label("Sources", systemImage: "server.rack")
                }
            }
            Section {
                NavigationLink {
                    Form {
                        Picker("Thème", selection: $appearance) {
                            ForEach(FeedarrAppearance.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        Toggle("Réduire la barre d'onglets", isOn: $minimizesTabBar)
                        Toggle("Autoriser le mode paysage", isOn: $allowsLandscape)
                    }
                    .navigationTitle("Apparence")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Apparence", systemImage: "paintbrush")
                }
                NavigationLink {
                    FeedarrNavigationSettingsView()
                } label: {
                    Label("Navigation", systemImage: "hand.tap")
                }
                NavigationLink {
                    FeedarrSecuritySettingsView()
                } label: {
                    Label("Sécurité", systemImage: "lock.shield")
                }
                NavigationLink {
                    FeedarrActivitySettingsView()
                } label: {
                    Label("Historique d’activité", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink {
                    Form {
                        Text("Aucun réglage disponible pour le moment.")
                            .foregroundStyle(.secondary)
                    }
                    .navigationTitle("Téléchargements")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Téléchargements", systemImage: "arrow.down.circle")
                }
            }
            Section {
                NavigationLink {
                    Form {
                        LabeledContent("Application", value: appName)
                        LabeledContent("Version", value: appVersion)
                    }
                    .navigationTitle("À propos")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("À propos", systemImage: "info.circle")
                }
            }
        }
        .tint(.blue)
        .navigationTitle("Réglages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(role: .cancel) { dismiss() } label: {
                    Label("Fermer", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
            }
        }
        .preferredColorScheme(appearance.colorScheme)
    }

    private var sourcesSettings: some View {
        List {
            Section {
                NavigationLink {
                    FeedarrServersView(manager: manager)
                } label: {
                    Label("Feedarr", systemImage: "server.rack")
                }
                NavigationLink {
                    QBittorrentServersView(manager: qbittorrentSources)
                } label: {
                    Label("qBittorrent", systemImage: "server.rack")
                }
            }
        }
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Feedarr"
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

// XTubee TabBarSettingsView: native list, visibility toggles and always-active move handles.
private struct FeedarrNavigationSettingsView: View {
    @AppStorage(FeedarrTabConfiguration.storageKey) private var configuration = FeedarrTabConfiguration.defaultValue

    var body: some View {
        List {
            Section {
                ForEach(configuration.order) { tab in
                    HStack {
                        Image(systemName: tab.symbol)
                            .frame(width: 24)
                            .foregroundStyle(.secondary)
                        Text(tab.title)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { configuration.isVisible(tab) },
                            set: { visible in
                                var updated = configuration
                                updated.setVisible(visible, for: tab)
                                configuration = updated
                            }
                        ))
                        .labelsHidden()
                        .accessibilityLabel(tab.title)
                        .disabled(configuration.isVisible(tab) && configuration.visibleTabs.count == 1)
                    }
                }
                .onMove { offsets, destination in
                    var updated = configuration
                    updated.move(from: offsets, to: destination)
                    configuration = updated
                }
            } footer: {
                Text("Conservez au moins un onglet principal. Recherche reste toujours accessible à droite.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Navigation")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FeedarrActivitySettingsView: View {
    private let store = FeedarrActivityStore.shared
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section {
                Button("Effacer l’historique", role: .destructive) { confirmingClear = true }
                    .disabled(store.history.isEmpty)
            } footer: {
                Text("Historique local limité aux 500 derniers événements sur 90 jours. L’effacement réinitialise aussi les compteurs locaux.")
            }
        }
        .navigationTitle("Historique d’activité")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Effacer tout l’historique local ?", isPresented: $confirmingClear,
                            titleVisibility: .visible) {
            Button("Effacer l’historique", role: .destructive) { store.clear() }
            Button("Annuler", role: .cancel) {}
        }
    }
}
