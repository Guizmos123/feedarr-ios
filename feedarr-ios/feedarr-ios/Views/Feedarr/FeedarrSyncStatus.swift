import SwiftUI
import Observation

/// Shared UI state for manual refreshes only, adapted from FeedarrRootView.
@MainActor
@Observable
final class FeedarrSyncStatus {
    enum Outcome { case success, failure(String), obsolete }
    private(set) var state: SyncStatusCapsule.State?
    private var refreshID: UUID?
    var isRefreshing: Bool { refreshID != nil }
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func refresh(isValid: @escaping @MainActor () -> Bool,
                 operation: @escaping @MainActor () async -> Outcome) async {
        guard refreshID == nil, isValid() else { return }
        let id = UUID()
        refreshID = id
        present(.synchronizing("Synchronisation…"))
        // Retain ownership when Releases replaces its ScrollView after a refresh.
        let task = Task { @MainActor in
            defer {
                if refreshID == id { refreshTask = nil; refreshID = nil }
            }
            let outcome = await operation()
            guard !Task.isCancelled, refreshID == id else { return }
            guard isValid() else { dismiss(); return }
            switch outcome {
            case .success: present(.success("Synchronisation terminée"), dismissAfter: .seconds(2))
            case .failure(let message): present(.error(message), dismissAfter: .seconds(3))
            case .obsolete: dismiss()
            }
        }
        refreshTask = task
        await task.value
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        dismiss()
    }

    private func present(_ state: SyncStatusCapsule.State, dismissAfter delay: Duration? = nil) {
        dismissTask?.cancel()
        dismissTask = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { self.state = state }
        guard let delay else { return }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self.state == state else { return }
            dismiss()
        }
    }

    private func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        withAnimation(.easeOut(duration: 0.22)) { state = nil }
    }
}

// The three states used by Feedarr, isolated from XTubee's subscriptions view.
struct SyncStatusCapsule: View {
    enum State: Equatable {
        case synchronizing(String), success(String), error(String)
    }
    let state: State
    let accentColor: Color

    var body: some View {
        HStack(spacing: 10) {
            switch state {
            case .synchronizing(let message):
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .foregroundStyle(accentColor)
                    .symbolEffect(.rotate, options: .repeating)
                Text(message)
            case .success(let message):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(message)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
            }
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
    }
}

struct FeedarrSyncOverlay: ViewModifier {
    let status: FeedarrSyncStatus
    let isVisible: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if isVisible, let state = status.state {
                SyncStatusCapsule(state: state, accentColor: .accentColor)
                    .transition(.move(edge: .top).combined(with: .opacity)
                        .combined(with: .scale(scale: 0.94, anchor: .top)))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
    }
}
