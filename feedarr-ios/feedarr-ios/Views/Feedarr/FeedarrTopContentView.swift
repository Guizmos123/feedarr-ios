//
//  FeedarrTopView.swift
//  Yattee
//
//  Native Top rails sharing one response and the display options sheet.
//

import Foundation
import SwiftUI
import Observation

struct FeedarrTopContentView: View {
    let model: FeedarrTopModel
    let posterService: FeedarrPosterService
    let isVisible: Bool
    var isManuallyRefreshing = false
    var onSelectRelease: ((FeedarrRelease) -> Void)? = nil
    var onRefresh: (@MainActor @Sendable () async -> Void)? = nil
    @AppStorage(FeedarrDisplayMode.storageKey) private var displayMode: FeedarrDisplayMode = .grid
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.displayScale) private var displayScale
    @State private var entrance = TopEntranceBarrier()

    var body: some View {
        GeometryReader { geometry in
            topContent(entranceDistance: geometry.size.width + 32)
        }
        .coordinateSpace(name: TopCardFrames.coordinateSpace)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { entrance.viewport = CGRect(origin: .zero, size: $0) }
        .onPreferenceChange(TopCardFrames.self) { entrance.frames = $0 }
        .onAppear { model.setVisible(isVisible) }
        .onChange(of: isVisible) { model.setVisible(isVisible) }
        .task(id: EntranceContext(ready: entranceReady, generation: posterService.generation,
                                 revision: model.configurationRevision, sort: model.selectedSort.rawValue,
                                 reduceMotion: reduceMotion)) {
            guard entranceReady else { entrance.cancel(); return }
            await entrance.prepare(generation: posterService.generation, reduceMotion: reduceMotion)
        }
        .onDisappear {
            model.setVisible(false)
            entrance.cancel()
        }
    }

    private struct EntranceContext: Equatable {
        let ready: Bool
        let generation: UUID
        let revision: UUID
        let sort: String
        let reduceMotion: Bool
    }

    private var entranceReady: Bool {
        isVisible && model.currentResponse != nil && !model.isEmpty && !model.isLoading
    }

    private func topContent(entranceDistance: CGFloat) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if model.isLoading && model.response == nil && !isManuallyRefreshing {
                        ProgressView("Chargement du Top…")
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    if let failure = model.failure {
                        ContentUnavailableView {
                            Label("Top indisponible", systemImage: failure == .offline ? "wifi.slash" : "exclamationmark.triangle")
                        } description: {
                            Text(failure.message)
                        } actions: {
                            Button("Réessayer") { model.retry() }
                        }
                    }
                    if model.isEmpty {
                        ContentUnavailableView("Aucun contenu", systemImage: "rectangle.stack",
                                               description: Text("Aucune release sur les dernières 24 heures."))
                    } else {
                        ForEach(model.rails) { rail in
                            railView(rail, entranceDistance: entranceDistance,
                                     sectionIndex: model.rails.filter { !$0.items.isEmpty }.firstIndex(where: { $0.id == rail.id }) ?? 0)
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .refreshable {
                guard isVisible else { return }
                await onRefresh?()
            }
            .scrollBounceBehavior(.always, axes: .vertical)
        }
    }

    private func posterPixels(width: CGFloat) -> Int {
        Int(min(max(ceil(width * 1.5 * displayScale), 1), 1200))
    }

    private func railView(_ rail: FeedarrTopRailContent, entranceDistance: CGFloat, sectionIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(rail.title).font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                if let count = rail.count {
                    Text(count.formatted()).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            if rail.items.isEmpty {
                Text("Aucun contenu dans cette catégorie.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 16)
            } else if displayMode == .list {
                LazyVStack(spacing: 12) {
                    ForEach(Array(rail.items.enumerated()), id: \.element.id) { index, release in
                        FeedarrReleaseRow(release: release, posterService: posterService, onSelectRelease: onSelectRelease)
                            .environment(\.feedarrPosterDisplayWidth, 76)
                            .modifier(TopCardEntrance(ready: entranceReady, reduceMotion: reduceMotion, index: index, sectionIndex: sectionIndex, distance: entranceDistance, card: TopCardID(rail: rail.id, release: release.id), pixels: posterPixels(width: displayMode == .list ? 76 : (sizeClass == .regular ? 168 : 144)), barrier: entrance))
                    }
                }
                .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(rail.items.enumerated()), id: \.element.id) { index, release in
                            FeedarrReleaseCard(release: release, posterService: posterService, onSelectRelease: onSelectRelease)
                                .frame(width: sizeClass == .regular ? 168 : 144, alignment: .topLeading)
                                .environment(\.feedarrPosterDisplayWidth, sizeClass == .regular ? 168 : 144)
                                .modifier(TopCardEntrance(ready: entranceReady, reduceMotion: reduceMotion, index: index, sectionIndex: sectionIndex, distance: entranceDistance, card: TopCardID(rail: rail.id, release: release.id), pixels: posterPixels(width: displayMode == .list ? 76 : (sizeClass == .regular ? 168 : 144)), barrier: entrance))
                        }
                    }
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
            }
        }
    }
}

