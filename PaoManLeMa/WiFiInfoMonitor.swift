import Foundation
import Network
#if os(iOS)
import CoreLocation
import NetworkExtension
import SystemConfiguration.CaptiveNetwork
import UIKit
#endif

public enum NetworkTransportKind: Equatable {
    case wifi
    case cellular
    case wired
    case offline
}

/// Values returned by the user's Apple Shortcut (`获取网络详情`) via x-callback-url.
public struct WiFiShortcutData: Equatable {
    public var ssid: String?
    public var standard: String?
    public var rssiDbm: Int?
    public var noiseDbm: Int?
    public var rxMbps: String?
    public var txMbps: String?
    public var linkSpeedFallback: String?
    public var channel: Int?
    public var bandText: String?
    public var macAddress: String?
    public var syncedAt: Date

    public init(syncedAt: Date = Date()) {
        self.syncedAt = syncedAt
    }

    public var formattedStandard: String? {
        guard let raw = standard?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lower = raw.lowercased()
        if lower.contains("wi-fi") || lower.contains("wifi") {
            return raw
        }
        if lower.contains("be") || lower == "7" {
            return "Wi-Fi 7 (802.11be)"
        }
        if lower.contains("ax") || lower == "6" {
            return "Wi-Fi 6 (802.11ax)"
        }
        if lower.contains("ac") || lower == "5" {
            return "Wi-Fi 5 (802.11ac)"
        }
        if lower.contains("11n") || lower == "n" || lower == "4" {
            return "Wi-Fi 4 (802.11n)"
        }
        return raw
    }

    public var formattedSignalStrength: String? {
        guard let rssi = rssiDbm else { return nil }
        let level: String
        if rssi >= -60 {
            level = "强"
        } else if rssi >= -72 {
            level = "良"
        } else {
            level = "弱"
        }
        return "\(level) (\(rssi) dBm)"
    }

    public var formattedLinkSpeed: String? {
        let rx = Self.cleanNumber(rxMbps)
        let tx = Self.cleanNumber(txMbps)
        if let rx, let tx {
            if rx == tx {
                return "\(rx) Mbps"
            }
            return "收 \(rx) / 发 \(tx) Mbps"
        }
        if let tx {
            return "\(tx) Mbps"
        }
        if let rx {
            return "\(rx) Mbps"
        }
        if let fb = linkSpeedFallback?.trimmingCharacters(in: .whitespacesAndNewlines), !fb.isEmpty {
            return fb.lowercased().contains("mbps") ? fb : "\(fb) Mbps"
        }
        return nil
    }

    public var formattedBand: String? {
        if let band = bandText?.trimmingCharacters(in: .whitespacesAndNewlines), !band.isEmpty {
            if let ch = channel {
                return "\(band) (信道 \(ch))"
            }
            return band
        }
        guard let ch = channel, ch > 0 else { return nil }
        if ch <= 14 {
            return "2.4 GHz (信道 \(ch))"
        } else if ch <= 177 {
            return "5 GHz (信道 \(ch))"
        } else {
            return "6 GHz (信道 \(ch))"
        }
    }

    private static func cleanNumber(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let stripped = raw
            .replacingOccurrences(of: "Mbps", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Mb/s", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }
}

/// Parses shortcut callback URLs (`paomanlema://wifi?result=...` or direct query params)
/// supporting JSON, `key=value` lines, and Chinese `网络工具箱` text lines.
public enum WiFiShortcutParser {
    public static func parse(url: URL) -> WiFiShortcutData? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let items = components.queryItems ?? []
        var dict: [String: String] = [:]
        for item in items {
            if let val = item.value {
                dict[item.name.lowercased()] = val
            }
        }

        // 1. Standard x-callback-url `?result=...` payload
        if let resultText = dict["result"], !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let parsed = parseTextPayload(resultText) {
                return parsed
            }
        }

        // 2. Direct query parameters: paomanlema://wifi?ssid=...&std=...&rssi=...&rx=...&tx=...&ch=...&mac=...
        var data = WiFiShortcutData()
        var matchedAny = false

        if let v = nonEmpty(dict["ssid"] ?? dict["name"]) { data.ssid = v; matchedAny = true }
        if let v = nonEmpty(dict["std"] ?? dict["standard"] ?? dict["wifistandard"]) { data.standard = v; matchedAny = true }
        if let v = parseFirstInt(dict["rssi"] ?? dict["signal"]) { data.rssiDbm = v; matchedAny = true }
        if let v = parseFirstInt(dict["noise"]) { data.noiseDbm = v; matchedAny = true }
        if let v = nonEmpty(dict["rx"] ?? dict["rxrate"]) { data.rxMbps = v; matchedAny = true }
        if let v = nonEmpty(dict["tx"] ?? dict["txrate"]) { data.txMbps = v; matchedAny = true }
        if let v = nonEmpty(dict["speed"] ?? dict["linkspeed"]) { data.linkSpeedFallback = v; matchedAny = true }
        if let v = parseFirstInt(dict["ch"] ?? dict["channel"]) { data.channel = v; matchedAny = true }
        if let v = nonEmpty(dict["band"]) { data.bandText = v; matchedAny = true }
        if let v = nonEmpty(dict["mac"] ?? dict["bssid"]) { data.macAddress = v; matchedAny = true }

        return matchedAny ? data : nil
    }

