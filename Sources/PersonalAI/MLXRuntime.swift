import CryptoKit
import Foundation

/// Ollama's MLX engine is ~200 MB per Metal version, so the app ships without it and
/// downloads the one build this Mac needs, only when the chosen model runs on MLX.
///
/// Ollama only looks for `mlx_metal_v*` next to its own (symlink-resolved) executable, and
/// the signed app bundle is read-only. So the MLX build goes into a runtime folder in
/// Application Support, together with a copy of the `ollama` binary and symlinks to the
/// rest of the bundled libraries, and Ollama runs from there.
enum MLXRuntime {
    struct Manifest: Decodable {
        struct Variant: Decodable { let url: URL; let sha256: String }
        let ollama: String                 // bundled Ollama version, e.g. "v0.40.0"
        let variants: [String: Variant]    // "mlx_metal_v3" / "mlx_metal_v4"
    }

    /// Metal 4 builds need macOS 26 or later (same rule as Ollama's isCompatibleMLXVariant).
    static var variantName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? "mlx_metal_v4" : "mlx_metal_v3"
    }

    /// Returns the `ollama` executable to run, preparing the runtime folder first.
    /// `progress` gets a 0...1 fraction while the MLX build downloads.
    static func prepare(bundleDir: URL, progress: @escaping @MainActor (Double?) -> Void) async throws -> URL {
        guard let url = Bundle.main.url(forResource: "mlx", withExtension: "json"),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)),
              let variant = manifest.variants[variantName] else {
            throw error("This build of Personal AI has no MLX download information.")
        }
        let fm = FileManager.default
        let dir = AppPaths.runtime.appendingPathComponent(manifest.ollama, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Older runtime versions left behind by an app update.
        for old in (try? fm.contentsOfDirectory(at: AppPaths.runtime, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent != manifest.ollama {
            try? fm.removeItem(at: old)
        }

        let mlxDir = dir.appendingPathComponent(variantName, isDirectory: true)
        if !fm.fileExists(atPath: mlxDir.appendingPathComponent("libmlxc.dylib").path) {
            try await download(variant, into: dir, progress: progress)
        }

        // A real copy of the binary (so its directory is this folder), symlinks for everything else.
        let binary = dir.appendingPathComponent("ollama")
        let bundled = bundleDir.appendingPathComponent("ollama")
        if fileSize(binary) != fileSize(bundled) {
            try? fm.removeItem(at: binary)
            try fm.copyItem(at: bundled, to: binary)
        }
        for item in try fm.contentsOfDirectory(at: bundleDir, includingPropertiesForKeys: nil)
        where item.lastPathComponent != "ollama" {
            let link = dir.appendingPathComponent(item.lastPathComponent)
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != item.path {
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(at: link, withDestinationURL: item)
            }
        }
        return binary
    }

    private static func download(_ variant: Manifest.Variant, into dir: URL, progress: @escaping @MainActor (Double?) -> Void) async throws {
        await progress(nil)
        let (tmp, response) = try await URLSession.shared.download(from: variant.url, delegate: ProgressDelegate(progress))
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw error("Could not download the MLX engine (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }

        var hasher = SHA256()
        let file = try FileHandle(forReadingFrom: tmp)
        while let chunk = try file.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        try file.close()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == variant.sha256.lowercased() else {
            throw error("The MLX engine download was corrupted. Try again later.")
        }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", tmp.path, dir.path]
        try unzip.run(); unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw error("Could not unpack the MLX engine.") }
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
        let report: @MainActor (Double?) -> Void
        init(_ report: @escaping @MainActor (Double?) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
            Task { @MainActor in report(fraction) }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "PersonalAI", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
