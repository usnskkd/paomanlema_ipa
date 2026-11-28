import Foundation
import Network
#if os(iOS)
import CoreLocation
import NetworkExtension
import SystemConfiguration.CaptiveNetwork
#endif

public enum NetworkTransportKind: Equatable {
    case wifi
    case cellular
    case wired
    case offline
}

/// Snapshot of the current Wi-Fi interface details displayed on the second screen.
public struct WiFiDetailsSnapshot: Equatable {
    public var transport: NetworkTransportKind = .offline
    public var ssid: String? = nil
    public var standardText: String = "--"
    public var signalStrengthText: String = "--"
    public var securityText: String = "--"
    public var linkSpeedText: String = "--"
    public var frequencyBandText: String = "--"
    public var macAddressText: String = "--"
    public var ipv4Address: String? = nil
    public var ipv6Addresses: [String] = []

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

/// Monitors Wi-Fi connectivity, en0 IPv4/IPv6 addresses, and (when authorized) SSID & security type.
@MainActor
public final class WiFiInfoMonitor: NSObject, ObservableObject {
    @Published public var snapshot = WiFiDetailsSnapshot()
    @Published public var needsLocationPermission = false

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.paomanlema.wifi.monitor")
    private var isStarted = false
    private var latestTransport: NetworkTransportKind = .offline

    #if os(iOS)
    private let locationManager = CLLocationManager()
    #endif

    public override init() {
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

    public func refresh() {
        let addresses = Self.readWiFiInterfaceAddresses()
        let inferredTransport: NetworkTransportKind
        if latestTransport == .wifi {
            inferredTransport = .wifi
        } else if latestTransport == .offline && (addresses.ipv4 != nil || !addresses.ipv6.isEmpty) {
            // NWPathMonitor may not have delivered its first callback yet
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
        next.standardText = "iOS 系统限制"
        next.signalStrengthText = "iOS 系统限制"
        next.securityText = "iOS 系统限制"
        next.linkSpeedText = "iOS 系统限制"
        next.frequencyBandText = "iOS 系统限制"
        next.macAddressText = "iOS 系统隐私隐藏"
        next.ipv4Address = addresses.ipv4
        next.ipv6Addresses = addresses.ipv6
        snapshot = next

        #if os(iOS)
        fetchHotspotNetworkInfo(baseSnapshot: next)
        #endif
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

    #if os(iOS)
    private func fetchHotspotNetworkInfo(baseSnapshot: WiFiDetailsSnapshot) {
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            let fallbackSSID = Self.readCaptiveSSID()
            Task { @MainActor [weak self] in
                guard let self, self.snapshot.isWiFiConnected else { return }
                var updated = baseSnapshot

                if let network {
                    let cleanSSID = network.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.ssid = cleanSSID.isEmpty ? fallbackSSID : cleanSSID

                    if #available(iOS 15.0, *) {
                        updated.securityText = Self.describeSecurityType(network.securityType)
                    }

                    if network.signalStrength > 0.001 {
                        updated.signalStrengthText = Self.describeSignalStrength(network.signalStrength)
                    }
                } else if let fallbackSSID {
                    updated.ssid = fallbackSSID
                }

                self.snapshot = updated
            }
        }
    }

    private static func readCaptiveSSID() -> String? {
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

    @available(iOS 15.0, *)
    private static func describeSecurityType(_ type: NEHotspotNetworkSecurityType) -> String {
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
            return "iOS 系统限制"
        @unknown default:
            return "iOS 系统限制"
        }
    }

    private static func describeSignalStrength(_ strength: Double) -> String {
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

        // Order IPv6 addresses consistently: link-local (fe80::), global unicast (2xxx/3xxx), ULA (fc/fd)
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
