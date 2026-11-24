import Foundation
import Observation

@MainActor
@Observable
final class QBittorrentServerEditorModel {
    enum State: Equatable { case ready, verifying, success, failure(String) }
    var name: String { didSet { if oldValue != name { configurationChanged() } } }
    var serverURL: String {
        didSet {
            guard oldValue != serverURL else { return }
            // A changed base path may route to another service on the same origin too.
            if (try? QBittorrentServerURL.normalize(oldValue)) != (try? QBittorrentServerURL.normalize(serverURL)) {
                username = ""
                password = ""
            }
            configurationChanged()
        }
    }
    var username = "" { didSet { if oldValue != username { configurationChanged() } } }
    var password = "" { didSet { if oldValue != password { configurationChanged() } } }
    private(set) var state: State = .ready
    private(set) var isLoadingCredentials = false
    private(set) var isSaving = false
    private(set) var didSave = false
    private(set) var errorMessage: String?
    private(set) var versions: QBittorrentServerVersions?
    let editingSource: QBittorrentSource?
    @ObservationIgnored private let manager: QBittorrentSourcesManager
    @ObservationIgnored private let validator: QBittorrentConnectionValidator
    @ObservationIgnored private let draftID: UUID
    @ObservationIgnored private let initialManagerRevision: UUID
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var validated: QBittorrentValidatedConfiguration?
    @ObservationIgnored private var verificationTask: Task<Void, Never>?
    @ObservationIgnored private var credentialsLoaded = false

    init(manager: QBittorrentSourcesManager, validator: QBittorrentConnectionValidator = .init(),
         editingSource: QBittorrentSource? = nil) {
        self.manager = manager
        self.validator = validator
        self.editingSource = editingSource
        draftID = editingSource?.id ?? UUID()
        name = editingSource?.name ?? ""
        serverURL = editingSource?.serverURL.absoluteString ?? ""
        initialManagerRevision = manager.configurationRevision
    }

    var isVerifying: Bool { state == .verifying }
    var canVerify: Bool { !isVerifying && !isSaving && !isLoadingCredentials && !didSave && fieldValidationMessage == nil }
    var canSave: Bool {
        state == .success && validated != nil && !isSaving && !didSave && fieldValidationMessage == nil &&
            manager.configurationRevision == initialManagerRevision
    }
    var fieldValidationMessage: String? {
        do { _ = try candidate(); _ = try QBittorrentCredentials(username: username, password: password); return nil }
        catch { return QBittorrentError.message(for: error) }
    }

    func loadCredentials() {
        guard !credentialsLoaded else { return }
        credentialsLoaded = true
        guard let editingSource else { return }
        isLoadingCredentials = true
        defer { isLoadingCredentials = false }
        do {
            let value = try manager.credentials(for: editingSource.id)
            username = value.username
            password = value.password
        } catch { errorMessage = QBittorrentError.message(for: error) }
    }

    func startVerification() {
        guard canVerify else { return }
        // Set synchronously to prevent multiple tasks from a double tap.
        state = .verifying
        validated = nil
        versions = nil
        errorMessage = nil
        let token = revision
        verificationTask = Task { await verify(token: token) }
    }

    private func verify(token: UUID) async {
        do {
            guard manager.configurationRevision == initialManagerRevision else { throw QBittorrentError.obsoleteResponse }
            let result = try await validator.validate(source: candidate(),
                credentials: QBittorrentCredentials(username: username, password: password))
            try Task.checkCancellation()
            guard token == revision else { return }
            guard manager.configurationRevision == initialManagerRevision else { throw QBittorrentError.obsoleteResponse }
            validated = result
            versions = result.versions
            state = .success
        } catch {
            guard token == revision else { return }
            validated = nil
            state = Task.isCancelled ? .ready : .failure(QBittorrentError.message(for: error))
        }
    }

    func cancelValidation() {
        revision = UUID()
        verificationTask?.cancel()
        verificationTask = nil
        validated = nil
        versions = nil
        state = .ready
    }

    func save() async -> Bool {
        guard canSave, let validated else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try Task.checkCancellation()
            try manager.save(validated, replacing: editingSource?.id, expectedRevision: initialManagerRevision)
            didSave = true
            return true
        } catch { errorMessage = QBittorrentError.message(for: error); return false }
    }

    private func candidate() throws -> QBittorrentSource {
        try QBittorrentSource(id: draftID, name: name, serverURL: serverURL,
                             dateAdded: editingSource?.dateAdded ?? Date())
    }

    private func configurationChanged() { cancelValidation(); errorMessage = nil }
}
