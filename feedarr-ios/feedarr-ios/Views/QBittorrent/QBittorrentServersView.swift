import SwiftUI

struct QBittorrentServersView: View {
    let manager: QBittorrentSourcesManager
    var title = "qBittorrent"
    @State private var editor: ServerEditor?
    @State private var errorMessage: String?
    @State private var pendingDeletion: QBittorrentSource?
    @State private var showingDeleteConfirmation = false

    private struct ServerEditor: Identifiable {
        let id = UUID()
        let source: QBittorrentSource?
    }

    var body: some View {
        // Preserve the native Feedarr sources layout without changing the Feedarr screen.
        Color(uiColor: .systemGroupedBackground)
            .ignoresSafeArea()
            .overlay {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if manager.sources.isEmpty {
                            ContentUnavailableView {
                                Label("Aucune source", systemImage: "server.rack")
                            } description: {
                                Text("Ajoutez un serveur qBittorrent pour commencer.")
                            } actions: {
                                Button("Configurer un serveur") { editor = ServerEditor(source: nil) }
                                    .buttonStyle(.borderedProminent)
                            }
                        } else {
                            sectionHeader("Serveurs qBittorrent")
                            sectionCard {
                                ForEach(Array(manager.sources.enumerated()), id: \.element.id) { index, source in
                                    QBittorrentSourceListRow(isLast: index == manager.sources.count - 1) {
                                        Button { editor = ServerEditor(source: source) } label: {
                                            QBittorrentSourceRow(
                                                source: source,
                                                isActive: manager.activeSourceID == source.id,
                                                needsAuthentication: manager.activeSourceID == source.id && manager.loadError != nil
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.primary)
                                        .contextMenu {
                                            Button("Modifier / Tester", systemImage: "pencil") { editor = ServerEditor(source: source) }
                                            Button("Activer", systemImage: "checkmark.circle") {
                                                perform { try manager.select(id: source.id) }
                                            }
                                            .disabled(manager.activeSourceID == source.id)
                                            Button(role: .destructive) {
                                                pendingDeletion = source
                                                showingDeleteConfirmation = true
                                            } label: {
                                                Label("Supprimer", systemImage: "trash")
                                            }
                                        }
                                        .accessibilityAction(named: "Activer") {
                                            perform { try manager.select(id: source.id) }
                                        }
                                        .accessibilityAction(named: "Supprimer") {
                                            pendingDeletion = source
                                            showingDeleteConfirmation = true
                                        }
                                    }
                                }
                            }
                        }
                        if let error = manager.loadError {
                            sectionHeader("Configuration indisponible")
                            sectionCard {
                                QBittorrentSourceListRow(isLast: true) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(error.localizedDescription).foregroundStyle(.red)
                                        Button("Réessayer") { perform { try manager.reload() } }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
            }
            .tint(.blue)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Ajouter", systemImage: "plus") { editor = ServerEditor(source: nil) }
                }
            }
            .sheet(item: $editor) { item in
                NavigationStack {
                    QBittorrentServerEditor(manager: manager, source: item.source)
                }
                .presentationCompactAdaptation(.sheet)
            }
            .confirmationDialog(
                "Supprimer le serveur « \(pendingDeletion?.name ?? "") » ?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Supprimer", role: .destructive) {
                    guard let source = pendingDeletion else { return }
                    perform { try manager.remove(id: source.id) }
                    pendingDeletion = nil
                }
                Button("Annuler", role: .cancel) { pendingDeletion = nil }
            }
            .alert("Erreur", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
    }

    // iOS inset values copied from XTubee's sectionHeader and sectionCard.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVStack(spacing: 0) { content() }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { errorMessage = error.localizedDescription }
    }
}

/// XTubee's iOS SourceListRow, without its unused video list style dependency.
private struct QBittorrentSourceListRow<Content: View>: View {
    let isLast: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 0) {
            content()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            if !isLast {
                Rectangle()
                    .fill(Color(uiColor: .separator))
                    .frame(height: 1 / displayScale)
                    .padding(.leading, 16 + 32 + 12)
            }
        }
    }
}

/// XTubee's qbittorrentSourceRow, with the active source status for QBittorrent's multi-server list.
private struct QBittorrentSourceRow: View {
    let source: QBittorrentSource
    let isActive: Bool
    let needsAuthentication: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.headline).foregroundStyle(.primary)
                // Query parameters and credentials never enter the visible address.
                Text(source.serverURL.host ?? "QBittorrent").font(.caption).foregroundStyle(.secondary)
                if needsAuthentication {
                    Label("Vérifier l’authentification", systemImage: "key.fill")
                        .font(.caption2).foregroundStyle(.orange)
                } else {
                    Text("Configuré").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Serveur actif")
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("sources.row.qbittorrent.\(source.id.uuidString)")
    }
}

private struct QBittorrentServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: QBittorrentServerEditorModel
    @State private var saveTask: Task<Void, Never>?

    init(manager: QBittorrentSourcesManager, source: QBittorrentSource?) {
        _model = State(initialValue: QBittorrentServerEditorModel(
            manager: manager, editingSource: source
        ))
    }

    var body: some View {
        Form {
            Section("Serveur") {
                TextField("Nom", text: $model.name)
                TextField("https://qbittorrent.example.com", text: $model.serverURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                TextField("Nom d’utilisateur", text: $model.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Mot de passe", text: $model.password)
                    .textContentType(.password)
            } header: {
                Text("Authentification")
            } footer: {
                Text("Identifiants de la WebUI qBittorrent. HTTPS recommandé ; HTTP est réservé au réseau local. La connexion doit être testée avant chaque enregistrement.")
            }
            Section("Connexion") {
                status
                Button("Tester la connexion") { model.startVerification() }
                    .disabled(!model.canVerify)
            }
            Section {
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Button {
                    saveTask = Task {
                        if await model.save() { dismiss() }
                    }
                } label: {
                    HStack {
                        if model.isSaving { ProgressView() }
                        Text("Enregistrer")
                    }
                }
                .disabled(!model.canSave)
            }
        }
        .disabled(model.isSaving || model.isLoadingCredentials)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(model.editingSource == nil ? "Ajouter un serveur" : "Modifier le serveur")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(role: .cancel) {
                    model.cancelValidation()
                    saveTask?.cancel()
                    dismiss()
                } label: {
                    Label("Fermer", systemImage: "xmark").labelStyle(.iconOnly)
                }
            }
        }
        .task { model.loadCredentials() }
        .onDisappear {
            model.cancelValidation()
            saveTask?.cancel()
        }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .ready:
            Text(model.fieldValidationMessage ?? "Testez la connexion avant d’enregistrer.")
                .foregroundStyle(.secondary)
        case .verifying:
            HStack { ProgressView(); Text("Vérification…") }
        case .success:
            Label("Connexion réussie : qBittorrent \(model.versions?.application ?? "—") · API \(model.versions?.api ?? "—").", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}
