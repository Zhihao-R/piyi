import Foundation

/// 服务方的密钥存在一个只有你能读的文件里（~/Library/Application Support/Piyi/keys.json），每个服务方一条。
/// 不用系统钥匙串：App 每次重新打包签名，钥匙串都要弹框确认，没点之前读不到密钥
public enum KeyFile {
    static let url = URL.applicationSupportDirectory.appending(path: "Piyi/keys.json")

    public static func key(for provider: String) -> String? {
        guard let data = try? Data(contentsOf: url), let keys = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return keys[provider]
    }

    /// 空字符串表示删掉
    public static func setKey(_ key: String, for provider: String) throws {
        var keys = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        keys[provider] = key.isEmpty ? nil : key
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(keys).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
