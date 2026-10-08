import Foundation
import ServiceManagement

/// Runs Ollama on the standard port so any Ollama client finds it,
/// then makes sure the best model for this Mac is downloaded.
/// Ollama itself loads the model on the first request and unloads it after
/// `OLLAMA_KEEP_ALIVE` of idle time, so RAM is only used while someone asks.
/// On a macOS memory-pressure warning it unloads the model right away.
@MainActor
final class Runtime: ObservableObject {
    enum State: Equatable {
        case starting
        case downloading(status: String, fraction: Double?)
        case ready
        case failed(String)
    }

    /// 11434 is Ollama's standard port, which apps look for. PERSONALAI_PORT overrides it for testing.
    static let port = Int(ProcessInfo.processInfo.environment["PERSONALAI_PORT"] ?? "") ?? 11434
    static let base = URL(string: "http://127.0.0.1:\(port)")!

    @Published private(set) var state: State = .starting {
        didSet { Log.state(state, previous: oldValue) }
    }
    @Published private(set) var model: CatalogModel?
    @Published private(set) var adoptedExternal = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    let hardware = Hardware.current()
    private var process: Process?
    private var memoryPressure: DispatchSourceMemoryPressure?

    func start() {
        watchMemoryPressure()
        Task { await boot() }
    }

    func stop() {
        memoryPressure?.cancel()
        process?.terminate()
        process = nil
    }

    /// Frees the model's RAM as soon as macOS reports memory is getting tight.
    /// Works for an adopted external Ollama too, since it goes through the API.
    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { await self?.unloadAll() }
        }
        source.resume()
        memoryPressure = source
    }

    private struct Loaded: Decodable { struct M: Decodable { let name: String }; let models: [M] }

    func unloadAll() async {
        guard let (data, _) = try? await URLSession.shared.data(from: Self.base.appendingPathComponent("api/ps")),
              let loaded = try? JSONDecoder().decode(Loaded.self, from: data) else { return }
        for m in loaded.models {
            var req = URLRequest(url: Self.base.appendingPathComponent("api/generate"))
            req.httpMethod = "POST"
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": m.name, "keep_alive": 0])
            _ = try? await URLSession.shared.data(for: req)
            NSLog("PersonalAI: unloaded \(m.name) on memory pressure")
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("PersonalAI: login item: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Boot

    private func boot() async {
        state = .starting
        guard let chosen = Catalog.load().best(for: hardware) else {
            state = .failed("No model fits this Mac (\(Int(hardware.ramGB)) GB RAM, \(Int(hardware.freeDiskGB)) GB free).")
            return
        }
        model = chosen
        Log.write("Mac: \(hardware.chip), \(Int(hardware.ramGB)) GB RAM, \(Int(hardware.freeDiskGB)) GB free; model: \(chosen.id)")

        if await isServing() {
            adoptedExternal = true          // the user's own Ollama is already running: reuse it
            Log.write("reusing the Ollama already running on port \(Self.port)")
        } else {
            do {
                let binary = try await ollamaBinary(for: chosen)
                try launchServer(binary)
            } catch {
                state = .failed("Could not start Ollama: \(error.localizedDescription)")
                return
            }
            guard await waitUntilServing() else {
                state = .failed("Ollama did not start. See \(AppPaths.log.path).")
                return
            }
        }

        do {
            if try await installedModels().contains(chosen.id) == false {
                try await pullWithRetry(chosen.id)
            }
            state = .ready
        } catch {
            state = .failed("Download failed: \(error.localizedDescription)")
        }
    }

    /// The bundled Ollama, run from a runtime folder with the MLX engine when the model needs it.
    private func ollamaBinary(for model: CatalogModel) async throws -> URL {
        if model.needsMLX, let bundleDir = Bundle.main.resourceURL?.appendingPathComponent("ollama"),
           FileManager.default.fileExists(atPath: bundleDir.appendingPathComponent("ollama").path) {
            return try await MLXRuntime.prepare(bundleDir: bundleDir) { [weak self] fraction in
                self?.state = .downloading(status: "Downloading the MLX engine (about 200 MB)", fraction: fraction)
            }
        }
        guard let binary = fallbackBinary() else {
            throw NSError(domain: "PersonalAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ollama binary is missing from the app."])
        }
        return binary
    }

    private func fallbackBinary() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("ollama/ollama"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ollama"),
            URL(fileURLWithPath: "/usr/local/bin/ollama"),
            URL(fileURLWithPath: "/Applications/Ollama.app/Contents/Resources/ollama"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func launchServer(_ binary: URL) throws {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_HOST"] = "127.0.0.1:\(Self.port)"      // never listen beyond this Mac
        env["OLLAMA_MODELS"] = AppPaths.models.path
        env["OLLAMA_KEEP_ALIVE"] = "5m"
        env["OLLAMA_MAX_LOADED_MODELS"] = "1"
        p.environment = env
        // Append across launches, so a failed first run is still there to read afterwards.
        if !FileManager.default.fileExists(atPath: AppPaths.log.path) {
            FileManager.default.createFile(atPath: AppPaths.log.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: AppPaths.log)
        log.seekToEndOfFile()
        log.write(Data("\n=== Personal AI \(Log.version) starting \(binary.path) at \(Date()) ===\n".utf8))
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.process = nil
                self.state = .failed("Ollama stopped (exit \(proc.terminationStatus)). See \(AppPaths.log.path).")
            }
        }
        try p.run()
        process = p
    }

    // MARK: - Ollama API

    private func isServing() async -> Bool {
        var req = URLRequest(url: Self.base.appendingPathComponent("api/version"))
        req.timeoutInterval = 1
        return (try? await URLSession.shared.data(for: req)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
    }

    private func waitUntilServing() async -> Bool {
        for _ in 0..<40 {
            if await isServing() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }

    private func installedModels() async throws -> Set<String> {
        let (data, _) = try await URLSession.shared.data(from: Self.base.appendingPathComponent("api/tags"))
        return Set(try JSONDecoder().decode(Tags.self, from: data).models.map(\.name))
    }

    /// Model downloads are several GB over flaky Wi-Fi. Ollama keeps finished parts, so each
    /// retry resumes where the last one stopped.
    private func pullWithRetry(_ id: String, attempts: Int = 5) async throws {
        for attempt in 1...attempts {
            do { return try await pull(id) } catch {
                Log.write("download attempt \(attempt) failed: \(error.localizedDescription)")
                guard attempt < attempts else { throw error }
                let wait = 10 * attempt
                state = .downloading(status: "Connection lost. Retrying in \(wait) s", fraction: nil)
                try await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Menu "Try again" after a failure.
    func retry() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        Task { await boot() }
    }

    private struct PullLine: Decodable { let status: String?; let total: Int64?; let completed: Int64?; let error: String? }

    private func pull(_ id: String) async throws {
        var req = URLRequest(url: Self.base.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": id, "stream": true])
        req.timeoutInterval = 60 * 60
        let (bytes, _) = try await URLSession.shared.bytes(for: req)
        state = .downloading(status: "Starting download", fraction: nil)
        for try await line in bytes.lines {
            guard let msg = try? JSONDecoder().decode(PullLine.self, from: Data(line.utf8)) else { continue }
            if let error = msg.error {
                throw NSError(domain: "PersonalAI", code: 2, userInfo: [NSLocalizedDescriptionKey: error])
            }
            let fraction = msg.total.flatMap { total in total > 0 ? Double(msg.completed ?? 0) / Double(total) : nil }
            state = .downloading(status: msg.status ?? "", fraction: fraction)
        }
    }
}
