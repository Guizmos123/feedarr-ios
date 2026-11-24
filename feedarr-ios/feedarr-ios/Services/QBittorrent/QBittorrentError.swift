import Foundation

nonisolated enum QBittorrentError: Error, LocalizedError, Equatable, Sendable {
    case invalidName, invalidURL, insecureRemoteHTTP, incompleteCredentials
    case sourceNotFound, configurationUnavailable, credentialsUnavailable, persistenceFailure, rollbackFailure
    case authenticationFailed, accessDenied, loginThrottled, incompatibleServer
    case redirectForbidden, responseTooLarge, invalidResponse, obsoleteResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidName: "Le nom du serveur est obligatoire."
        case .invalidURL: "L’URL qBittorrent est invalide. Utilisez l’URL de base de la WebUI, sans identifiants, paramètres ni fragment."
        case .insecureRemoteHTTP: "HTTP est réservé au réseau local. Utilisez HTTPS pour ce serveur."
        case .incompleteCredentials: "Renseignez le nom d’utilisateur et le mot de passe de la WebUI."
        case .sourceNotFound: "Le serveur qBittorrent est introuvable."
        case .configurationUnavailable: "La configuration qBittorrent est indisponible."
        case .credentialsUnavailable: "Les identifiants qBittorrent sont manquants ou le Keychain est indisponible."
        case .persistenceFailure: "Le serveur qBittorrent n’a pas pu être enregistré."
        case .rollbackFailure: "La configuration n’a pas pu être restaurée. Fermez puis rouvrez les Sources avant de réessayer."
        case .authenticationFailed: "Les identifiants WebUI ont été refusés. Vérifiez-les avant de réessayer."
        case .accessDenied: "Accès refusé : vérifiez la WebUI, le proxy et un éventuel bannissement."
        case .loginThrottled: "Une connexion est en cours ou a échoué récemment. Patientez avant de réessayer."
        case .incompatibleServer: "Serveur incompatible : qBittorrent 4.6.x ou 5.x avec WebAPI v2 est requis."
        case .redirectForbidden: "Redirection refusée. Renseignez directement l’URL finale de la WebUI."
        case .responseTooLarge, .invalidResponse: "La WebUI a renvoyé une réponse invalide ou trop volumineuse."
        case .obsoleteResponse: "La configuration a changé pendant la connexion. Testez-la à nouveau."
        case .httpStatus(let code): "La WebUI a renvoyé le statut HTTP \(code)."
        }
    }

    static func message(for error: any Error) -> String {
        if let error = error as? QBittorrentError { return error.localizedDescription }
        if let error = error as? QBittorrentCredentialsStoreError {
            return (error == .incompleteCredentials ? QBittorrentError.incompleteCredentials :
                QBittorrentError.credentialsUnavailable).localizedDescription
        }
        if error is CancellationError { return "La vérification a été annulée." }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return "La vérification a été annulée."
            case .timedOut: return "Le délai de connexion est dépassé."
            case .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected,
                 .clientCertificateRequired:
                return "Le certificat HTTPS n’est pas valide ou approuvé par cet iPhone."
            case .appTransportSecurityRequiresSecureConnection:
                return "Cette adresse HTTP est bloquée par iOS. Utilisez HTTPS ou une adresse locale autorisée."
            default: break
            }
        }
        // Never surface URLSession diagnostics, server bodies, URLs or credentials.
        return "Le serveur qBittorrent est injoignable. Vérifiez l’adresse et l’accès au réseau local."
    }
}