    public static func parseTextPayload(_ text: String) -> WiFiShortcutData? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Try JSON dictionary first
        if trimmed.hasPrefix("{"), let jsonData = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            var data = WiFiShortcutData()
            var matched = false
            for (rawKey, rawVal) in obj {
                let valStr = "\(rawVal)".trimmingCharacters(in: .whitespacesAndNewlines)
                if applyField(key: rawKey, value: valStr, to: &data) {
                    matched = true
                }
            }
            if matched { return data }
        }

        // Fallback: line-by-line key:value / key：value / key=value parser
        var data = WiFiShortcutData()
        var matched = false
        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = rawLine
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "·•- "))
            guard !line.isEmpty else { continue }

            // Handle header line like "Flymodem0232 的详细信息："
            if line.contains("的详细信息") {
                let prefix = line.components(separatedBy: "的详细信息").first?
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "📶🛜🌐")))
                if let prefix, !prefix.isEmpty, data.ssid == nil {
                    // Strip leading emoji/non-alphanumeric icon if any
                    let cleaned = prefix.trimmingCharacters(in: .whitespaces)
                    if !cleaned.isEmpty {
                        data.ssid = cleaned
                        matched = true
                    }
                }
                continue
            }

            if let (k, v) = splitKeyValue(line) {
                if applyField(key: k, value: v, to: &data) {
                    matched = true
                }
            }
        }
        return matched ? data : nil
    }

    private static func splitKeyValue(_ line: String) -> (String, String)? {
        let separators: [Character] = ["=", "：", ":"]
        for sep in separators {
            if let idx = line.firstIndex(of: sep) {
                let key = String(line[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                let val = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty && !val.isEmpty {
                    return (key, val)
                }
            }
        }
        return nil
    }

    private static func applyField(key rawKey: String, value rawVal: String, to data: inout WiFiShortcutData) -> Bool {
        let key = rawKey.lowercased().replacingOccurrences(of: " ", with: "")
        let val = rawVal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !val.isEmpty else { return false }

        if key == "ssid" || key == "name" || key.contains("网络名称") || key.contains("wifi名") || key.contains("wi-fi名") {
            data.ssid = val
            return true
        }
        if key == "std" || key == "standard" || key.contains("标准") || key.contains("wifistandard") {
            data.standard = val
            return true
        }
        if key == "rssi" || key.contains("信号") {
            if let num = parseFirstInt(val) {
                data.rssiDbm = num
                return true
            }
        }
        if key == "noise" || key.contains("噪声") || key.contains("噪音") {
            if let num = parseFirstInt(val) {
                data.noiseDbm = num
                return true
            }
        }
        if key == "rx" || key.contains("rx") || key.contains("接收速率") {
            data.rxMbps = val
            return true
        }
        if key == "tx" || key.contains("tx") || key.contains("发送速率") || key.contains("传输速率") {
            data.txMbps = val
            return true
        }
        if key == "speed" || key.contains("连接速度") || key.contains("linkspeed") {
            data.linkSpeedFallback = val
            return true
        }
        if key == "ch" || key == "channel" || key.contains("频道") || key.contains("信道") {
            if let num = parseFirstInt(val) {
                data.channel = num
                return true
            }
        }
        if key == "band" || key.contains("频段") {
            data.bandText = val
            return true
        }
        if key == "mac" || key == "bssid" || key.contains("mac") || key.contains("硬件地址") {
            if val != "02:00:00:00:00:00" {
                data.macAddress = val
                return true
            }
        }
        return false
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            return nil
        }
        return v
    }

    private static func parseFirstInt(_ text: String?) -> Int? {
        guard let text else { return nil }
        var buffer = ""
        var foundDigit = false
        for ch in text {
            if ch == "-" && buffer.isEmpty {
                buffer.append(ch)
            } else if ch.isNumber {
                buffer.append(ch)
                foundDigit = true
            } else if foundDigit {
                break
            } else {
                buffer = ""
            }
        }
        return foundDigit ? Int(buffer) : nil
    }
}

