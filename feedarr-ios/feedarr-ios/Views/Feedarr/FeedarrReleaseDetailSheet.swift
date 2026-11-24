import SwiftUI
import UIKit
import SafariServices
import CoreGraphics

struct FeedarrReleaseSelection: Identifiable {
    let release: FeedarrRelease
    let configurationRevision: UUID
    var id: String { configurationRevision.uuidString + ":" + String(release.id) }

    @MainActor
    func isCurrent(sources: FeedarrSourcesManager?) -> Bool {
        guard let sources else { return false }
        return sources.source != nil && sources.loadError == nil && sources.configurationRevision == configurationRevision
    }

    @MainActor
    func downloadTorrent(sources: FeedarrSourcesManager,
                         using download: @MainActor () async throws -> FeedarrTorrentResult) async throws -> FeedarrTorrentResult {
        try Task.checkCancellation()
        guard isCurrent(sources: sources) else { throw FeedarrAPIError.obsoleteResponse }
        let result = try await download()
        guard !Task.isCancelled, isCurrent(sources: sources) else {
            if case .file(let url) = result { FeedarrTorrentService.cleanUp(url) }
            if Task.isCancelled { throw CancellationError() }
            throw FeedarrAPIError.obsoleteResponse
        }
        return result
    }
}

/// XTubee's artwork ambience and card presentation, with validated external links and native torrent sharing.
struct FeedarrReleaseDetailSheet: View {
    let selection: FeedarrReleaseSelection
    let posterService: FeedarrPosterService
    let manager: FeedarrSourcesManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var didRecordOpening = false
    @State private var downloadActivity: FeedarrActivityDownload?
    @State private var tracker: FeedarrTracker?
    @State private var externalLinkTask: Task<Void, Never>?
    @State private var externalLinkRejected = false
    @State private var informationPage: FeedarrInformationPage?
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadToken = UUID()
    @State private var torrentExport: FeedarrTorrentExport?
    @State private var presentedTorrentExport: FeedarrTorrentExport?
    private var showingExport: Bool { presentedTorrentExport != nil }
    @State private var magnetLink: String?
    @State private var showingMagnet = false
    @State private var downloadFailed = false
    @State private var downloadErrorMessage: String?
    @State private var posterImage: UIImage?
    @State private var posterFailed = false
    @State private var artworkAccent: FeedarrArtworkAccent?
    @State private var artworkBackground: Image?

