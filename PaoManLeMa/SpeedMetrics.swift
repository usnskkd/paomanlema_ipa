import Foundation

/// A single timestamped throughput measurement in Mbps.
public struct SpeedSample: Identifiable, Equatable {
    public let id: Int
    public let elapsedSeconds: TimeInterval
    public let mbps: Double

    public init(id: Int, elapsedSeconds: TimeInterval, mbps: Double) {
        self.id = id
        self.elapsedSeconds = elapsedSeconds
        self.mbps = mbps
    }
}

/// Metrics state for one transfer direction (Download or Upload).
public struct DirectionMetrics: Equatable {
    public var isRunning: Bool = false
    public var hasCompletedRun: Bool = false
    public var currentMbps: Double = 0
    public var averageMbps: Double = 0
    public var finalMbps: Double = 0
    public var totalBytes: Int64 = 0
    public var samples: [SpeedSample] = []

    /// Suggested upper bound for the Y-axis scale.
    public var yAxisMaxMbps: Double {
        let peakSample = samples.map(\.mbps).max() ?? 0
        let peak = max(peakSample, averageMbps, currentMbps)
        if peak <= 0.01 {
            return 100.0
        }
        return peak * 1.15
    }

    public init() {}
}

/// User-configurable speed test settings persisted in UserDefaults.
public struct SpeedTestConfig: Codable, Equatable {
    public var downloadURL: String
    public var uploadURL: String
    public var downloadThreads: Int
    public var uploadThreads: Int
    public var uploadChunkMB: Int

    public static let defaultDownloadURL = "https://speed.cloudflare.com/__down?bytes=50000000"
    public static let defaultUploadURL = "https://speed.cloudflare.com/__up"

    public static let `default` = SpeedTestConfig(
        downloadURL: defaultDownloadURL,
        uploadURL: defaultUploadURL,
        downloadThreads: 6,
        uploadThreads: 4,
        uploadChunkMB: 8
    )

    private static let storageKey = "com.paomanlema.ios.config.v1"

    public static func load() -> SpeedTestConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(SpeedTestConfig.self, from: data) else {
            return .default
        }
        return decoded.sanitized()
    }

    public func save() {
        let clean = sanitized()
        if let data = try? JSONEncoder().encode(clean) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    public func sanitized() -> SpeedTestConfig {
        SpeedTestConfig(
            downloadURL: downloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultDownloadURL
                : downloadURL.trimmingCharacters(in: .whitespacesAndNewlines),
            uploadURL: uploadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultUploadURL
                : uploadURL.trimmingCharacters(in: .whitespacesAndNewlines),
            downloadThreads: min(max(downloadThreads, 1), 16),
            uploadThreads: min(max(uploadThreads, 1), 12),
            uploadChunkMB: min(max(uploadChunkMB, 2), 20)
        )
    }
}

/// Formatting helpers matching the PaoManLeMa UI conventions.
public enum SpeedFormatter {
    public static func formatBytes(_ bytes: Int64) -> String {
        let value = Double(max(bytes, 0))
        let kb = 1024.0
        let mb = kb * 1024.0
        let gb = mb * 1024.0

        if value >= gb {
            return String(format: "%.2f GB", value / gb)
        } else if value >= mb {
            return String(format: "%.1f MB", value / mb)
        } else if value >= kb {
            return String(format: "%.1f KB", value / kb)
        } else {
            return String(format: "%.1f MB", 0.0)
        }
    }

    public static func formatMbps(_ mbps: Double) -> String {
        String(format: "%.2f Mbps", max(mbps, 0))
    }

    public static func formatShortM(_ mbps: Double) -> String {
        String(format: "%.2fM", max(mbps, 0))
    }

    public static func formatAxisValue(_ mbps: Double) -> String {
        if mbps <= 0.001 {
            return "0K"
        }
        return String(format: "%.2f", mbps)
    }

    public static func formatLiveBadge(_ mbps: Double) -> String {
        if mbps >= 100 {
            return String(format: "%.1f", mbps)
        }
        return String(format: "%.2f", max(mbps, 0))
    }
}
