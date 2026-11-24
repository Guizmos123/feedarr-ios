import SwiftUI

struct FeedarrTopView: View {
    let manager: FeedarrSourcesManager
    let syncStatus: FeedarrSyncStatus
    var isVisible = true
    var onOpenSettings: (() -> Void)? = nil
    @State private var model: FeedarrTopModel?
    @State private var posterService: FeedarrPosterService?
    @State private var selection: FeedarrReleaseSelection?
    @State private var showingOptions = false
    @State private var optionsDetent: PresentationDetent = .medium
    @AppStorage(FeedarrDisplayMode.storageKey) private var displayMode: FeedarrDisplayMode = .grid

    var body: some View {
        Group {
            if let error = manager.loadError {
                ContentUnavailableView {
                    Label("Configuration indisponible", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    if let onOpenSettings { Button("Ouvrir les réglages", action: onOpenSettings) }
                }
            } else if manager.sources.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.largeTitle)
                    Text("Aucune source Feedarr configurée")
                        .font(.headline)
                    Text("Ajoutez une source dans les Réglages pour afficher les classements.")
                        .font(.subheadline)
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if let model, let posterService {
                FeedarrTopContentView(
                    model: model, posterService: posterService, isVisible: isVisible,
                    isManuallyRefreshing: syncStatus.isRefreshing,
                    onSelectRelease: { release in
                        guard model.currentResponse != nil, manager.loadError == nil else { return }
                        selection = FeedarrReleaseSelection(
                            release: release, configurationRevision: manager.configurationRevision)
                    },
                    onRefresh: { await refresh(model) }
                )
            } else {
                ProgressView("Chargement du Top…")
            }
        }
        .navigationTitle("Top 24h")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            if model != nil, !manager.sources.isEmpty || manager.loadError != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Options", systemImage: "slider.horizontal.3") {
                        optionsDetent = .medium
                        showingOptions = true
                    }
                    .disabled(manager.loadError != nil)
                }
            }
        }
        .modifier(FeedarrSyncOverlay(status: syncStatus, isVisible: isVisible))
        .onChange(of: model?.selectedSort) { syncStatus.cancel() }
        .task {
            guard model == nil else { return }
            let api = FeedarrAPIClient(sources: manager)
            posterService = FeedarrPosterService(sources: manager)
            model = FeedarrTopModel(sources: manager) { sort in
                try await api.top(hours: 24, take: 5, perCategoryTake: 5, sort: sort)
            }
        }
        .onChange(of: manager.configurationRevision) { selection = nil }
        .sheet(item: $selection) { selection in
            if let posterService {
                FeedarrReleaseDetailSheet(selection: selection, posterService: posterService, manager: manager)
            }
        }
        .sheet(isPresented: $showingOptions) {
            NavigationStack {
                Form {
                    Section("Affichage") {
                        Picker("Présentation", selection: $displayMode) {
                            ForEach(FeedarrDisplayMode.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    }
                    if let model {
                        Section("Classement") {
                            Picker("Trier le Top", selection: Binding(
                                get: { model.selectedSort }, set: { model.selectSort($0) }
                            )) {
                                ForEach([FeedarrTopSort.score, .recent, .seeders, .grabs]) { sort in
                                    Text(sort.localizedTitle).tag(sort)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Options")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fermer", systemImage: "xmark") { showingOptions = false }
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .presentationDetents([.medium, .large], selection: $optionsDetent)
            .presentationDragIndicator(.visible)
        }
    }

    private func refresh(_ model: FeedarrTopModel) async {
        guard isVisible, !model.isLoading else { return }
        let revision = manager.configurationRevision
        let sort = model.selectedSort
        await syncStatus.refresh(isValid: {
            manager.configurationRevision == revision && manager.loadError == nil
        }) {
            await model.refresh()
            guard sort == model.selectedSort, !model.isLoading else { return .obsolete }
            if let failure = model.failure { return .failure(failure.message) }
            return model.currentResponse == nil ? .obsolete : .success
        }
    }

}
