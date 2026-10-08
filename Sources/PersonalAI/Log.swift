import Foundation

/// The app's own log, `~/Library/Application Support/PersonalAI/personalai.log`.
/// Errors only show in the menu otherwise, so this is what a user sends when a launch fails.
enum Log {
    static let url = AppPaths.support.appendingPathComponent("personalai.log")
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }

    /// Records state changes, skipping download progress ticks.
    static func state(_ new: Runtime.State, previous: Runtime.State) {
        switch (new, previous) {
        case let (.downloading(status, _), .downloading(old, _)) where status == old:
            return
        case let (.downloading(status, _), _):
            write("downloading: \(status)")
        case let (.failed(message), _):
            write("FAILED: \(message)")
        case (.ready, _):
            write("ready")
        case (.starting, _):
            write("starting, version \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        }
    }
}