/// Snapshot of the current Wi-Fi interface details displayed on the second screen.
public struct WiFiDetailsSnapshot: Equatable {
    public var transport: NetworkTransportKind = .offline
    public var ssid: String? = nil
    public var bssid: String? = nil
    public var standardText: String = "--"
    public var signalStrengthText: String = "--"
    public var securityText: String = "--"
    public var linkSpeedText: String = "--"
    public var frequencyBandText: String = "--"
    public var macAddressText: String = "--"
    public var ipv4Address: String? = nil
    public var ipv6Addresses: [String] = []
    public var shortcutSyncedTimeText: String? = nil

    public var isWiFiConnected: Bool {
        transport == .wifi
    }

    public var displaySSID: String {
        guard isWiFiConnected else { return "未连接 Wi-Fi" }
        if let ssid, !ssid.isEmpty {
            return ssid
        }
        return "已连接 Wi-Fi（未授权/证书受限）"
    }

    public var statusSubtitle: String {
        switch transport {
        case .wifi:
            if let synced = shortcutSyncedTimeText {
                return "已连接 Wi-Fi · 快捷指令同步于 \(synced)"
            }
            return "当前已连接 Wi-Fi"
        case .cellular:
            return "未连接 Wi-Fi（当前蜂窝移动网络）"
        case .wired:
            return "未连接 Wi-Fi（有线网络）"
        case .offline:
            return "未连接网络"
        }
    }

    public init() {}
}

/// Monitors Wi-Fi connectivity, en0 IPv4/IPv6 addresses, NEHotspotNetwork (SSID/BSSID/Security),
/// and integrates with Apple Shortcuts (`x-callback-url`) for full iOS 17+ radio metrics.
@MainActor
public final class WiFiInfoMonitor: NSObject, ObservableObject {
    @Published public var snapshot = WiFiDetailsSnapshot()
    @Published public var needsLocationPermission = false
    @Published public var shortcutStatusMessage: String?
    @Published public var shortcutName: String {
        didSet {
            UserDefaults.standard.set(shortcutName, forKey: Self.shortcutNameKey)
        }
    }

    public static let defaultShortcutName = "跑满了吗WiFi"
    private static let shortcutNameKey = "com.paomanlema.ios.wifiShortcutName.v1"

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.paomanlema.wifi.monitor")
    private var isStarted = false
    private var latestTransport: NetworkTransportKind = .offline
    private var cachedShortcutData: WiFiShortcutData?

    #if os(iOS)
    private let locationManager = CLLocationManager()
    #endif

    public override init() {
        let saved = UserDefaults.standard.string(forKey: Self.shortcutNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.shortcutName = (saved?.isEmpty == false) ? saved! : Self.defaultShortcutName
        super.init()
        #if os(iOS)
        locationManager.delegate = self
        #endif
    }

    public func start() {
        guard !isStarted else {
            refresh()
            return
        }
        isStarted = true

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let kind: NetworkTransportKind
            if path.status != .satisfied {
                kind = .offline
            } else if path.usesInterfaceType(.wifi) {
                kind = .wifi
            } else if path.usesInterfaceType(.cellular) {
                kind = .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                kind = .wired
            } else {
                kind = .offline
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.latestTransport = kind
                if kind != .wifi {
                    self.cachedShortcutData = nil
                }
                self.refresh()
            }
        }
        pathMonitor.start(queue: monitorQueue)
        refresh()
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        pathMonitor.cancel()
    }

    public func requestLocationAuthorization() {
        #if os(iOS)
        locationManager.requestWhenInUseAuthorization()
        #endif
    }

