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

    /// The part downloaded so far, kept next to the model file: the next download continues from it, whether the connection dropped or the app quit
    static func partial(in root: URL) -> URL {
        file(in: root).appendingPathExtension("part")
    }

    /// A download stopped partway last time
    public static func hasPartial(in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: partial(in: root).path)
    }

    /// Download and verify; only moved into its final place on success. progress is 0–1
    public static func download(to root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let target = file(in: root), part = partial(in: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lastError: Error = Failure(message: String(localized: "下载失败"))
        for source in sources {
            do {
                // Both sources serve the same file, so the next source carries on from what the previous one got
                try await fetch(URL(string: source)!, to: part, progress: progress)
                guard try checksum(part) == sha256 else {
                    try? FileManager.default.removeItem(at: part)
                    throw Failure(message: String(localized: "下载的文件不完整，请重试"))
                }
                _ = try FileManager.default.replaceItemAt(target, withItemAt: part)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Append to the partial file, asking the server only for the bytes still missing
    private static func fetch(_ url: URL, to part: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let have = (try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        guard have < size else { return }
        var request = URLRequest(url: url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let writer = try PartWriter(file: part, have: have, progress: progress)
        let session = URLSession(configuration: .default, delegate: writer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    writer.done = continuation
                    session.dataTask(with: request).resume()
                }
            } onCancel: {
                session.invalidateAndCancel()
            }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    /// Writes each piece to the end of the partial file as it arrives. If the server ignores the range and sends the whole file, start the file over
    private final class PartWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let handle: FileHandle
        var written: Int64
        var reported = -1
        let progress: @Sendable (Double) -> Void
        var done: CheckedContinuation<Void, Error>?
        var failure: Error?

        init(file: URL, have: Int64, progress: @escaping @Sendable (Double) -> Void) throws {
            handle = try FileHandle(forWritingTo: file)
            written = have
            self.progress = progress
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 206:
                break
            case 200..<300:
                written = 0
                try? handle.truncate(atOffset: 0)
            default:
                failure = Failure(message: String(localized: "下载源返回错误"))
                return .cancel
            }
            try? handle.seek(toOffset: UInt64(written))
            return .allow
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try handle.write(contentsOf: data)
                written += Int64(data.count)
                // Pieces arrive every few dozen KB; report only when the progress moves by a thousandth
                let step = Int(Double(written) / Double(LocalModel.size) * 1000)
                if step != reported { reported = step; progress(Double(step) / 1000) }
            } catch {
                failure = error
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle.close()
            if let error = failure ?? error { done?.resume(throwing: error) } else { done?.resume() }
            done = nil
        }
    }

    private static func checksum(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
