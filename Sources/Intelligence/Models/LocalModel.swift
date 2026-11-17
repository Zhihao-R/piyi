import Foundation
import CryptoKit

/// Local embedding model file: not shipped in the app, saved under models/ in the library folder when you click "Download" in Settings.
/// Download sources measured (2026-10): hf-mirror and ModelScope both about 4–5 MB/s; ModelScope first (Qwen's official home, more stable long-term), falling back to hf-mirror if unreachable
public enum LocalModel {
    public static let name = "Qwen3-Embedding-0.6B-Q8_0"
    static let fileName = name + ".gguf"
    public static let size: Int64 = 639_150_592
    static let sha256 = "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439"
    static let sources = [
        "https://modelscope.cn/models/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/master/\(fileName)",
        "https://hf-mirror.com/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/main/\(fileName)",
    ]

    public static func file(in root: URL) -> URL {
        root.appending(path: "models/\(fileName)")
    }

    public struct Failure: LocalizedError {
        let message: String
        public var errorDescription: String? { message }
    }

    /// Download and verify; only moved into its final place on success. progress is 0–1
    public static func download(to root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let target = file(in: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lastError: Error = Failure(message: String(localized: "下载失败"))
        for source in sources {
            do {
                let temporary = try await fetch(URL(string: source)!, progress: progress)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard try checksum(temporary) == sha256 else { throw Failure(message: String(localized: "下载的文件不完整，请重试")) }
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Download to a temporary file, reporting progress along the way
    private static func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: url) { file, response, error in
                    if let error { return continuation.resume(throwing: error) }
                    guard let file, (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else {
                        return continuation.resume(throwing: Failure(message: String(localized: "下载源返回错误")))
                    }
                    // The system deletes this file after the callback ends, so move it first
                    let kept = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".gguf")
                    do { try FileManager.default.moveItem(at: file, to: kept); continuation.resume(returning: kept) } catch { continuation.resume(throwing: error) }
                }
                box.observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionDownloadTask?
        var observation: NSKeyValueObservation?
    }

    private static func checksum(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
