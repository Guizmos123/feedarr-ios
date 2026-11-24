//
//  FeedarrPosterView.swift
//  Yattee
//
//  Reusable poster surface; loading follows the SwiftUI view's task lifetime.
//

import Foundation
import SwiftUI

struct FeedarrPosterView: View {
    let release: FeedarrRelease
    let service: FeedarrPosterService
    var aspectRatio: CGFloat = 2.0 / 3.0
    @Environment(\.feedarrPosterDisplayWidth) private var displayWidth
    @Environment(\.displayScale) private var displayScale
    @Environment(\.feedarrPosterAvailability) private var availabilityReporter

    private var maximumPixelSize: Int {
        guard let width = displayWidth, width.isFinite, width > 0,
              aspectRatio.isFinite, aspectRatio > 0 else { return 1200 }
        let pixels = width * max(1, 1 / aspectRatio) * displayScale
        return Int(min(max(ceil(pixels), 1), 1200))
    }

    @State private var image: Image?
    @State private var loadedGeneration: UUID?
    @State private var failed = false
    @State private var loadedRequest: LoadID?
    @State private var activeRequest: LoadID?

    private var availability: FeedarrPosterAvailabilityEvent {
        let current = LoadID(releaseID: release.id, posterURL: release.posterUrl,
                             generation: service.generation, pixels: maximumPixelSize)
        let state: FeedarrPosterAvailabilityEvent.State
        if release.posterUrl?.isEmpty != false { state = .absent }
        else if image != nil && loadedRequest == current { state = .ready }
        else if failed && activeRequest == current { state = .failed }
        else { state = .loading }
        return FeedarrPosterAvailabilityEvent(releaseID: release.id, generation: service.generation,
                                              pixels: maximumPixelSize, state: state,
                                              session: availabilityReporter?.session)
    }

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(aspectRatio > 0 && aspectRatio.isFinite ? aspectRatio : 2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image, loadedGeneration == service.generation {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: LoadID(releaseID: release.id, posterURL: release.posterUrl, generation: service.generation, pixels: maximumPixelSize)) {
                let requestedPixels = maximumPixelSize
                let request = LoadID(releaseID: release.id, posterURL: release.posterUrl,
                                     generation: service.generation, pixels: requestedPixels)
                activeRequest = request
                image = nil
                loadedGeneration = nil
                loadedRequest = nil
                failed = false
                guard let url = release.posterUrl, !url.isEmpty else { return }
                do {
                    let poster = try await service.image(for: release, maximumPixelSize: requestedPixels)
                    try Task.checkCancellation()
                    #if canImport(UIKit)
                    image = Image(uiImage: poster)
                    #else
                    image = Image(nsImage: poster)
                    #endif
                    loadedGeneration = service.generation
                    loadedRequest = request
                } catch {
                    if !Task.isCancelled { failed = true }
                }
            }
            // Re-emit existing state for a new Top session without restarting image loading.
            .onChange(of: availability, initial: true) { availabilityReporter?.report(availability) }
            .onDisappear { image = nil; loadedGeneration = nil; loadedRequest = nil }
    }

    private struct LoadID: Equatable {
        let releaseID: Int64
        let posterURL: String?
        let generation: UUID
        let pixels: Int
    }
}

// Opt-in only: other screens and detail sheets retain the existing 1200-pixel limit.
nonisolated private struct FeedarrPosterDisplayWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var feedarrPosterDisplayWidth: CGFloat? {
        get { self[FeedarrPosterDisplayWidthKey.self] }
        set { self[FeedarrPosterDisplayWidthKey.self] = newValue }
    }
}

nonisolated struct FeedarrPosterAvailabilityEvent: Equatable, Sendable {
    enum State: Equatable, Sendable { case loading, ready, failed, absent }
    let releaseID: Int64
    let generation: UUID
    let pixels: Int
    let state: State
    let session: UUID?
}

nonisolated struct FeedarrPosterAvailabilityReporter: Sendable {
    let session: UUID
    let report: @MainActor @Sendable (FeedarrPosterAvailabilityEvent) -> Void
}

nonisolated private struct FeedarrPosterAvailabilityKey: EnvironmentKey {
    static let defaultValue: FeedarrPosterAvailabilityReporter? = nil
}

extension EnvironmentValues {
    var feedarrPosterAvailability: FeedarrPosterAvailabilityReporter? {
        get { self[FeedarrPosterAvailabilityKey.self] }
        set { self[FeedarrPosterAvailabilityKey.self] = newValue }
    }
}
