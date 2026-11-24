import SwiftUI
import UIKit

@main struct MyApp: App {
    @UIApplicationDelegateAdaptor(FeedarrAppDelegate.self) private var appDelegate
    @AppStorage(FeedarrNavigationPreferences.allowsLandscapeKey) private var allowsLandscape = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { FeedarrOrientation.updateScenes() }
                .onChange(of: allowsLandscape) { FeedarrOrientation.updateScenes() }
                .onChange(of: scenePhase) {
                    if scenePhase == .active { FeedarrOrientation.updateScenes() }
                }
        }
    }
}

final class FeedarrAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Preserve SwiftUI's scene configuration and window lifecycle.
        let configuration = connectingSceneSession.configuration.copy() as! UISceneConfiguration
        configuration.delegateClass = FeedarrSceneDelegate.self
        return configuration
    }
}

final class FeedarrSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let scene = scene as? UIWindowScene { FeedarrAppSecurity.shared.connect(scene) }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        if let scene = scene as? UIWindowScene { FeedarrAppSecurity.shared.becameInactive(scene) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        if let scene = scene as? UIWindowScene { FeedarrAppSecurity.shared.becameActive(scene) }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        if let scene = scene as? UIWindowScene { FeedarrAppSecurity.shared.becameInactive(scene) }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        if let scene = scene as? UIWindowScene { FeedarrAppSecurity.shared.enteredBackground(scene) }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if let scene = scene as? UIWindowScene { FeedarrAppSecurity.shared.disconnect(scene) }
    }

    func supportedInterfaceOrientations(for windowScene: UIWindowScene) -> UIInterfaceOrientationMask {
        FeedarrOrientation.supportedOrientations
    }
}

private enum FeedarrOrientation {
    static var supportedOrientations: UIInterfaceOrientationMask {
        UserDefaults.standard.bool(forKey: FeedarrNavigationPreferences.allowsLandscapeKey)
            ? [.portrait, .landscapeLeft, .landscapeRight] : .portrait
    }

    static func updateScenes() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            guard scene.activationState == .foregroundActive else { continue }
            for window in scene.windows {
                if let root = window.rootViewController { invalidateOrientations(root) }
            }
            // Enabling landscape only expands the mask; never request a landscape rotation.
            // Disabling it can return the current scene (including its sheets) to portrait.
            if supportedOrientations == .portrait,
               scene.effectiveGeometry.interfaceOrientation != .portrait {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }

    private static func invalidateOrientations(_ controller: UIViewController) {
        controller.setNeedsUpdateOfSupportedInterfaceOrientations()
        for child in controller.children { invalidateOrientations(child) }
        if let presented = controller.presentedViewController { invalidateOrientations(presented) }
    }
}
