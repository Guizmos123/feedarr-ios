import SwiftUI

struct FeedarrSearchView: View {
    let manager: FeedarrSourcesManager
    var isVisible = true
    @State private var query = ""
    @State private var model: FeedarrReleasesModel?
    @State private var posterService: FeedarrPosterService?
    @State private var selection: FeedarrReleaseSelection?

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if !hasQuery {
                ContentUnavailableView(
                    "Rechercher dans Feedarr", systemImage: "magnifyingglass",
                    description: Text("La recherche de contenus sera disponible prochainement.")
                )
            } else if let error = manager.loadError {
                ContentUnavailableView("Configuration indisponible", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            } else if let model, let posterService {
                FeedarrReleasesView(
                    model: model, posterService: posterService, isVisible: isVisible && hasQuery,
                    isSearchPresented: .constant(false),
                    onSelectRelease: { release in
                        guard model.isCurrentConfiguration, manager.loadError == nil else { return }
                        selection = FeedarrReleaseSelection(
                            release: release, configurationRevision: manager.configurationRevision)
                    },
                    onRefresh: {
                        guard isVisible, hasQuery else { return }
                        await model.refresh()
                    }
                )
            }
        }
        .navigationTitle("Recherche")
        .searchable(text: Binding(get: { query }, set: { text in
            query = text
            // Stop the model before clearing q so an empty search never loads the catalogue.
            if !hasQuery { model?.setVisible(false) }
            model?.updateSearchText(text)
            model?.setVisible(isVisible && hasQuery)
        }), prompt: "Rechercher un contenu")
        .task {
            guard model == nil else { return }
            let api = FeedarrAPIClient(sources: manager)
            let releases = FeedarrReleasesModel(sources: manager) { query, cursor, sort, category in
                try await api.releases(limit: 50, sort: sort, q: query,
                                       unifiedCategory: category?.rawValue, cursor: cursor)
            }
            releases.updateSearchText(query)
            posterService = FeedarrPosterService(sources: manager)
            model = releases
            releases.setVisible(isVisible && hasQuery)
        }
        .onChange(of: isVisible) { model?.setVisible(isVisible && hasQuery) }
        .onDisappear { model?.setVisible(false) }
        .onChange(of: manager.configurationRevision) { selection = nil }
        .sheet(item: $selection) { selection in
            if let posterService {
                FeedarrReleaseDetailSheet(selection: selection, posterService: posterService, manager: manager)
            }
        }
    }
}
