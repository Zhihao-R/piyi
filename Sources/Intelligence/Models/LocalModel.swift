import Foundation
import CryptoKit

/// 本机向量模型文件：不放进安装包，在设置里点「下载」时存进资料库目录的 models/ 下。
/// 下载源实测（2026-10）hf-mirror 和 ModelScope 都约 4～5 MB/秒；先用 ModelScope（Qwen 官方所在的站，长期更稳），不通再换 hf-mirror
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

    /// 下载并校验，成功后才放到正式位置。progress 是 0～1
    public static func download(to root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let target = file(in: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lastError: Error = Failure(message: "下载失败")
        for source in sources {
            do {
                let temporary = try await fetch(URL(string: source)!, progress: progress)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard try checksum(temporary) == sha256 else { throw Failure(message: "下载的文件不完整，请重试") }
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

    /// 下载到临时文件，边下边报进度
    private static func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: url) { file, response, error in
                    if let error { return continuation.resume(throwing: error) }
                    guard let file, (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else {
                        return continuation.resume(throwing: Failure(message: "下载源返回错误"))
                    }
                    // 回调结束后系统会删掉这个文件，先挪走
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