// Process-local only: consumed synchronously with the first actual slide, or Reduce Motion.
@MainActor
private enum TopEntranceSession {
    static var consumed = false
}

nonisolated private struct TopCardID: Hashable, Sendable {
    let rail: FeedarrTopRail
    let release: Int64
}

nonisolated private struct TopCardFrames: PreferenceKey {
    static let coordinateSpace = "feedarr.top.initialViewport"
    static let defaultValue: [TopCardID: CGRect] = [:]
    static func reduce(value: inout [TopCardID: CGRect], nextValue: () -> [TopCardID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

@MainActor
@Observable
private final class TopEntranceBarrier {
    private(set) var session = UUID()
    private(set) var group: Set<TopCardID>?
    private(set) var departure: ContinuousClock.Instant?
    @ObservationIgnored var viewport = CGRect.zero
    @ObservationIgnored var frames: [TopCardID: CGRect] = [:]
    @ObservationIgnored var mounted: [TopCardID: (section: Int, index: Int)] = [:]
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var states: [TopCardID: FeedarrPosterAvailabilityEvent.State] = [:]
    @ObservationIgnored private var active = false
    @ObservationIgnored private var waiter: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var timeout: Task<Void, Never>?

    func report(_ event: FeedarrPosterAvailabilityEvent, card: TopCardID, pixels: Int) {
        guard active, event.session == session, event.generation == generation,
              event.releaseID == card.release, event.pixels == pixels else { return }
        states[card] = event.state
        releaseIfReady()
    }

    func prepare(generation: UUID, reduceMotion: Bool) async {
        cancel()
        guard !TopEntranceSession.consumed else { return }
        if reduceMotion { TopEntranceSession.consumed = true; return }
        let token = session
        self.generation = generation
        active = true
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(800))
        // Let initial layout and cached-poster callbacks establish the offscreen frame.
        // This is a short layout window, not a fixed image-loading delay.
        do {
            try await Task.sleep(for: .milliseconds(32))
            // If lazy mounting itself is late, wait only within the same global deadline.
            while mounted.isEmpty && ContinuousClock.now < deadline {
                try await ContinuousClock().sleep(until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(16))))
            }
        }
        catch { if session == token { cancel() }; return }
        guard session == token, !Task.isCancelled else { return }
        let visible = Set(frames.compactMap { card, frame -> TopCardID? in
            guard mounted[card] != nil, frame.width > 0, frame.height > 0,
                  frame.minX.isFinite, frame.minY.isFinite, frame.intersects(viewport) else { return nil }
            return card
        })
        if !visible.isEmpty {
            group = visible
        } else {
            // Geometry missing/late: only a bounded initial mounted subset may participate.
            let fallback = mounted.sorted {
                $0.value.section == $1.value.section ? $0.value.index < $1.value.index : $0.value.section < $1.value.section
            }.prefix(4).map(\.key)
            group = Set(fallback)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard session == token, !Task.isCancelled else { continuation.resume(); return }
                waiter = continuation
                timeout = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    guard let self, self.session == token else { return }
                    self.release()
                }
                releaseIfReady()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.session == token else { return }
                self.cancel()
            }
        }
    }

    private func releaseIfReady() {
        guard waiter != nil, let group, group.allSatisfy({ states[$0].map { $0 != .loading } ?? false }) else { return }
        release()
    }
    private func release() {
        guard active, group != nil, departure == nil else { return }
        departure = ContinuousClock.now
        timeout?.cancel()
        timeout = nil
        waiter?.resume()
        waiter = nil
    }
    func cancel() {
        active = false
        timeout?.cancel()
        timeout = nil
        waiter?.resume()
        waiter = nil
        session = UUID()
        group = nil
        departure = nil
        generation = nil
        states = [:]
    }
}

