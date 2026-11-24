import SwiftUI
import UIKit

struct FeedarrSecuritySettingsView: View {
    private let security = FeedarrAppSecurity.shared

    var body: some View {
        Form {
            Section {
                Toggle("Exiger Face ID", isOn: Binding(
                    get: { security.isEnabled }, set: { security.requestEnabled($0) }
                ))
                .disabled(security.isAuthenticating)
                if security.isAuthenticating { ProgressView("Authentification…") }
                if let message = security.errorMessage {
                    Text(message).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Face ID protège l’accès à Feedarr à chaque ouverture et retour de l’arrière-plan. Le code de l’iPhone reste disponible en secours. Une authentification est nécessaire pour modifier cette option.")
            }
        }
        .navigationTitle("Sécurité")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Opaque window content, above every app presentation, also used for app-switcher privacy.
struct FeedarrLockScreen: View {
    let security: FeedarrAppSecurity
    @AppStorage(FeedarrAppearance.storageKey) private var appearance: FeedarrAppearance = .system

    private static let icon: UIImage? = {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let names = primary?["CFBundleIconFiles"] as? [String]
        if let name = names?.last, let image = UIImage(named: name) { return image }
        return UIImage(named: "AppIcon")
    }()

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 24) {
                if let icon = Self.icon {
                    Image(uiImage: icon).resizable().scaledToFit()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .accessibilityLabel("Feedarr")
                } else {
                    Image(systemName: "lock.shield").font(.system(size: 64))
                        .accessibilityLabel("Feedarr")
                }
                Text("Feedarr").font(.title2.bold())
                if security.isEnabled && security.isLocked {
                    Button("Déverrouiller") { security.unlock() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!security.canUnlock)
                    if security.isAuthenticating { ProgressView() }
                    if let message = security.errorMessage {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(32)
        }
        .preferredColorScheme(appearance.colorScheme)
    }
}
