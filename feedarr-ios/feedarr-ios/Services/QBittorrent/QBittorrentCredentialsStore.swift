//
//  QBittorrentCredentialsStore.swift
//  Yattee
//
//  Stores QBittorrent WebUI credentials in a dedicated Keychain service.
//

import Foundation
import Security

nonisolated struct QBittorrentCredentials: Codable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let username: String
    let password: String

    init(username: String, password: String) throws {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QBittorrentCredentialsStoreError.incompleteCredentials
        }
        self.username = username
        self.password = password
    }

    var description: String { "QBittorrentCredentials(redacted)" }
    var debugDescription: String { description }

    private enum CodingKeys: String, CodingKey {
        case username, password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                username: container.decode(String.self, forKey: .username),
                password: container.decode(String.self, forKey: .password)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .username,
                in: container,
                debugDescription: "Incomplete QBittorrent credentials"
            )
        }
    }
}

nonisolated enum QBittorrentCredentialsStoreError: Error, LocalizedError, Equatable, Sendable {
    case incompleteCredentials
    case encodingFailed
    case invalidStoredData
    case keychainFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .incompleteCredentials:
            return "QBittorrent credentials require both a username and a password."
        case .encodingFailed:
            return "The QBittorrent credentials could not be encoded."
        case .invalidStoredData:
            return "The stored QBittorrent credentials are invalid."
        case .keychainFailure:
            return "The local QBittorrent credential store is unavailable."
        }
    }
}

@MainActor
protocol QBittorrentCredentialsStoring: AnyObject {
    func credentials(for sourceID: UUID) throws -> QBittorrentCredentials?
    func setCredentials(_ credentials: QBittorrentCredentials, for sourceID: UUID) throws
    func deleteCredentials(for sourceID: UUID) throws
}

@MainActor
protocol QBittorrentKeychainAccessing: AnyObject {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

@MainActor
final class SystemQBittorrentKeychain: QBittorrentKeychainAccessing {
    func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw QBittorrentCredentialsStoreError.keychainFailure(status)
        }
        return data
    }

    func write(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw QBittorrentCredentialsStoreError.keychainFailure(updateStatus)
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw QBittorrentCredentialsStoreError.keychainFailure(addStatus)
        }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw QBittorrentCredentialsStoreError.keychainFailure(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

@MainActor
final class QBittorrentCredentialsStore: QBittorrentCredentialsStoring {
    static let serviceName = "com.app.feedarr.qbittorrent.webui.v1"

    private let keychain: QBittorrentKeychainAccessing
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        keychain = SystemQBittorrentKeychain()
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    init(
        keychain: QBittorrentKeychainAccessing,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.keychain = keychain
        self.encoder = encoder
        self.decoder = decoder
    }

    func credentials(for sourceID: UUID) throws -> QBittorrentCredentials? {
        guard let data = try keychain.read(
            service: Self.serviceName,
            account: sourceID.uuidString
        ) else {
            return nil
        }
        do {
            return try decoder.decode(QBittorrentCredentials.self, from: data)
        } catch {
            throw QBittorrentCredentialsStoreError.invalidStoredData
        }
    }

    func setCredentials(_ credentials: QBittorrentCredentials, for sourceID: UUID) throws {
        let data: Data
        do {
            data = try encoder.encode(credentials)
        } catch {
            throw QBittorrentCredentialsStoreError.encodingFailed
        }
        try keychain.write(data, service: Self.serviceName, account: sourceID.uuidString)
    }

    func deleteCredentials(for sourceID: UUID) throws {
        try keychain.delete(service: Self.serviceName, account: sourceID.uuidString)
    }
}
