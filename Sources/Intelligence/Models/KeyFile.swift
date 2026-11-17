import Foundation

/// Provider keys are stored in a file only you can read (~/Library/Application Support/Piyi/keys.json), one entry per provider.
/// Not the system keychain: every time the app is repackaged and re-signed, the keychain asks for confirmation, and the key can't be read until you click
public enum KeyFile {
    static let url = URL.applicationSupportDirectory.appending(path: "Piyi/keys.json")

    public static func key(for provider: String) -> String? {
        guard let data = try? Data(contentsOf: url), let keys = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return keys[provider]
    }

    /// An empty string means delete
    public static func setKey(_ key: String, for provider: String) throws {
        var keys = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        keys[provider] = key.isEmpty ? nil : key
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(keys).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
