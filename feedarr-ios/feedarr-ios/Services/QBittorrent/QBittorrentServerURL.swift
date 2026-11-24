import Foundation
import Darwin

nonisolated enum QBittorrentServerURL {
    static func normalize(_ value: String) throws -> URL {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw QBittorrentError.invalidURL }
        if scheme == "http", !isLocalHost(host) { throw QBittorrentError.insecureRemoteHTTP }
        // Reject ambiguous encoded separators / traversal; keep valid reverse-proxy base paths.
        let path = parts.percentEncodedPath.lowercased()
        guard !path.contains("%2f"), !path.contains("%5c"), !path.contains("%25"),
              !path.contains("\\"),
              !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw QBittorrentError.invalidURL
        }
        parts.scheme = scheme
        parts.host = host.lowercased()
        while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        guard let url = parts.url else { throw QBittorrentError.invalidURL }
        return url
    }

    static func isLocalHost(_ raw: String) -> Bool {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let n = UInt32(bigEndian: ipv4.s_addr)
            return n >> 24 == 10 || n >> 24 == 127 || n >> 16 == 0xA9FE ||
                n >> 20 == 0xAC1 || n >> 16 == 0xC0A8
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            return withUnsafeBytes(of: ipv6) { bytes in
                (bytes[0] & 0xFE == 0xFC) || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) ||
                    (bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1)
            }
        }
        // Single-label Bonjour / LAN names and .local only; no arbitrary public HTTP domains.
        return host == "localhost" || host.hasSuffix(".local") ||
            (!host.contains(".") && !host.contains(":") &&
             host.contains(where: { $0.isLetter }) &&
             host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    }

    static func origin(_ url: URL) -> String {
        var parts = URLComponents()
        parts.scheme = url.scheme
        parts.host = url.host
        parts.port = url.port
        return parts.string ?? ""
    }
}
