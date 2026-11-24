import Foundation
import Observation
import UIKit
import ImageIO

nonisolated enum FeedarrPosterError: Error, LocalizedError, Equatable, Sendable {
    case sourceNotConfigured, credentialsUnavailable, missingCredentials
    case invalidURL, invalidImage, cancelled, obsoleteResponse
    case transport(FeedarrHTTPError)

    var errorDescription: String? { "Le poster Feedarr est indisponible." }
}

/// Native replacement for XTubee's Nuke backend. Keeps its URL policy and bounded
/// authenticated transport; decoded posters are cached in memory only.
@MainActor
@Observable
final class FeedarrPosterService {
    nonisolated static let maximumResponseSize = 8 * 1_024 * 1_024
    nonisolated static let memoryCacheLimit = 32 * 1_024 * 1_024
    private(set) var generation = UUID()
    @ObservationIgnored private let sources: FeedarrSourcesManager
    @ObservationIgnored private let credentialsStore: any FeedarrCredentialsStoring
    @ObservationIgnored private let transport: any FeedarrHTTPTransport
    @ObservationIgnored private let cache = NSCache<NSString, UIImage>()
    @ObservationIgnored private var revision: UUID
    @ObservationIgnored private var downloads: [String: Download] = [:]
    @ObservationIgnored private var images: [String: ImageFlight] = [:]
    @ObservationIgnored private var authentication: FeedarrCredentials?
    @ObservationIgnored private var hasAuthentication = false

