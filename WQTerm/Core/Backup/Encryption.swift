import Foundation
import Security
import CryptoKit

/// Encryption cho backup: CryptoKit AES-GCM, key lưu Keychain (PRD Module 3).
final class Encryption {
    static let shared = Encryption()
    private let keychain = KeychainService.shared

    private init() {}

    var symmetricKey: SymmetricKey {
        get throws {
            // Lấy key từ Keychain, nếu chưa có thì sinh mới
            if let data = try? keychain.read(key: "WQTerm.BackupKey") {
                return SymmetricKey(data: data)
            }
            let newKey = SymmetricKey(size: .bits256)
            try keychain.write(key: "WQTerm.BackupKey", data: newKey.withUnsafeBytes { Data($0) })
            return newKey
        }
    }

    func encrypt(_ data: Data) throws -> Data {
        let key = try symmetricKey
        let box = try AES.GCM.seal(data, using: key)
        guard let combined = box.combined else { throw CocoaError(.coderInvalidValue) }
        return combined
    }

    func decrypt(_ data: Data) throws -> Data {
        let key = try symmetricKey
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }
}

// MARK: - KeychainService (giúp đọc ghi Keychain đơn giản)

final class KeychainService {
    static let shared = KeychainService()
    private init() {}

    func write(key: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw BackupError.keychainFailure(status: Int(status)) }
    }

    func read(key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw BackupError.keychainFailure(status: Int(status)) }
        return item as? Data
    }
}

enum BackupError: LocalizedError {
    case keychainFailure(status: Int)
    case snapshotLimitExceeded
    case fileTooLarge
    case restoreCancelled

    var errorDescription: String? {
        switch self {
        case .keychainFailure(let status): return "Keychain lỗi: \(status)"
        case .snapshotLimitExceeded: return "Vượt quá giới hạn snapshot tổng 2GB."
        case .fileTooLarge: return "File quá lớn (>100MB), không backup."
        case .restoreCancelled: return "Restore bị hủy bởi người dùng."
        }
    }
}
