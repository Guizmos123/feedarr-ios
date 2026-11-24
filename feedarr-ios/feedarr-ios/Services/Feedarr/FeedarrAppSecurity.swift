import LocalAuthentication
import Observation
import SwiftUI
import UIKit

/// One authentication context for the entire app; no credentials enter this store.
@MainActor
@Observable
final class FeedarrAppSecurity {
    static let shared = FeedarrAppSecurity()
    private(set) var isEnabled: Bool
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    private(set) var isForegroundActive = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var needsAutomaticUnlock = true
    @ObservationIgnored private var context: LAContext?
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var shields: [String: Shield] = [:]

    private init() {
        let enabled = UserDefaults.standard.bool(forKey: FeedarrSecurityPreferences.requiresFaceIDKey)
        isEnabled = enabled
        isLocked = enabled
    }

    var canUnlock: Bool { isEnabled && isLocked && isForegroundActive && !isAuthenticating }

    func connect(_ scene: UIWindowScene) {
        guard shields[scene.session.persistentIdentifier] == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.backgroundColor = .systemBackground
        let controller = UIHostingController(rootView: FeedarrLockScreen(security: self))
        controller.view.backgroundColor = .systemBackground
        controller.view.accessibilityViewIsModal = true
        window.rootViewController = controller
        shields[scene.session.persistentIdentifier] = Shield(window: window)
        updateShields()
    }

    func becameActive(_ scene: UIWindowScene) {
        connect(scene)
        shields[scene.session.persistentIdentifier]?.active = true
        isForegroundActive = true
        updateShields()
        if isEnabled && isLocked && needsAutomaticUnlock && !isAuthenticating {
            needsAutomaticUnlock = false
            authenticate(.unlock, in: scene)
        }
    }

    func becameInactive(_ scene: UIWindowScene) {
        connect(scene)
        shields[scene.session.persistentIdentifier]?.active = false
        isForegroundActive = shields.values.contains { $0.active }
        // Synchronous opaque cover, including when app locking is disabled.
        // Do not invalidate LAContext here: its system prompt can cause inactivity.
        updateShields()
    }

    func enteredBackground(_ scene: UIWindowScene) {
        becameInactive(scene)
        invalidateAuthentication()
        if isEnabled {
            isLocked = true
            needsAutomaticUnlock = true
        }
        errorMessage = nil
        updateShields()
    }

    func disconnect(_ scene: UIWindowScene) {
        let id = scene.session.persistentIdentifier
        if let shield = shields.removeValue(forKey: id) {
            shield.restoreWindows()
            shield.window.isHidden = true
            shield.window.rootViewController = nil
        }
        invalidateAuthentication()
        isForegroundActive = shields.values.contains { $0.active }
        if isEnabled { isLocked = true; needsAutomaticUnlock = true }
        updateShields()
    }

    func unlock() {
        guard canUnlock, let scene = activeScene else { return }
        needsAutomaticUnlock = false
        authenticate(.unlock, in: scene)
    }

    func requestEnabled(_ enabled: Bool) {
        guard enabled != isEnabled, !isLocked, !isAuthenticating, let scene = activeScene else { return }
        authenticate(.preference(enabled), in: scene)
    }

    private var activeScene: UIWindowScene? {
        shields.values.first { $0.active }?.window.windowScene
    }

    nonisolated private enum Operation: Sendable { case unlock, preference(Bool) }
    nonisolated private enum Failure: Sendable { case cancelled, unavailable, rejected }

    private func authenticate(_ operation: Operation, in scene: UIWindowScene) {
        guard !isAuthenticating, scene.activationState == .foregroundActive else { return }
        errorMessage = nil
        let authentication = LAContext()
        authentication.localizedCancelTitle = "Annuler"
        authentication.touchIDAuthenticationAllowableReuseDuration = 0
        var error: NSError?
        guard authentication.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            errorMessage = "Authentification indisponible. Vérifiez Face ID et le code de l’iPhone dans les Réglages iOS."
            return
        }
        let id = UUID()
        let sceneID = scene.session.persistentIdentifier
        requestID = id
        context = authentication
        isAuthenticating = true
        let reason: String
        switch operation {
        case .unlock: reason = "Déverrouiller Feedarr."
        case .preference(true): reason = "Activer la protection de Feedarr."
        case .preference(false): reason = "Désactiver la protection de Feedarr."
        }
        authentication.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, error in
            let failure: Failure
            switch (error as? LAError)?.code {
            case .userCancel, .systemCancel, .appCancel: failure = .cancelled
            case .passcodeNotSet, .biometryNotAvailable, .biometryNotEnrolled: failure = .unavailable
            default: failure = .rejected
            }
            Task { @MainActor [weak self] in
                self?.complete(id, sceneID: sceneID, operation: operation, success: success, failure: failure)
            }
        }
    }

    private func complete(_ id: UUID, sceneID: String, operation: Operation, success: Bool, failure: Failure) {
        guard requestID == id, let scene = shields[sceneID]?.window.windowScene,
              scene.activationState != .background && scene.activationState != .unattached else { return }
        requestID = nil
        context = nil
        isAuthenticating = false
        if success {
            if case .preference(let enabled) = operation {
                // The preference can only be written after successful system authentication.
                UserDefaults.standard.set(enabled, forKey: FeedarrSecurityPreferences.requiresFaceIDKey)
                isEnabled = enabled
            }
            isLocked = false
            needsAutomaticUnlock = false
            errorMessage = nil
        } else {
            switch failure {
            case .cancelled: errorMessage = "Authentification annulée. Vous pouvez réessayer."
            case .unavailable: errorMessage = "Authentification indisponible. Utilisez le code de l’iPhone."
            case .rejected: errorMessage = "Authentification échouée. Vous pouvez réessayer."
            }
            // Never change the preference or retry automatically after an unsuccessful attempt.
        }
        updateShields()
    }

    private func invalidateAuthentication() {
        requestID = nil
        context?.invalidate()
        context = nil
        isAuthenticating = false
    }

    private func updateShields() {
        for shield in shields.values {
            let protect = !shield.active || (isEnabled && isLocked)
            if protect {
                // Never make this window key: navigation, sheets and keyboard ownership survive.
                shield.window.isHidden = false
                shield.blockWindows()
            } else {
                shield.restoreWindows()
                shield.window.isHidden = true
            }
        }
    }

    private final class Shield {
        let window: UIWindow
        var active = false
        private var blocked: [ObjectIdentifier: WindowState] = [:]
        init(window: UIWindow) { self.window = window }
        func blockWindows() {
            for underlying in window.windowScene?.windows ?? [] where underlying !== window {
                let id = ObjectIdentifier(underlying)
                if blocked[id] == nil { blocked[id] = WindowState(underlying) }
                underlying.isUserInteractionEnabled = false
                underlying.accessibilityElementsHidden = true
            }
        }
        func restoreWindows() {
            for state in blocked.values {
                state.window?.isUserInteractionEnabled = state.interactive
                state.window?.accessibilityElementsHidden = state.accessibilityHidden
            }
            blocked = [:]
        }
    }
    private final class WindowState {
        weak var window: UIWindow?
        let interactive: Bool
        let accessibilityHidden: Bool
        init(_ window: UIWindow) {
            self.window = window
            interactive = window.isUserInteractionEnabled
            accessibilityHidden = window.accessibilityElementsHidden
        }
    }
}