    private var release: FeedarrRelease { selection.release }
    private var metadata: FeedarrReleaseDetailMetadata { FeedarrReleaseDetailMetadata(release: release) }
    private var isCurrent: Bool {
        selection.isCurrent(sources: manager)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if isCurrent {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(alignment: .top, spacing: 16) {
                            poster
                            VStack(alignment: .leading, spacing: 12) {
                                primaryInformation
                                Spacer(minLength: 0)
                                HStack {
                                    Spacer(minLength: 0)
                                    informationAction
                                    downloadAction
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: (sizeClass == .regular ? 180 : 125) * 1.5,
                                   alignment: .topLeading)
                        }
                        releaseInformation
                        statistics
                        section("Média", rows: metadata.mediaRows)
                        if let overview = metadata.overview {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Synopsis").font(.headline).accessibilityAddTraits(.isHeader)
                                Text(overview).font(.body).lineSpacing(5)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
            }
            .background { releaseAmbience.ignoresSafeArea() }
            .task(id: ArtworkLoadID(releaseID: release.id, posterURL: release.posterUrl,
                                    generation: posterService.generation)) {
                await loadArtworkAccent()
            }
            .task(id: selection.configurationRevision) {
                guard isCurrent else { return }
                do {
                    let trackers = try await FeedarrAPIClient(sources: manager).trackerSources()
                    guard !Task.isCancelled, isCurrent else { return }
                    tracker = trackers.first { $0.id == release.sourceId }
                } catch {
                    // The validated release URL remains available without the directory badge.
                    tracker = nil
                }
            }
            .sheet(item: $informationPage) { page in
                FeedarrSafariView(url: page.url)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $presentedTorrentExport, onDismiss: cleanUpTorrent) { export in
                FeedarrTorrentActivitySheet(export: export) { presentedTorrentExport = nil }
                    .interactiveDismissDisabled()
            }
            .alert("Lien magnet", isPresented: $showingMagnet) {
                Button("Copier le magnet") {
                    if isCurrent, let magnetLink {
                        UIPasteboard.general.string = magnetLink
                        downloadActivity?.finish(.magnetCopied)
                    } else {
                        downloadActivity?.finish(.cancelled)
                    }
                    magnetLink = nil
                }
                Button("Annuler", role: .cancel) {
                    downloadActivity?.finish(.cancelled)
                    magnetLink = nil
                }
            } message: { Text("Le serveur a fourni un lien magnet. Copiez-le pour l’utiliser dans votre client torrent.") }
            .alert("Téléchargement impossible", isPresented: $downloadFailed) {
                Button("Réessayer") { downloadTorrent() }
                Button("Annuler", role: .cancel) {}
            } message: { Text(downloadErrorMessage ?? "Le téléchargement a échoué. Réessayez.") }
            .alert("Lien indisponible", isPresented: $externalLinkRejected) {
                Button("Fermer", role: .cancel) {}
            } message: { Text("Ce lien ne peut pas être ouvert en toute sécurité.") }
            .navigationTitle("Release")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .cancel) { dismiss() } label: {
                        Label("Fermer", systemImage: "xmark").labelStyle(.iconOnly)
                    }
                }
            }
        }
        .onDisappear {
            cancelDownload()
            if !showingExport {
                torrentExport?.close()
                torrentExport = nil
            }
            externalLinkTask?.cancel()
            externalLinkTask = nil
        }
        .onChange(of: manager.configurationRevision) {
            cancelDownload()
            torrentExport?.complete(.cancelled)
            presentedTorrentExport = nil
            informationPage = nil
            externalLinkTask?.cancel()
            externalLinkTask = nil
            dismiss()
        }
        .onAppear {
            guard isCurrent else { dismiss(); return }
            if !didRecordOpening, let serverID = manager.source?.id {
                didRecordOpening = true
                FeedarrActivityStore.shared.recordOpening(serverID: serverID, release: release)
            }
        }
    }

    @ViewBuilder
    private var informationAction: some View {
        let links = FeedarrExternalLinks.items(for: release)
        if let link = links.first(where: { $0.id == "TMDB" }) ?? links.first(where: { $0.id == "TVDB" }) {
            Button { openExternalLink(link.url) } label: {
                Image(systemName: "info")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 44, height: 44)
                    .releaseActionGlass()
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(externalLinkTask != nil || downloadTask != nil || showingExport || !isCurrent)
            .accessibilityLabel("Informations" + " " + link.id)
        }
    }

    private func openExternalLink(_ url: URL) {
        guard isCurrent, externalLinkTask == nil, downloadTask == nil, !showingExport else { return }
        externalLinkTask = Task {
            defer { if !Task.isCancelled { externalLinkTask = nil } }
            guard isCurrent else { return }
            let allowed = await FeedarrExternalLinks.mayOpen(url)
            guard !Task.isCancelled, isCurrent else { return }
            if allowed {
                informationPage = FeedarrInformationPage(url: url)
            } else {
                externalLinkRejected = true
            }
        }
    }

    private var downloadAction: some View {
        Button(action: downloadTorrent) {
            ZStack {
                if downloadTask != nil {
                    ProgressView().tint(.blue)
                } else {
                    Image(systemName: "arrow.down")
                        .font(.body.weight(.semibold))
                }
            }
            .foregroundStyle(.blue)
            .frame(width: 44, height: 44)
            .releaseActionGlass()
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Télécharger")
        .disabled(downloadTask != nil || showingExport || externalLinkTask != nil || informationPage != nil || !isCurrent)
    }

    private func downloadTorrent() {
        guard isCurrent, downloadTask == nil, !showingExport,
              informationPage == nil, externalLinkTask == nil, let serverID = manager.source?.id else {
            return
        }
        torrentExport?.close()
        torrentExport = nil
        let activity = FeedarrActivityStore.shared.beginDownload(serverID: serverID, release: release)
        downloadActivity = activity
        let token = UUID()
        downloadToken = token
        downloadFailed = false
        downloadErrorMessage = nil
        let service = FeedarrTorrentService(api: FeedarrAPIClient(sources: manager))
        downloadTask = Task {
            defer { if downloadToken == token { downloadTask = nil } }
            do {
                let result = try await selection.downloadTorrent(sources: manager) {
                    try await service.download(releaseID: release.id, releaseName: release.title)
                }
                guard !Task.isCancelled, downloadToken == token, isCurrent else {
                    activity.finish(.cancelled)
                    if case .file(let url) = result { FeedarrTorrentService.cleanUp(url) }
                    return
                }
                switch result {
                case .file(let url):
                    torrentExport = try FeedarrTorrentExport(url: url) { outcome in
                        switch outcome {
                        case .saved: activity.finish(.exportSucceeded)
                        case .cancelled: activity.finish(.cancelled)
                        case .failed: activity.finish(.failed)
                        }
                    }
                    presentedTorrentExport = torrentExport
                case .magnet(let link):
                    magnetLink = link; showingMagnet = true
                }
            } catch {
                let cancelled = Task.isCancelled || !isCurrent || error is CancellationError ||
                    (error as? FeedarrAPIError) == .cancelled || (error as? FeedarrAPIError) == .obsoleteResponse
                activity.finish(cancelled ? .cancelled : .failed)
                guard !Task.isCancelled, downloadToken == token, isCurrent,
                      (error as? FeedarrAPIError) != .cancelled,
                      (error as? FeedarrAPIError) != .obsoleteResponse else {
                    return
                }
                downloadErrorMessage = error.localizedDescription
                downloadFailed = true
            }
        }
    }

    private func cleanUpTorrent() {
        guard let torrentExport else { return }
        // UIKit may dismiss without a completion callback (for example by dragging).
        // Every dismissal ends this session; no fallback action remains mounted.
        if torrentExport.outcome == nil { torrentExport.complete(.cancelled) }
        presentedTorrentExport = nil
        let result = torrentExport.close()
        self.torrentExport = nil
        if case .failed(let error) = result, isCurrent {
            downloadErrorMessage = error.localizedDescription
            downloadFailed = true
        }
    }

    private func cancelDownload() {
        if downloadTask != nil || magnetLink != nil { downloadActivity?.finish(.cancelled) }
        downloadToken = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        magnetLink = nil
        showingMagnet = false
        // Export sessions own their file until picker dismissal. Disappearing
        // from this view only cancels an in-flight HTTP download.
    }

    // One pipeline load supplies both the sharp poster and the blurred background.
    private var poster: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let posterImage {
                    Image(uiImage: posterImage).resizable().scaledToFill()
                } else {
                    Image(systemName: posterFailed ? "photo.badge.exclamationmark" : "photo")
                        .font(.title2).foregroundStyle(.secondary)
                }
            }
            .clipped()
            .frame(width: sizeClass == .regular ? 180 : 155)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityHidden(true)
    }

    private var releaseAmbience: some View {
        let accent = artworkAccent?.color ?? Color.accentColor
        let counterAccent = artworkAccent?.counterColor ?? Color.indigo
        return ZStack(alignment: .top) {
            Color(uiColor: .systemBackground)
            if let artworkBackground {
                GeometryReader { geometry in
                    artworkBackground
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height,
                            alignment: .center
                        )
                        .blur(radius: 8)
                        .saturation(1.15)
                        .brightness(colorScheme == .dark ? -0.12 : -0.25)
                        .opacity(colorScheme == .dark ? 0.90 : 0.90)
                        .clipped()
                }
            }
            Color(uiColor: .systemBackground)
                .opacity(colorScheme == .dark ? 0.40 : 0.35)
            RadialGradient(
                colors: [accent.opacity(colorScheme == .dark ? 0.68 : 0.48), accent.opacity(0)],
                center: .topLeading,
                startRadius: 24,
                endRadius: 620
            )
            RadialGradient(
                colors: [counterAccent.opacity(colorScheme == .dark ? 0.52 : 0.34), counterAccent.opacity(0)],
                center: .bottomTrailing,
                startRadius: 12,
                endRadius: 540
            )
            LinearGradient(
                colors: [Color.clear, Color(uiColor: .systemBackground).opacity(colorScheme == .dark ? 0.36 : 0.50)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func loadArtworkAccent() async {
        posterImage = nil
        posterFailed = false
        artworkAccent = nil
        artworkBackground = nil
        guard isCurrent, release.posterUrl?.isEmpty == false else { return }
        do {
            let image = try await posterService.image(for: release)
            try Task.checkCancellation()
            guard isCurrent else { return }
            posterImage = image
            guard let cgImage = image.cgImage else { return }
            let sendableImage = SendableCGImage(value: cgImage)
            let accent = await Task.detached(priority: .utility) {
                FeedarrArtworkAccent.extract(from: sendableImage.value)
            }.value
            try Task.checkCancellation()
            guard isCurrent else { return }
            artworkAccent = accent
            artworkBackground = Image(uiImage: image)
        } catch {
            if !Task.isCancelled { posterFailed = true }
        }
    }

    private var technicalTitle: String? {
        guard let title = release.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return title
    }

    private var cleanHeading: String? {
        guard let clean = release.titleClean?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else { return nil }
        return clean
    }

    private var primaryRows: [FeedarrReleaseDetailMetadata.Row] {
        metadata.releaseRows.filter { ["feedarr.detail.category", "feedarr.detail.year"].contains($0.id) }
    }

    private var metadataTextColor: Color {
        colorScheme == .dark
            ? .white.opacity(0.85)
            : .black.opacity(0.85)
    }

    private var primaryInformation: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let cleanHeading {
                Text(cleanHeading)
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
            }
            if !primaryRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(primaryRows) { row in
                        Text(row.value)
                            .font(.subheadline)
                            .foregroundStyle(metadataTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            let episodeRows = metadata.releaseRows.filter { ["feedarr.detail.season", "feedarr.detail.episode"].contains($0.id) }
            if !episodeRows.isEmpty {
                Text(episodeRows.map { label(for: $0.id) + " " + $0.value }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(metadataTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) { qualityBadges }
        }
    }

    @ViewBuilder
    private var qualityBadges: some View {
        let resolution = metadata.releaseRows.first { $0.id == "feedarr.detail.resolution" }?.value
        if let resolution { resolutionBadge(resolution) }
        if let codec = metadata.releaseRows.first(where: { $0.id == "feedarr.detail.codec" })?.value,
           codec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != resolution?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            Text(codec)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .feedarrBadgeGlass()
        }
    }

    private var releaseGroups: [[FeedarrReleaseDetailMetadata.Row]] {
        let rows = metadata.releaseRows
        return [
            ["feedarr.detail.source"].compactMap { key in rows.first { $0.id == key } },
            ["feedarr.detail.size", "feedarr.detail.published", "feedarr.detail.group"].compactMap { key in rows.first { $0.id == key } }
        ].filter { !$0.isEmpty }
    }

    @ViewBuilder
    private var releaseInformation: some View {
        if technicalTitle != nil || !releaseGroups.isEmpty || tracker != nil || FeedarrExternalLinks.validatedURL(release.trackerPageUrl) != nil {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    if let technicalTitle {
                        Text(technicalTitle).font(.subheadline.weight(.medium)).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if !releaseGroups.isEmpty { Divider() }
                    }
                    ForEach(Array(releaseGroups.enumerated()), id: \.offset) { index, rows in
                        if index > 0 { Divider() }
                        detailRows(rows)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            } label: {
                HStack {
                    Text("Informations").accessibilityAddTraits(.isHeader)
                    Spacer()
                    if let url = FeedarrExternalLinks.validatedURL(release.trackerPageUrl) {
                        Button { openExternalLink(url) } label: {
                            trackerBadge
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Tracker" + (tracker.map { " " + $0.name } ?? ""))
                        .disabled(externalLinkTask != nil || downloadTask != nil || showingExport || !isCurrent)
                    } else if tracker != nil {
                        trackerBadge
                    }
                }
            }
            .releaseDetailCard()
        }
    }

    private var trackerBadge: some View {
        let rgb = tracker?.badgeColor
        let background = rgb.map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue, opacity: 1) }
            ?? Color.secondary.opacity(0.15)
        return Label(tracker?.name ?? "Tracker", systemImage: "link")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .feedarrBadgeGlass(tint: background,
                               interactive: FeedarrExternalLinks.validatedURL(release.trackerPageUrl) != nil)
    }

    @ViewBuilder
    private var statistics: some View {
        if !metadata.statisticsRows.isEmpty {
            GroupBox {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 16) {
                    ForEach(metadata.statisticsRows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.value).font(.headline).monospacedDigit()
                            Text(label(for: row.id))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Statistiques").accessibilityAddTraits(.isHeader)
            }
            .releaseDetailCard()
        }
    }

    @ViewBuilder
    private func section(_ title: String, rows: [FeedarrReleaseDetailMetadata.Row]) -> some View {
        if !rows.isEmpty {
            GroupBox {
                detailRows(rows).padding(.top, 8)
            } label: {
                Text(title).accessibilityAddTraits(.isHeader)
            }
            .releaseDetailCard()
        }
    }

    private func detailRows(_ rows: [FeedarrReleaseDetailMetadata.Row]) -> some View {
        VStack(spacing: 14) {
            ForEach(rows) { row in
                LabeledContent(label(for: row.id)) {
                    Text(row.value)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resolutionBadge(_ value: String) -> some View {
        let style = FeedarrResolutionBadgeStyle(resolution: value)
        return Text(value)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .feedarrBadgeGlass(tint: style.tint)
    }

    private struct ArtworkLoadID: Equatable {
        let releaseID: Int64
        let posterURL: String?
        let generation: UUID
    }
    private func label(for key: String) -> String {
        let labels = [
            "cleanTitle": "Titre", "year": "Année", "category": "Catégorie",
            "season": "Saison", "episode": "Épisode", "resolution": "Résolution",
            "codec": "Codec", "source": "Source", "group": "Groupe", "size": "Taille",
            "published": "Publication", "rating": "Note", "votes": "Votes",
            "genres": "Genres", "runtime": "Durée (min)", "releaseDate": "Date de sortie",
            "seeders": "Seeders", "leechers": "Leechers", "grabs": "Téléchargements"
        ]
        return labels[String(key.dropFirst("feedarr.detail.".count))] ?? key
    }
}

private struct FeedarrInformationPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct FeedarrSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(
        _ controller: SFSafariViewController,
        context: Context
    ) {}
}

private extension View {
    @ViewBuilder
    func feedarrBadgeGlass(
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                if let tint {
                    self.glassEffect(.regular.tint(tint).interactive(), in: .capsule)
                } else {
                    self.glassEffect(.regular.interactive(), in: .capsule)
                }
            } else if let tint {
                self.glassEffect(.regular.tint(tint), in: .capsule)
            } else {
                self.glassEffect(.regular, in: .capsule)
            }
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }
    @ViewBuilder
    func releaseActionGlass() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.background(.regularMaterial, in: Circle())
        }
    }

    func releaseDetailCard() -> some View {
        self.groupBoxStyle(FeedarrCardStyle())
    }
}

nonisolated private struct SendableCGImage: @unchecked Sendable {
    let value: CGImage
}

private struct FeedarrCardStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        let content = VStack(alignment: .leading, spacing: 16) {
            configuration.label
                .font(.headline)

            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)

        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
        } else {
            content
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
        }
    }
}

