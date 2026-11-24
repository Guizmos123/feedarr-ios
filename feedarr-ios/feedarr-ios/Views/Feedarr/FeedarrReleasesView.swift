//
//  FeedarrReleasesView.swift
//  Yattee
//
//  Poster grid or list, retained between segments and paginated near its end.
//

import Foundation
import SwiftUI

struct FeedarrReleasesView: View {
    let model: FeedarrReleasesModel
    let posterService: FeedarrPosterService
    let isVisible: Bool
    var isManuallyRefreshing = false
    @Binding var isSearchPresented: Bool
    var onSelectRelease: ((FeedarrRelease) -> Void)? = nil
    var onRefresh: (@MainActor @Sendable () async -> Void)? = nil
    @FocusState private var searchFocused: Bool
    @AppStorage(FeedarrDisplayMode.storageKey) private var layout: FeedarrDisplayMode = .grid
    @AppStorage("feedarrReleasesRowStyle") private var rowStyle: FeedarrReleaseRowStyle = .regular
    @AppStorage("feedarrReleasesGridColumns") private var gridColumns = 2
    @AppStorage("feedarrReleasesShowsInformation") private var showsInformation = true
    @State private var scrollID: Int64?

    private var currentItems: [FeedarrRelease] {
        model.isCurrentConfiguration ? model.items : []
    }

    private var columns: [GridItem] {
        let count = layout == .list ? 1 : min(max(2, gridColumns), 4)
        return Array(repeating: GridItem(.flexible(), spacing: showsInformation ? 12 : 6), count: count)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isVisible && isSearchPresented {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Rechercher dans la librairie",
                                  text: Binding(get: { model.searchText }, set: { model.updateSearchText($0) }))
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .focused($searchFocused)
                            .submitLabel(.search)
                            .accessibilityIdentifier("feedarr.releases.searchField")
                            .task { searchFocused = true }
                        if !model.searchText.isEmpty {
                            Button { model.updateSearchText("") } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Effacer la recherche")
                        }
                    }
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    Button("Annuler") {
                        searchFocused = false
                        isSearchPresented = false
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            ScrollView {
                LazyVStack(spacing: 20) {
                    if !isManuallyRefreshing && (model.isLoadingInitial || model.isDebouncing) && model.items.isEmpty {
                        ProgressView("Chargement de la librairie…")
                            .frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                    if model.isEmpty && model.failure == nil {
                        if let query = model.query {
                            ContentUnavailableView.search(text: query)
                        } else {
                            ContentUnavailableView("Aucune release", systemImage: "rectangle.stack")
                        }
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: layout == .grid ? (showsInformation ? 24 : 6) : 12) {
                        ForEach(currentItems) { release in
                            Group {
                                if layout == .grid {
                                    FeedarrReleaseCard(release: release, posterService: posterService, onSelectRelease: onSelectRelease, showsInformation: showsInformation)
                                } else {
                                    FeedarrReleaseRow(release: release, posterService: posterService, style: rowStyle, onSelectRelease: onSelectRelease)
                                }
                            }
                            .onAppear { model.itemAppeared(release.id) }
                        }
                    }
                    .scrollTargetLayout()
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .refreshable {
                guard isVisible else { return }
                await onRefresh?()
            }
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollPosition(id: $scrollID)
            .id(model.catalogGeneration)
        }
        .onChange(of: model.catalogGeneration) { scrollID = nil }
        .onAppear { model.setVisible(isVisible) }
        .onChange(of: isSearchPresented) { if !isSearchPresented { searchFocused = false } }
        .onChange(of: isVisible) {
            if !isVisible { searchFocused = false; isSearchPresented = false }
            model.setVisible(isVisible)
        }
        .onDisappear { searchFocused = false; isSearchPresented = false; model.setVisible(false) }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if let failure = model.failure {
                Label(failure.message, systemImage: failure == .offline ? "wifi.slash" : "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Réessayer") { model.retry() }
                    .buttonStyle(.bordered)
            } else if model.isLoadingNextPage && !isManuallyRefreshing {
                ProgressView("Chargement des releases suivantes…")
            } else if model.isAtEnd && !model.items.isEmpty && !model.isLoadingInitial {
                Text("Toutes les releases ont été chargées.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Color.clear.frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        // Also advances through empty/duplicate-only pages when the footer stays visible.
        .task(id: PageTrigger(cursor: model.nextCursor, visible: isVisible)) {
            if isVisible { model.loadNextPage() }
        }
    }

    private struct PageTrigger: Equatable {
        let cursor: String?
        let visible: Bool
    }
}
