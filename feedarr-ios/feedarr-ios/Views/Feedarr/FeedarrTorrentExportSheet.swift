//
//  FeedarrTorrentExportSheet.swift
//  Yattee
//
//  Share a validated local torrent using the native iOS activity sheet.
//

import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

enum FeedarrTorrentExportOutcome: Equatable, Sendable {
    case saved
    case cancelled
    case failed(FeedarrTorrentError)
}

@MainActor
final class FeedarrTorrentExport: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    private(set) var outcome: FeedarrTorrentExportOutcome?
    private var closed = false
    private let onOutcome: @MainActor (FeedarrTorrentExportOutcome) -> Void

    init(url: URL, onOutcome: @escaping @MainActor (FeedarrTorrentExportOutcome) -> Void = { _ in }) throws {
        do {
            _ = try FeedarrTorrentService.validateLocalFile(url)
        } catch {
            FeedarrTorrentService.cleanUp(url)
            throw error
        }
        self.url = url
        self.onOutcome = onOutcome
    }

    deinit { FeedarrTorrentService.cleanUp(url) }

    func complete(_ result: FeedarrTorrentExportOutcome) {
        guard outcome == nil, !closed else { return }
        outcome = result
        onOutcome(result)
    }

    /// Called after the picker is dismissed, never when its parent merely disappears.
    @discardableResult
    func close() -> FeedarrTorrentExportOutcome {
        if outcome == nil { complete(.failed(.exportInterrupted)) }
        if !closed {
            closed = true
            FeedarrTorrentService.cleanUp(url)
        }
        return outcome ?? .failed(.exportInterrupted)
    }
}

#if os(iOS)
/// Pass only the actual file URL to UIKit; no text, HTTP URL or custom item provider.
struct FeedarrTorrentActivitySheet: UIViewControllerRepresentable {
    let export: FeedarrTorrentExport
    let onComplete: @MainActor @Sendable () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(export: export) { [onComplete] in onComplete() }
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [export.url], applicationActivities: nil)
        let coordinator = context.coordinator
        controller.completionWithItemsHandler = { _, completed, _, error in
            let result: FeedarrTorrentExportOutcome
            if error != nil {
                result = .failed(.exportInterrupted)
            } else {
                result = completed ? .saved : .cancelled
            }
            Task { @MainActor in coordinator.finish(result) }
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    @MainActor
    final class Coordinator {
        private let export: FeedarrTorrentExport
        private let onComplete: @MainActor @Sendable () -> Void
        private var finished = false

        init(export: FeedarrTorrentExport, onComplete: @escaping @MainActor @Sendable () -> Void) {
            self.export = export
            self.onComplete = onComplete
        }

        func finish(_ result: FeedarrTorrentExportOutcome) {
            guard !finished else { return }
            finished = true
            export.complete(result)
            onComplete()
        }
    }
}

#endif
