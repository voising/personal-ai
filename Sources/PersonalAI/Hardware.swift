import Foundation

/// What the Mac can run: unified memory, chip family and free disk space.
struct Hardware {
    let ramGB: Double
    let chip: String
    let appleSilicon: Bool
    let freeDiskGB: Double

    static func current() -> Hardware {
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return Hardware(
            ramGB: ram.rounded(),
            chip: sysctlString("machdep.cpu.brand_string") ?? "Unknown chip",
            appleSilicon: sysctlInt("hw.optional.arm64") == 1,
            freeDiskGB: Double(free) / 1_000_000_000
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
