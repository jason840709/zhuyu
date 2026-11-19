import Foundation

/// App-owned files only. This type deliberately never accesses the system Keychain.
struct SecretStore: Sendable {
    let directory: URL

    private struct Snapshot: Codable {
        var schemaVersion = 1
        var revision = 0
        var keys: [String: String] = [:]
    }

    func read(_ provider: Provider) throws -> String? {
        try load()?.keys[provider.rawValue]
    }

    func save(_ value: String, for provider: Provider) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw StoreError.empty }
        var snapshot = try load() ?? Snapshot()
        guard snapshot.revision < Int.max else { throw StoreError.unreadable }
        snapshot.revision += 1
        snapshot.keys[provider.rawValue] = clean
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let url = file(snapshot.revision % 2)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else {
                    throw StoreError.writeFailed
                }
            }
            // Keep the previous complete slot. No atomic replacement, lock file or hard link.
            try data.write(to: url, options: [])
        } catch { throw StoreError.writeFailed }
    }

    private func file(_ index: Int) -> URL {
        directory.appendingPathComponent("api-keys-\(index).json")
    }

    private func load() throws -> Snapshot? {
        var valid: [Snapshot] = []
        var found = false
        for index in 0...1 {
            let url = file(index)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            found = true
            if let data = try? Data(contentsOf: url),
               let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
               snapshot.schemaVersion == 1, snapshot.revision >= 0 {
                valid.append(snapshot)
            }
        }
        if let latest = valid.max(by: { $0.revision < $1.revision }) { return latest }
        if found { throw StoreError.unreadable }
        return nil
    }

    enum StoreError: LocalizedError {
        case empty, unreadable, writeFailed
        var errorDescription: String? {
            switch self {
            case .empty: "請輸入 API 金鑰。空白輸入不會刪除已儲存的金鑰。"
            case .unreadable: "無法讀取本機 API 金鑰檔，原檔已保留。輸入內容不會被清空。"
            case .writeFailed: "API 金鑰未能儲存。請檢查 Data 資料夾的寫入權限；輸入內容已保留，可再次儲存。"
            }
        }
    }
}

/// Draft lifetime belongs to the App, so dismissing a sheet or changing providers cannot erase input.
struct APIKeyDrafts {
    private var values: [Provider: String] = [:]
    private var savedValues: [Provider: String] = [:]

    func value(for provider: Provider) -> String { values[provider] ?? "" }
    func hasChanges(_ provider: Provider) -> Bool {
        value(for: provider).trimmingCharacters(in: .whitespacesAndNewlines) != (savedValues[provider] ?? "")
    }
    func isSaved(_ provider: Provider) -> Bool {
        !(savedValues[provider] ?? "").isEmpty && !hasChanges(provider)
    }
    mutating func prepare(_ provider: Provider, read: () throws -> String?) rethrows {
        guard values[provider] == nil else { return }
        let value = try read() ?? ""
        values[provider] = value
        savedValues[provider] = value
    }
    mutating func edit(_ value: String, for provider: Provider) { values[provider] = value }
    mutating func didSave(_ value: String, for provider: Provider) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        values[provider] = clean
        savedValues[provider] = clean
    }
}
