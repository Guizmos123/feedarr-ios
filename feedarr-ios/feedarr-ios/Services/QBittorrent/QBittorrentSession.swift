import Foundation

nonisolated protocol QBittorrentHTTPTransport: Sendable {
    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse)
    func invalidate()
}

/// Each instance owns a fresh ephemeral session. Cookies are managed explicitly by QBittorrentSession.
nonisolated final class QBittorrentURLSessionTransport: QBittorrentHTTPTransport, Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: QBittorrentSessionDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }
    func invalidate() { session.invalidateAndCancel() }

    @concurrent
    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw QBittorrentError.invalidResponse }
        guard !(300...399).contains(response.statusCode), response.url == request.url else {
            throw QBittorrentError.redirectForbidden
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw QBittorrentError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw QBittorrentError.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }
}

nonisolated private final class QBittorrentSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Also reject same-origin redirects: never replay a credential-bearing POST at another path.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            // WebUI credentials must never answer a proxy / HTTP Basic authentication challenge.
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Shared across temporary validation sessions too, preventing repeated failed tests from hammering login.
actor QBittorrentLoginGate {
    nonisolated static let shared = QBittorrentLoginGate()
    private var blockedUntil: [String: Date] = [:]
    private var inFlight: Set<String> = []

    func begin(origin: String) throws {
        let now = Date()
        blockedUntil = blockedUntil.filter { $0.value > now }
        guard !inFlight.contains(origin), blockedUntil[origin] == nil else { throw QBittorrentError.loginThrottled }
        inFlight.insert(origin)
    }

    func finish(origin: String, succeeded: Bool) {
        inFlight.remove(origin)
        // Success is also paced. A failure (including an ambiguous network result) never retries automatically.
        blockedUntil[origin] = Date().addingTimeInterval(succeeded ? 2 : 60)
    }
}

/// Actor-local cookies cannot leak to another server, even on the same host or port.
actor QBittorrentSession {
    private let baseURL: URL
    private let credentials: QBittorrentCredentials
    private let transport: any QBittorrentHTTPTransport
    private let loginGate: QBittorrentLoginGate
    private var cookies: [HTTPCookie] = []
    private var invalidated = false
    private var busy = false
    private var authenticationBlocked = false

    init(baseURL: URL, credentials: QBittorrentCredentials,
         transport: any QBittorrentHTTPTransport = QBittorrentURLSessionTransport(),
         loginGate: QBittorrentLoginGate = .shared) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.transport = transport
        self.loginGate = loginGate
    }

    func invalidate() {
        invalidated = true
        cookies = []
        transport.invalidate()
    }

    /// Read-only version probes; one reconnect is allowed only for an already established session.
    func versions() async throws -> QBittorrentServerVersions {
        guard !busy else { throw QBittorrentError.loginThrottled }
        busy = true
        defer { busy = false }
        try checkValidity()
        guard !authenticationBlocked else { throw QBittorrentError.authenticationFailed }
        let hadSession = !cookies.isEmpty
        if !hadSession { try await login() }
        do {
            return try await readVersions()
        } catch QBittorrentError.accessDenied where hadSession {
            cookies = []
            try await login()
            do { return try await readVersions() }
            catch {
                if (error as? QBittorrentError) == .accessDenied { authenticationBlocked = true; cookies = [] }
                throw error
            }
        } catch QBittorrentError.accessDenied {
            authenticationBlocked = true
            cookies = []
            throw QBittorrentError.accessDenied
        }
    }

    private func readVersions() async throws -> QBittorrentServerVersions {
        let application = try await request(path: ["app", "version"])
        let api = try await request(path: ["app", "webapiVersion"])
        try checkValidity()
        return try QBittorrentServerVersions(application: application.0, api: api.0)
    }

    private func login() async throws {
        try checkValidity()
        let origin = QBittorrentServerURL.origin(baseURL)
        try await loginGate.begin(origin: origin)
        do {
            cookies = []
            let (data, response) = try await request(path: ["auth", "login"], form: [
                ("username", credentials.username), ("password", credentials.password)
            ])
            guard String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "Ok." else {
                throw QBittorrentError.authenticationFailed
            }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
                if let key = entry.key as? String, let value = entry.value as? String { result[key] = value }
            }
            let received = HTTPCookie.cookies(withResponseHeaderFields: headers, for: baseURL)
            cookies = received.filter { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
                let host = (baseURL.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                return (domain == host || host.hasSuffix("." + domain)) && !cookie.value.isEmpty &&
                    (cookie.expiresDate.map { $0 > Date() } ?? true) && (!cookie.isSecure || baseURL.scheme == "https")
            }
            guard !cookies.isEmpty else { throw QBittorrentError.authenticationFailed }
            try checkValidity()
            await loginGate.finish(origin: origin, succeeded: true)
        } catch {
            cookies = []
            // Further automatic callers must not keep submitting rejected credentials.
            // An explicit configuration test/save creates a fresh session instead.
            if (error as? QBittorrentError) == .authenticationFailed || (error as? QBittorrentError) == .accessDenied {
                authenticationBlocked = true
            }
            await loginGate.finish(origin: origin, succeeded: false)
            throw error
        }
    }

    private func request(path: [String], form: [(String, String)]? = nil) async throws -> (Data, HTTPURLResponse) {
        try checkValidity()
        let url = (["api", "v2"] + path).reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = form == nil ? "GET" : "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue(QBittorrentServerURL.origin(baseURL), forHTTPHeaderField: "Origin")
        request.setValue(baseURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        let applicable = cookies.filter {
            let path = url.path
            let cookiePath = $0.path
            return ($0.expiresDate.map { $0 > Date() } ?? true) &&
                (path == cookiePath || path.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/"))
        }
        if !applicable.isEmpty {
            request.setValue(HTTPCookie.requestHeaderFields(with: applicable)["Cookie"], forHTTPHeaderField: "Cookie")
        }
        if let form {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            request.httpBody = Data(form.map {
                "\($0.0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
            }.joined(separator: "&").utf8)
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let result = try await transport.data(for: request, maximumBytes: 4096)
        try checkValidity()
        guard result.0.count <= 4096 else { throw QBittorrentError.responseTooLarge }
        guard result.1.url == url, !(300...399).contains(result.1.statusCode) else {
            throw QBittorrentError.redirectForbidden
        }
        switch result.1.statusCode {
        case 200: return result
        case 401, 403: throw QBittorrentError.accessDenied
        default: throw QBittorrentError.httpStatus(result.1.statusCode)
        }
    }

    private func checkValidity() throws {
        try Task.checkCancellation()
        guard !invalidated else { throw QBittorrentError.obsoleteResponse }
    }
}
