import Foundation
import Security

protocol TfLAPIKeyStoring: Sendable {
    func load() async throws -> String?
    func save(_ apiKey: String?) async throws
}

struct KeychainTfLAPIKeyStore: TfLAPIKeyStoring, Sendable {
    private let service: String
    private let account = "tfl-api-key"

    init(service: String = Bundle.main.bundleIdentifier ?? "dev.skynolimit.TubeTrackUK") {
        self.service = service
    }

    func load() async throws -> String? {
        try await Task.detached {
            try loadSynchronously()
        }.value
    }

    func save(_ apiKey: String?) async throws {
        try await Task.detached {
            try saveSynchronously(apiKey)
        }.value
    }

    private func loadSynchronously() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw TfLAPIKeyStoreError.unreadableValue
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw TfLAPIKeyStoreError.keychain(status)
        }
    }

    private func saveSynchronously(_ apiKey: String?) throws {
        guard let apiKey else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TfLAPIKeyStoreError.keychain(status)
            }
            return
        }

        let encodedKey = Data(apiKey.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: encodedKey] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw TfLAPIKeyStoreError.keychain(updateStatus)
        }

        var attributes = baseQuery
        attributes[kSecValueData as String] = encodedKey
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TfLAPIKeyStoreError.keychain(addStatus)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum TfLAPIKeyStoreError: LocalizedError, Sendable {
    case unreadableValue
    case keychain(OSStatus)

    var errorDescription: String? {
        "The TfL API key could not be saved securely. Please try again."
    }
}

enum TfLAPIKeyValidationError: LocalizedError, Sendable {
    case empty

    var errorDescription: String? {
        "Enter a TfL API key before saving."
    }
}