    /// Launches the Apple Shortcut via official `shortcuts://x-callback-url/run-shortcut`
    /// so Shortcuts reads Wi-Fi Standard / RSSI / RX / TX / Channel / MAC and returns automatically.
    public func triggerShortcutSync() {
        #if os(iOS)
        let name = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultShortcutName
            : shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "x-success", value: "paomanlema://wifi"),
            URLQueryItem(name: "x-cancel", value: "paomanlema://wifi-cancel"),
            URLQueryItem(name: "x-error", value: "paomanlema://wifi-error")
        ]

        guard let url = components.url else { return }
        UIApplication.shared.open(url) { [weak self] opened in
            Task { @MainActor [weak self] in
                if !opened {
                    self?.showNotice("无法打开「快捷指令」App，请确认已安装系统快捷指令")
                }
            }
        }
        #endif
    }

    /// Handles `paomanlema://wifi...` callback returned from Apple Shortcuts.
    @discardableResult
    public func handleCallbackURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "paomanlema" else { return false }
        let host = url.host?.lowercased() ?? ""

        if host == "wifi-cancel" {
            showNotice("已取消快捷指令同步")
            return true
        }
        if host == "wifi-error" {
            let errMsg = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "errorMessage" })?.value
            showNotice("快捷指令执行失败：\(errMsg ?? "请检查快捷指令名称「\(shortcutName)」是否存在")")
            return true
        }
        guard host == "wifi" else { return false }

        if let parsed = WiFiShortcutParser.parse(url: url) {
            cachedShortcutData = parsed
            latestTransport = .wifi
            refresh()
            showNotice("已从快捷指令同步完整 Wi-Fi 参数")
        } else {
            showNotice("已返回，但未解析到 Wi-Fi 参数（请检查快捷指令最后一步是否输出文本）")
        }
        return true
    }

    public func refresh() {
        let addresses = Self.readWiFiInterfaceAddresses()
        let inferredTransport: NetworkTransportKind
        if latestTransport == .wifi {
            inferredTransport = .wifi
        } else if latestTransport == .offline && (addresses.ipv4 != nil || !addresses.ipv6.isEmpty) {
            inferredTransport = .wifi
        } else {
            inferredTransport = latestTransport
        }

        updateLocationPermissionFlag(isWiFi: inferredTransport == .wifi)

        guard inferredTransport == .wifi else {
            var empty = WiFiDetailsSnapshot()
            empty.transport = inferredTransport
            snapshot = empty
            return
        }

        var next = WiFiDetailsSnapshot()
        next.transport = .wifi
        next.standardText = "点击右上角同步"
        next.signalStrengthText = "点击右上角同步"
        next.securityText = "待读取"
        next.linkSpeedText = "点击右上角同步"
        next.frequencyBandText = "点击右上角同步"
        next.macAddressText = "待读取"
        next.ipv4Address = addresses.ipv4
        next.ipv6Addresses = addresses.ipv6

        applyShortcutOverlay(to: &next)
        snapshot = next

        #if os(iOS)
        fetchHotspotNetworkInfo(baseSnapshot: next)
        #endif
    }

    private func applyShortcutOverlay(to target: inout WiFiDetailsSnapshot) {
        guard let sc = cachedShortcutData else { return }

        // Clear stale cache only when both SSIDs are known and clearly different
        if let liveSSID = target.ssid, !liveSSID.isEmpty,
           let syncedSSID = sc.ssid, !syncedSSID.isEmpty,
           liveSSID != syncedSSID {
            cachedShortcutData = nil
            return
        }

        if (target.ssid == nil || target.ssid?.isEmpty == true), let scSSID = sc.ssid {
            target.ssid = scSSID
        }
        if let std = sc.formattedStandard {
            target.standardText = std
        }
        if let sig = sc.formattedSignalStrength {
            target.signalStrengthText = sig
        }
        if let spd = sc.formattedLinkSpeed {
            target.linkSpeedText = spd
        }
        if let band = sc.formattedBand {
            target.frequencyBandText = band
        }
        if let mac = sc.macAddress, !mac.isEmpty {
            target.macAddressText = Self.normalizeMAC(mac)
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        target.shortcutSyncedTimeText = fmt.string(from: sc.syncedAt)
    }

    private func updateLocationPermissionFlag(isWiFi: Bool) {
        #if os(iOS)
        guard isWiFi else {
            needsLocationPermission = false
            return
        }
        let status = locationManager.authorizationStatus
        needsLocationPermission = (status == .notDetermined || status == .denied || status == .restricted)
        #else
        needsLocationPermission = false
        #endif
    }

    private func showNotice(_ message: String) {
        shortcutStatusMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.shortcutStatusMessage == message {
                self?.shortcutStatusMessage = nil
            }
        }
    }

    #if os(iOS)
    private func fetchHotspotNetworkInfo(baseSnapshot: WiFiDetailsSnapshot) {
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            let fallbackSSID = Self.readCaptiveSSID()
            let fallbackBSSID = Self.readCaptiveBSSID()

            Task { @MainActor [weak self] in
                guard let self, self.snapshot.isWiFiConnected else { return }
                var updated = baseSnapshot

                if let network {
                    let cleanSSID = network.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.ssid = cleanSSID.isEmpty ? fallbackSSID : cleanSSID

                    let cleanBSSID = Self.normalizeMAC(network.bssid)
                    if !cleanBSSID.isEmpty && cleanBSSID != "00:00:00:00:00:00" {
                        updated.bssid = cleanBSSID
                        updated.macAddressText = "\(cleanBSSID) (路由器)"
                    } else if let fb = fallbackBSSID {
                        updated.bssid = fb
                        updated.macAddressText = "\(fb) (路由器)"
                    }

                    if #available(iOS 15.0, *) {
                        updated.securityText = Self.describeSecurityType(network.securityType)
                    }

                    if network.signalStrength > 0.001 {
                        updated.signalStrengthText = Self.describeSignalStrength(network.signalStrength)
                    }
                } else {
                    if let fallbackSSID {
                        updated.ssid = fallbackSSID
                    }
                    if let fallbackBSSID {
                        updated.bssid = fallbackBSSID
                        updated.macAddressText = "\(fallbackBSSID) (路由器)"
                    }
                }

                // Apply synced Shortcuts metrics on top (giving hardware MAC, 802.11ax, RSSI, RX/TX, band)
                self.applyShortcutOverlay(to: &updated)
                self.snapshot = updated
            }
        }
    }

    private nonisolated static func readCaptiveSSID() -> String? {
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else { return nil }
        for iface in interfaces {
            guard let rawInfo = CNCopyCurrentNetworkInfo(iface as CFString) as? [String: Any],
                  let ssid = rawInfo[kCNNetworkInfoKeySSID as String] as? String,
                  !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            return ssid
        }
        return nil
    }

    private nonisolated static func readCaptiveBSSID() -> String? {
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else { return nil }
        for iface in interfaces {
            guard let rawInfo = CNCopyCurrentNetworkInfo(iface as CFString) as? [String: Any],
                  let bssid = rawInfo[kCNNetworkInfoKeyBSSID as String] as? String else {
                continue
            }
            let normalized = normalizeMAC(bssid)
            if !normalized.isEmpty && normalized != "00:00:00:00:00:00" {
                return normalized
            }
        }
        return nil
    }

    @available(iOS 15.0, *)
    private nonisolated static func describeSecurityType(_ type: NEHotspotNetworkSecurityType) -> String {
        switch type {
        case .open:
            return "开放网络（无加密）"
        case .WEP:
            return "WEP"
        case .personal:
            return "WPA/WPA2/WPA3 PSK"
        case .enterprise:
            return "WPA/WPA2/WPA3 Enterprise"
        case .unknown:
            return "未知"
        @unknown default:
            return "未知"
        }
    }

    private nonisolated static func describeSignalStrength(_ strength: Double) -> String {
        let pct = Int(round(min(max(strength, 0), 1) * 100))
        if strength >= 0.75 {
            return "强 (\(pct)%)"
        } else if strength >= 0.45 {
            return "良 (\(pct)%)"
        } else {
            return "弱 (\(pct)%)"
        }
    }
    #endif

    /// Pads single-digit hex octets in BSSID/MAC strings (e.g. `a:3:69:9a:f:e` -> `0a:03:69:9a:0f:0e`).
    public nonisolated static func normalizeMAC(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":")
        guard parts.count == 6 else { return trimmed }
        return parts.map { part in
            let s = String(part).lowercased()
            return s.count == 1 ? "0\(s)" : s
        }.joined(separator: ":")
    }

    /// Reads real IPv4 and all IPv6 addresses bound to the Wi-Fi interface (`en0`) via `getifaddrs`.
    private static func readWiFiInterfaceAddresses() -> (ipv4: String?, ipv6: [String]) {
        var ipv4: String?
        var ipv6List: [String] = []
        var seenIPv6 = Set<String>()

        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else {
            return (nil, [])
        }
        defer { freeifaddrs(ifaddrPointer) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            guard let namePtr = current.pointee.ifa_name else { continue }
            let name = String(cString: namePtr)
            guard name == "en0" else { continue }

            guard let addr = current.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family

            if family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let ip = String(cString: host)
                    if !ip.isEmpty {
                        ipv4 = ip
                    }
                }
            } else if family == UInt8(AF_INET6) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    var ip = String(cString: host)
                    if let percentIdx = ip.firstIndex(of: "%") {
                        ip = String(ip[..<percentIdx])
                    }
                    if !ip.isEmpty, seenIPv6.insert(ip).inserted {
                        ipv6List.append(ip)
                    }
                }
            }
        }

        ipv6List.sort { a, b in
            ipv6SortRank(a) < ipv6SortRank(b)
        }

        return (ipv4, ipv6List)
    }

    private static func ipv6SortRank(_ ip: String) -> Int {
        let lower = ip.lowercased()
        if lower.hasPrefix("fe80:") { return 0 }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return 2 }
        return 1
    }
}

#if os(iOS)
extension WiFiInfoMonitor: CLLocationManagerDelegate {
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.refresh()
        }
    }
}
#endif
