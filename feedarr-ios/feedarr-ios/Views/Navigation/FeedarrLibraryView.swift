import SwiftUI

struct FeedarrLibraryView: View {
    let manager: FeedarrSourcesManager
    let syncStatus: FeedarrSyncStatus
    var isVisible = true
    @State private var model: FeedarrReleasesModel?
    @State private var posterService: FeedarrPosterService?
    @State private var selection: FeedarrReleaseSelection?
    @State private var showingSearch = false
    @State private var showingFilters = false
    @State private var optionsDetent: PresentationDetent = .medium
    @AppStorage(FeedarrDisplayMode.storageKey) private var layout: FeedarrDisplayMode = .grid
    @AppStorage("feedarrReleasesRowStyle") private var rowStyle: FeedarrReleaseRowStyle = .regular
    @AppStorage("feedarrReleasesGridColumns") private var gridColumns = 2
    @AppStorage("feedarrReleasesShowsInformation") private var showsInformation = true

    var body: some View {
        Group {
            if let error = manager.loadError {
                ContentUnavailableView("Configuration indisponible", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            } else if let model, let posterService {
                FeedarrReleasesView(
                    model: model, posterService: posterService, isVisible: isVisible,
                    isManuallyRefreshing: syncStatus.isRefreshing,
                    isSearchPresented: $showingSearch,
                    onSelectRelease: { release in
                        guard model.isCurrentConfiguration, manager.loadError == nil else { return }
                        selection = FeedarrReleaseSelection(
                            release: release, configurationRevision: manager.configurationRevision)
                    },
                    onRefresh: { await refresh(model) }
                )
            } else {
                ProgressView("Chargement de la librairie…")
            }
        }
        .navigationTitle("Librairie")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            if let model {
                ToolbarItem(placement: .primaryAction) {
                    Button("Filtres et affichage", systemImage: model.hasActiveFilters ? "slider.horizontal.3.circle.fill" : "slider.horizontal.3") {
                        optionsDetent = .medium
                        showingFilters = true
                    }
                }
            }
        }
        .modifier(FeedarrSyncOverlay(status: syncStatus, isVisible: isVisible))
        .onChange(of: model?.query) { syncStatus.cancel() }
        .onChange(of: model?.selectedSort) { syncStatus.cancel() }
        .onChange(of: model?.selectedCategory) { syncStatus.cancel() }
        .task {
            guard model == nil else { return }
            let api = FeedarrAPIClient(sources: manager)
            posterService = FeedarrPosterService(sources: manager)
            model = FeedarrReleasesModel(sources: manager) { query, cursor, sort, category in
                try await api.releases(limit: 50, sort: sort, q: query,
                                       unifiedCategory: category?.rawValue, cursor: cursor)
            }
        }
        .onChange(of: manager.configurationRevision) { selection = nil }
        .sheet(item: $selection) { selection in
            if let posterService {
                FeedarrReleaseDetailSheet(selection: selection, posterService: posterService, manager: manager)
            }
        }
        .sheet(isPresented: $showingFilters) {
            NavigationStack {
                if let model { optionsForm(model) }
            }
            .presentationDetents([.medium, .large], selection: $optionsDetent)
            .presentationDragIndicator(.visible)
        }
    }

    private func refresh(_ model: FeedarrReleasesModel) async {
        guard isVisible, !model.isLoading else { return }
        let revision = manager.configurationRevision
        let filters = (model.query, model.selectedSort, model.selectedCategory)
        await syncStatus.refresh(isValid: {
            manager.configurationRevision == revision && manager.loadError == nil
        }) {
            await model.refresh()
            guard filters == (model.query, model.selectedSort, model.selectedCategory),
                  !model.isLoadingInitial, model.isCurrentConfiguration else { return .obsolete }
            if let failure = model.failure { return .failure(failure.message) }
            return model.hasLoadedInitial ? .success : .obsolete
        }
    }

    private func optionsForm(_ model: FeedarrReleasesModel) -> some View {
        Form {
            Section("Affichage") {
                Picker("Présentation", selection: $layout) {
                    ForEach(FeedarrDisplayMode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                if layout == .grid {
                    Stepper("Colonnes : \(min(max(2, gridColumns), 4))",
                            value: Binding(get: { min(max(2, gridColumns), 4) }, set: { gridColumns = $0 }),
                            in: 2...4)
                    Toggle("Afficher les informations", isOn: $showsInformation)
                } else {
                    Picker("Taille des lignes", selection: $rowStyle) {
                        ForEach(FeedarrReleaseRowStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                }
            }
            Section("Filtres") {
                Picker("Tri", selection: Binding(
                    get: { model.selectedSort }, set: { model.selectSort($0) }
                )) {
                    ForEach(FeedarrReleasesSort.allCases) { sort in
                        Text(sort.localizedTitle).tag(sort)
                    }
                }
                Picker("Catégorie", selection: Binding(
                    get: { model.selectedCategory }, set: { model.selectCategory($0) }
                )) {
                    Text("Toutes les catégories").tag(Optional<FeedarrTopCategory>.none)
                    ForEach(FeedarrTopCategory.railOrder) { category in
                        Text(category.localizedTitle).tag(Optional(category))
                    }
                }
            }
        }
        .navigationTitle("Filtres et affichage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fermer", systemImage: "xmark") { showingFilters = false }
                    .labelStyle(.iconOnly)
            }
        }
    }
}
