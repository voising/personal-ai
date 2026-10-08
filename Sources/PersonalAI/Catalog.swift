import Foundation

struct CatalogModel: Codable, Identifiable {
    let id: String          // Ollama tag, e.g. "gemma3:12b"
    let name: String
    let sizeGB: Double      // download size
    let minRAMGB: Double    // smallest Mac it stays responsive on
    let appleSiliconOnly: Bool
    let rank: Int           // higher is better quality
    let tested: Bool        // benchmarked with scripts/bench.sh
}

struct Catalog: Codable {
    let version: Int
    let models: [CatalogModel]

    /// Override file first (lets us ship a new list without a new app), then the bundled one.
    static func load() -> Catalog {
        let override = AppPaths.support.appendingPathComponent("models.json")
        for url in [override, Bundle.main.url(forResource: "models", withExtension: "json")].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(Catalog.self, from: data) {
                return catalog
            }
        }
        return Catalog(version: 0, models: [
            CatalogModel(id: "gemma3:1b", name: "Gemma 3 1B", sizeGB: 0.8, minRAMGB: 4,
                         appleSiliconOnly: false, rank: 10, tested: false)
        ])
    }

    /// Best-ranked model that fits in memory and on disk. Keeps 2 GB of disk spare.
    func best(for hw: Hardware) -> CatalogModel? {
        models
            .filter { $0.minRAMGB <= hw.ramGB && (hw.appleSilicon || !$0.appleSiliconOnly) && $0.sizeGB + 2 <= hw.freeDiskGB }
            .max { $0.rank < $1.rank }
    }
}

enum AppPaths {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersonalAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let models = support.appendingPathComponent("models", isDirectory: true)
    static let log = support.appendingPathComponent("ollama.log")
}
