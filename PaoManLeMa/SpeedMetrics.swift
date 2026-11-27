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

/// Single HTTP endpoint definition compatible with PAOMAN_SPEED_TEST_CONFIG (.conf).
public struct SpeedEndpoint: Codable, Equatable, Hashable {
    public var url: String
    public var method: String
    public var headers: [String: String]

    public init(url: String, method: String = "", headers: [String: String] = [:]) {
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self.method = method.trimmingCharacters(in: .whitespacesAndNewlines)
        self.headers = headers
    }

    enum CodingKeys: String, CodingKey {
        case url
        case method
        case headers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = (try container.decode(String.self, forKey: .url))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.method = (try container.decodeIfPresent(String.self, forKey: .method) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
    }
}

/// A named speed test node profile containing multiple download & upload endpoints.
public struct SpeedProfile: Codable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var downloadEndpoints: [SpeedEndpoint]
    public var uploadEndpoints: [SpeedEndpoint]

    public init(
        id: Int,
        name: String,
        downloadEndpoints: [SpeedEndpoint],
        uploadEndpoints: [SpeedEndpoint]
    ) {
        self.id = id
        self.name = name
        self.downloadEndpoints = downloadEndpoints
        self.uploadEndpoints = uploadEndpoints
    }

    public var downloadUrlsText: String {
        downloadEndpoints.map(\.url).joined(separator: "\n")
    }

    public var uploadUrlsText: String {
        uploadEndpoints.map(\.url).joined(separator: "\n")
    }

    public static let cloudflareDefault = SpeedProfile(
        id: 9001,
        name: "Cloudflare 全球双向",
        downloadEndpoints: [
            SpeedEndpoint(url: "https://speed.cloudflare.com/__down?bytes=50000000")
        ],
        uploadEndpoints: [
            SpeedEndpoint(url: "https://speed.cloudflare.com/__up")
        ]
    )
}

/// Parser for Android PaoManLeMa `PAOMAN_SPEED_TEST_CONFIG` `.conf` files.
public enum PaoManConfParser {
    private struct RawConfFile: Decodable {
        let format: String?
        let version: Int?
        let selectedProfileId: Int?
        let profiles: [RawProfile]?
    }

    private struct RawProfile: Decodable {
        let id: Int?
        let name: String?
        let downloadUrls: [String]?
        let uploadUrls: [String]?
        let downloadEndpoints: [SpeedEndpoint]?
        let uploadEndpoints: [SpeedEndpoint]?
    }

    public struct ParseResult {
        public let profiles: [SpeedProfile]
        public let selectedProfileId: Int
    }

    public static func parse(data: Data) throws -> ParseResult {
        let decoder = JSONDecoder()
        let raw = try decoder.decode(RawConfFile.self, from: data)
        guard let rawProfiles = raw.profiles, !rawProfiles.isEmpty else {
            throw NSError(
                domain: "PaoManConfParser",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "配置文件中未找到有效的 profiles 节点列表"]
            )
        }

        var parsed: [SpeedProfile] = []
        for (idx, item) in rawProfiles.enumerated() {
            let dlEndpoints = mergeEndpoints(endpoints: item.downloadEndpoints, urls: item.downloadUrls)
            let ulEndpoints = mergeEndpoints(endpoints: item.uploadEndpoints, urls: item.uploadUrls)
            if dlEndpoints.isEmpty && ulEndpoints.isEmpty {
                continue
            }
            let pid = item.id ?? (idx + 1)
            let pname = (item.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "导入配置 \(pid)"
            parsed.append(SpeedProfile(
                id: pid,
                name: pname,
                downloadEndpoints: dlEndpoints,
                uploadEndpoints: ulEndpoints
            ))
        }

        guard !parsed.isEmpty else {
            throw NSError(
                domain: "PaoManConfParser",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "配置文件中没有可用的下载或上传 URL"]
            )
        }

        let selectedId = raw.selectedProfileId.flatMap { wanted in
            parsed.contains(where: { $0.id == wanted }) ? wanted : nil
        } ?? parsed[0].id

        return ParseResult(profiles: parsed, selectedProfileId: selectedId)
    }

    private static func mergeEndpoints(endpoints: [SpeedEndpoint]?, urls: [String]?) -> [SpeedEndpoint] {
        var result: [SpeedEndpoint] = []
        var seen = Set<String>()

        if let endpoints {
            for ep in endpoints where isValidHTTPURL(ep.url) {
                if seen.insert(ep.url).inserted {
                    result.append(ep)
                }
            }
        }
        if let urls {
            for rawUrl in urls {
                let cleaned = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                if isValidHTTPURL(cleaned), seen.insert(cleaned).inserted {
                    result.append(SpeedEndpoint(url: cleaned))
                }
            }
        }
        return result
    }

    public static func parseLines(_ text: String) -> [SpeedEndpoint] {
        var result: [SpeedEndpoint] = []
        var seen = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidHTTPURL(cleaned), seen.insert(cleaned).inserted {
                result.append(SpeedEndpoint(url: cleaned))
            }
        }
        return result
    }

    public static func isValidHTTPURL(_ string: String) -> Bool {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            return false
        }
        return true
    }

    /// Loads the bundled `default_speed_profiles.conf` shipped inside the app bundle.
    public static func loadBundledProfiles() -> [SpeedProfile] {
        guard let fileURL = Bundle.main.url(forResource: "default_speed_profiles", withExtension: "conf"),
              let data = try? Data(contentsOf: fileURL),
              let result = try? parse(data: data) else {
            return []
        }
        return result.profiles
    }
}

/// User-configurable speed test settings persisted in UserDefaults.
public struct SpeedTestConfig: Codable, Equatable {
    public var profiles: [SpeedProfile]
    public var selectedProfileId: Int
    public var downloadThreads: Int
    public var uploadThreads: Int
    public var uploadChunkMB: Int

    public var activeProfile: SpeedProfile {
        profiles.first(where: { $0.id == selectedProfileId })
            ?? profiles.first
            ?? .cloudflareDefault
    }

    public static func makeDefault() -> SpeedTestConfig {
        var list = PaoManConfParser.loadBundledProfiles()
        if !list.contains(where: { $0.id == SpeedProfile.cloudflareDefault.id }) {
            list.append(.cloudflareDefault)
        }
        let firstId = list.first?.id ?? SpeedProfile.cloudflareDefault.id
        return SpeedTestConfig(
            profiles: list,
            selectedProfileId: firstId,
            downloadThreads: 8,
            uploadThreads: 8,
            uploadChunkMB: 4
        )
    }

    private static let storageKey = "com.paomanlema.ios.config.v2"

    public static func load() -> SpeedTestConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(SpeedTestConfig.self, from: data),
              !decoded.profiles.isEmpty else {
            return makeDefault()
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
        let validProfiles = profiles.isEmpty ? [SpeedProfile.cloudflareDefault] : profiles
        let resolvedId = validProfiles.contains(where: { $0.id == selectedProfileId })
            ? selectedProfileId
            : validProfiles[0].id
        return SpeedTestConfig(
            profiles: validProfiles,
            selectedProfileId: resolvedId,
            downloadThreads: min(max(downloadThreads, 1), 24),
            uploadThreads: min(max(uploadThreads, 1), 24),
            uploadChunkMB: min(max(uploadChunkMB, 1), 16)
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