nonisolated private struct FeedarrArtworkAccent: Equatable, Sendable {
    let hue: Double
    let saturation: Double
    let brightness: Double

    var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    var counterColor: Color {
        Color(hue: (hue + 0.48).truncatingRemainder(dividingBy: 1),
              saturation: min(0.74, saturation + 0.08),
              brightness: min(0.66, brightness + 0.04))
    }

    nonisolated static func extract(from image: CGImage) -> Self? {
        let sampleWidth = 32
        let sampleHeight = 32
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var buckets = [Bucket](repeating: Bucket(), count: 24 * 4 * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.5 else { continue }
            let red = Double(pixels[offset]) / 255
            let green = Double(pixels[offset + 1]) / 255
            let blue = Double(pixels[offset + 2]) / 255
            let hsb = hsb(red: red, green: green, blue: blue)
            guard hsb.saturation >= 0.16, hsb.brightness >= 0.12, hsb.brightness <= 0.94 else { continue }

            let hueIndex = min(23, Int(hsb.hue * 24))
            let saturationIndex = min(3, Int(hsb.saturation * 4))
            let brightnessIndex = min(3, Int(hsb.brightness * 4))
            let index = hueIndex * 16 + saturationIndex * 4 + brightnessIndex
            let luminancePreference = 1 - abs(hsb.brightness - 0.58) * 0.65
            let weight = (0.35 + hsb.saturation) * luminancePreference * alpha
            buckets[index].weight += weight
            buckets[index].red += red * weight
            buckets[index].green += green * weight
            buckets[index].blue += blue * weight
        }

        guard let bucket = buckets.max(by: { $0.weight < $1.weight }), bucket.weight > 0 else { return nil }
        let selected = hsb(
            red: bucket.red / bucket.weight,
            green: bucket.green / bucket.weight,
            blue: bucket.blue / bucket.weight
        )
        return Self(
            hue: selected.hue,
            saturation: min(0.72, max(0.44, selected.saturation)),
            brightness: min(0.68, max(0.48, selected.brightness))
        )
    }

    private nonisolated static func hsb(red: Double, green: Double, blue: Double) -> HSB {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let saturation = maximum == 0 ? 0 : delta / maximum
        guard delta > 0 else { return HSB(hue: 0, saturation: saturation, brightness: maximum) }
        let rawHue: Double
        if maximum == red {
            rawHue = (green - blue) / delta
        } else if maximum == green {
            rawHue = 2 + (blue - red) / delta
        } else {
            rawHue = 4 + (red - green) / delta
        }
        let hue = (rawHue / 6).truncatingRemainder(dividingBy: 1)
        return HSB(hue: hue < 0 ? hue + 1 : hue, saturation: saturation, brightness: maximum)
    }

    private struct Bucket {
        var weight = 0.0
        var red = 0.0
        var green = 0.0
        var blue = 0.0
    }

    private struct HSB {
        let hue: Double
        let saturation: Double
        let brightness: Double
    }
}

enum FeedarrResolutionBadgeStyle: Equatable, Sendable {
    case hd, fullHD, ultraHD, sd, neutral

    init(resolution: String) {
        switch resolution.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "720p": self = .hd
        case "1080p": self = .fullHD
        case "2160p", "4k": self = .ultraHD
        case "480p", "sd": self = .sd
        default: self = .neutral
        }
    }

    var tint: Color {
        switch self {
        case .hd: .green
        case .fullHD: .blue
        case .ultraHD: .purple
        case .sd: .gray
        case .neutral: .secondary
        }
    }
}