    nonisolated private struct Download: Sendable {
        let id: UUID
        let task: Task<Data, Error>
        var consumers: Set<UUID>
    }
    nonisolated private struct ImageFlight: Sendable {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<UIImage, Error>]
    }

    init(sources: FeedarrSourcesManager) {
        self.sources = sources
        credentialsStore = FeedarrCredentialsStore()
        transport = URLSessionFeedarrTransport()
        revision = sources.configurationRevision
        cache.totalCostLimit = Self.memoryCacheLimit
        cache.countLimit = 150
        observeSource()
    }

    func image(for release: FeedarrRelease, maximumPixelSize: Int = 1200) async throws -> UIImage {
        try Task.checkCancellation()
        refreshConfiguration()
        guard let source = sources.source else { throw FeedarrPosterError.sourceNotConfigured }
        guard sources.loadError == nil else { throw FeedarrPosterError.credentialsUnavailable }
        let configuration = sources.configurationRevision
        let url = try Self.resolvePosterURL(release.posterUrl, source: source)
        let pixels = min(max(maximumPixelSize, 1), 1200)
        let cachedKey = generation.uuidString + ":" + source.id.uuidString + ":" + url.absoluteString + ":" + String(pixels)
        if let image = cache.object(forKey: cachedKey as NSString) { return image }
        let credentials: FeedarrCredentials?
        if source.usesBasicAuth {
            guard source.serverURL.scheme == "https" else {
                throw FeedarrPosterError.transport(.insecureBasicAuth)
            }
            do { credentials = try credentialsStore.credentials(for: source.id) }
            catch { throw FeedarrPosterError.credentialsUnavailable }
            guard credentials != nil else { throw FeedarrPosterError.missingCredentials }
        } else { credentials = nil }
        // Never join an in-flight request made with a different authentication snapshot.
        if hasAuthentication && authentication != credentials { invalidate() }
        authentication = credentials
        hasAuthentication = true
        let token = generation
        let downloadKey = token.uuidString + ":" + source.id.uuidString + ":" + url.absoluteString
        let imageKey = downloadKey + ":" + String(pixels)
        let consumer = UUID()
        do {
            let image: UIImage = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: FeedarrPosterError.cancelled)
                        return
                    }
                    if images[imageKey] != nil {
                        images[imageKey]?.waiters[consumer] = continuation
                        return
                    }
                    let flightID = UUID()
                    let work = Task { [weak self] in
                        guard let self else { return }
                        do {
                            let image = try await self.loadImage(url: url, key: downloadKey,
                                                                 credentials: credentials, pixels: pixels)
                            try Task.checkCancellation()
                            self.refreshConfiguration()
                            guard token == self.generation, configuration == self.sources.configurationRevision,
                                  self.sources.loadError == nil else { throw FeedarrPosterError.obsoleteResponse }
                            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
                            self.cache.setObject(image, forKey: imageKey as NSString, cost: cost)
                            self.finishImage(imageKey, id: flightID, result: .success(image))
                        } catch {
                            self.finishImage(imageKey, id: flightID, result: .failure(error))
                        }
                    }
                    images[imageKey] = ImageFlight(id: flightID, task: work, waiters: [consumer: continuation])
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelImage(imageKey, consumer: consumer) }
            }
            try Task.checkCancellation()
            // A resumed waiter can run after another main-actor turn switched servers.
            refreshConfiguration()
            guard token == generation, configuration == sources.configurationRevision,
                  sources.source?.id == source.id, sources.loadError == nil else {
                throw FeedarrPosterError.obsoleteResponse
            }
            return image
        } catch {
            refreshConfiguration()
            if Task.isCancelled || error is CancellationError { throw FeedarrPosterError.cancelled }
            guard token == generation else { throw FeedarrPosterError.obsoleteResponse }
            if let error = error as? FeedarrHTTPError { throw FeedarrPosterError.transport(error) }
            throw error
        }
    }

    private func loadImage(url: URL, key: String, credentials: FeedarrCredentials?, pixels: Int) async throws -> UIImage {
        try Task.checkCancellation()
        let consumer = UUID()
        let download: Download
        if var existing = downloads[key] {
            existing.consumers.insert(consumer)
            downloads[key] = existing
            download = existing
        } else {
            let transport = self.transport
            let task = Task {
                let http = try FeedarrHTTPClient(
                    serverURL: url.absoluteString, username: credentials?.username, password: credentials?.password,
                    transport: FeedarrPosterTransport(underlying: transport), maximumResponseSize: Self.maximumResponseSize
                )
                let (data, response) = try await http.getResponse(pathComponents: [])
                try http.validateStatus(response)
                try Task.checkCancellation()
                return data
            }
            download = Download(id: UUID(), task: task, consumers: [consumer])
            downloads[key] = download
        }
        // Hold the bytes through decoding, so another size can reuse the same download.
        return try await withTaskCancellationHandler {
            defer { releaseDownload(key, id: download.id, consumer: consumer) }
            let data = try await download.task.value
            try Task.checkCancellation()
            return try await Self.decode(data, maximumPixelSize: pixels)
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.releaseDownload(key, id: download.id, consumer: consumer)
            }
        }
    }

    private func releaseDownload(_ key: String, id: UUID, consumer: UUID) {
        guard var download = downloads[key], download.id == id else { return }
        download.consumers.remove(consumer)
        if download.consumers.isEmpty {
            downloads[key] = nil
            download.task.cancel()
        } else { downloads[key] = download }
    }

    private func cancelImage(_ key: String, consumer: UUID) {
        guard var flight = images[key], let waiter = flight.waiters.removeValue(forKey: consumer) else { return }
        if flight.waiters.isEmpty {
            images[key] = nil
            flight.task.cancel()
        } else { images[key] = flight }
        waiter.resume(throwing: FeedarrPosterError.cancelled)
    }

    private func finishImage(_ key: String, id: UUID, result: Result<UIImage, Error>) {
        guard let flight = images[key], flight.id == id else { return }
        images[key] = nil
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }

    // Bound decoded dimensions too, so a small compressed response cannot allocate
    // an arbitrarily large bitmap. ImageIO also avoids decoding on the main actor.
    @concurrent
    private nonisolated static func decode(_ data: Data, maximumPixelSize: Int) async throws -> UIImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw FeedarrPosterError.invalidImage }
        try Task.checkCancellation()
        return UIImage(cgImage: cgImage)
    }

    private func refreshConfiguration() {
        guard revision != sources.configurationRevision else { return }
        revision = sources.configurationRevision
        invalidate()
    }

    private func invalidate() {
        generation = UUID()
        cache.removeAllObjects()
        authentication = nil
        hasAuthentication = false
        let pending = Array(images.values)
        images.removeAll()
        for flight in pending {
            flight.task.cancel()
            for waiter in flight.waiters.values { waiter.resume(throwing: FeedarrPosterError.obsoleteResponse) }
        }
        for download in downloads.values { download.task.cancel() }
        downloads.removeAll()
    }

    private func observeSource() {
        withObservationTracking {
            _ = sources.configurationRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshConfiguration()
                self.observeSource()
            }
        }
    }
    /// Handles both backend-root paths and paths already including the proxy base.
    /// Absolute URLs are preserved, but must stay inside the configured installation.
    nonisolated static func resolvePosterURL(_ raw: String?, source: FeedarrSource) throws -> URL {
        guard let raw, !raw.isEmpty, !raw.hasPrefix("//"), !raw.contains("\\"),
              !raw.contains(where: { $0.isWhitespace || $0.isNewline }),
              var poster = URLComponents(string: raw), poster.fragment == nil,
              poster.user == nil, poster.password == nil else { throw FeedarrPosterError.invalidURL }
        let decodedPath = poster.percentEncodedPath.removingPercentEncoding ?? poster.path
        guard !decodedPath.contains("\\"),
              !decodedPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw FeedarrPosterError.invalidURL
        }
        let forbidden = Set(["username", "password", "user", "pass", "token", "access_token", "api_key", "apikey", "authorization"])
        guard !(poster.queryItems ?? []).contains(where: { forbidden.contains($0.name.lowercased()) }) else {
            throw FeedarrPosterError.invalidURL
        }
        guard let base = URLComponents(url: source.serverURL, resolvingAgainstBaseURL: false) else {
            throw FeedarrPosterError.invalidURL
        }
        let prefix = base.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePath = prefix.isEmpty ? "" : "/" + prefix
        if poster.scheme == nil && poster.host == nil {
            let path = "/" + poster.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            poster.scheme = base.scheme
            poster.host = base.host
            poster.port = base.port
            poster.percentEncodedPath = basePath.isEmpty || path.hasPrefix(basePath + "/") ? path : basePath + path
        }
        guard let url = poster.url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              FeedarrRedirectPolicy.allowsRedirect(from: source.serverURL, to: url),
              basePath.isEmpty || url.path.hasPrefix(source.serverURL.path + "/") else {
            throw FeedarrPosterError.invalidURL
        }
        return url
    }

}

nonisolated private struct FeedarrPosterTransport: FeedarrHTTPTransport {
    let underlying: any FeedarrHTTPTransport
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, maximumResponseSize: FeedarrPosterService.maximumResponseSize)
    }
    func data(for request: URLRequest, maximumResponseSize: Int) async throws -> (Data, URLResponse) {
        var request = request
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return try await underlying.data(for: request, maximumResponseSize: maximumResponseSize)
    }
}