private struct TopCardEntrance: ViewModifier {
    let ready: Bool
    let reduceMotion: Bool
    let index: Int
    let sectionIndex: Int
    let distance: CGFloat
    let card: TopCardID
    let pixels: Int
    let barrier: TopEntranceBarrier
    @State private var offset: CGFloat
    @State private var started = false
    @State private var settled: Bool

    init(ready: Bool, reduceMotion: Bool, index: Int, sectionIndex: Int, distance: CGFloat,
         card: TopCardID, pixels: Int, barrier: TopEntranceBarrier) {
        self.ready = ready
        self.reduceMotion = reduceMotion
        self.index = index
        self.sectionIndex = sectionIndex
        self.distance = distance
        self.card = card
        self.pixels = pixels
        self.barrier = barrier
        let alreadyPlayed = TopEntranceSession.consumed || (barrier.group.map { !$0.contains(card) } ?? false)
        _settled = State(initialValue: alreadyPlayed)
        _offset = State(initialValue: alreadyPlayed || reduceMotion ? 0 : distance)
    }

    func body(content: Content) -> some View {
        let session = barrier.session
        content
            .environment(\.feedarrPosterAvailability, FeedarrPosterAvailabilityReporter(session: session) { event in
                barrier.report(event, card: card, pixels: pixels)
            })
            .offset(x: reduceMotion ? 0 : offset)
            // Background is OUTSIDE the offset: its layout slot stays untransformed.
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: TopCardFrames.self,
                                           value: [card: geometry.frame(in: .named(TopCardFrames.coordinateSpace))])
                }
            }
            .onAppear { barrier.mounted[card] = (sectionIndex, index) }
            .task(id: Trigger(ready: ready, reduceMotion: reduceMotion, distance: distance,
                              session: session, departure: barrier.departure, included: barrier.group?.contains(card))) {
                guard ready else {
                    if started || TopEntranceSession.consumed { settle() }
                    return
                }
                if reduceMotion { TopEntranceSession.consumed = true; settle(); return }
                if TopEntranceSession.consumed && barrier.group == nil { settle(); return }
                // A cancelled preparation can retry before any card has actually departed.
                if !TopEntranceSession.consumed && !started { settled = false }
                guard !settled, !started else { return }
                if let group = barrier.group, !group.contains(card) { settle(); return }
                guard let base = barrier.departure else { setOffset(distance); return }
                do {
                    let departure = base.advanced(by: .milliseconds(sectionIndex * 200 + index * 100))
                    try await ContinuousClock().sleep(until: departure)
                    try Task.checkCancellation()
                } catch { return }
                guard barrier.session == session else { return }
                started = true
                withAnimation(.spring(response: 0.9, dampingFraction: 0.86)) { offset = 0 }
                TopEntranceSession.consumed = true
            }
            .onDisappear {
                barrier.mounted[card] = nil
                if started || TopEntranceSession.consumed { settle() }
            }
    }

    private func settle() { settled = true; setOffset(0) }
    private func setOffset(_ value: CGFloat) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { offset = value }
    }
    private struct Trigger: Equatable {
        let ready: Bool
        let reduceMotion: Bool
        let distance: CGFloat
        let session: UUID
        let departure: ContinuousClock.Instant?
        let included: Bool?
    }
}
