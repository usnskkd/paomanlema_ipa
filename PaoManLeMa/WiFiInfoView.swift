import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Second screen displaying the connected Wi-Fi name and technical details
/// arranged identically to the user's reference layout.
struct WiFiInfoView: View {
    @ObservedObject var monitor: WiFiInfoMonitor
    @State private var copiedHint: String?

    private let primaryBlue = Color(red: 0.039, green: 0.337, blue: 0.816)
    private let dividerColor = Color(red: 0.941, green: 0.945, blue: 0.957)
    private let labelColor = Color(red: 0.10, green: 0.11, blue: 0.14)
    private let valueColor = Color(red: 0.557, green: 0.573, blue: 0.608)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                headerRow

                infoCard

                if monitor.snapshot.isWiFiConnected && monitor.needsLocationPermission {
                    Button {
                        monitor.requestLocationAuthorization()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 13))
                            Text("授权定位权限以读取已连接 Wi-Fi 名称")
                                .font(.system(size: 13.5, weight: .medium))
                        }
                        .foregroundColor(primaryBlue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(red: 0.882, green: 0.914, blue: 0.996))
                        )
                    }
                    .buttonStyle(.plain)
                }

                if let copiedHint {
                    Text(copiedHint)
                        .font(.caption)
                        .foregroundColor(primaryBlue)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .onAppear {
            monitor.start()
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Wi-Fi 信息")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(labelColor)

                HStack(spacing: 6) {
                    Circle()
                        .fill(monitor.snapshot.isWiFiConnected
                              ? Color(red: 0.118, green: 0.557, blue: 0.243)
                              : Color(red: 0.851, green: 0.467, blue: 0.024))
                        .frame(width: 8, height: 8)

                    Text(monitor.snapshot.statusSubtitle)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(Color(red: 0.38, green: 0.40, blue: 0.44))
                }
            }

            Spacer()

            Button {
                monitor.refresh()
            } label: {
                Text("刷新")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(primaryBlue)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(red: 0.882, green: 0.914, blue: 0.996))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var infoCard: some View {
        let s = monitor.snapshot

        return VStack(spacing: 0) {
            // Top row: Connected Wi-Fi Name
            infoRow(
                label: "已连接 Wi-Fi",
                value: s.displaySSID,
                valueTint: s.isWiFiConnected ? primaryBlue : valueColor,
                isBoldValue: s.isWiFiConnected,
                copyValue: s.ssid
            )

            infoRow(label: "技术标准", value: s.standardText)
            infoRow(label: "信号强度", value: s.signalStrengthText)
            infoRow(label: "安全性", value: s.securityText)
            infoRow(label: "连接速度", value: s.linkSpeedText)
            infoRow(label: "频段", value: s.frequencyBandText)
            infoRow(label: "MAC 地址", value: s.macAddressText)
            infoRow(
                label: "IPv4 地址",
                value: s.ipv4Address ?? "--",
                copyValue: s.ipv4Address
            )
            ipv6Row(addresses: s.ipv6Addresses)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
        )
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(dividerColor)
            .frame(height: 1)
    }

    private func infoRow(
        label: String,
        value: String,
        valueTint: Color? = nil,
        isBoldValue: Bool = false,
        copyValue: String? = nil,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(label)
                    .font(.system(size: 16, weight: isBoldValue ? .medium : .regular))
                    .foregroundColor(labelColor)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 8)

                Text(value)
                    .font(.system(size: 15, weight: isBoldValue ? .semibold : .regular).monospacedDigit())
                    .foregroundColor(valueTint ?? valueColor)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 15)
            .contentShape(Rectangle())
            .onTapGesture {
                if let copyValue, !copyValue.isEmpty {
                    copyToClipboard(copyValue, label: label)
                }
            }

            if showDivider {
                rowDivider
            }
        }
    }

    private func ipv6Row(addresses: [String]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text("IPv6 地址")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(labelColor)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.top, 2)

            Spacer(minLength: 8)

            if addresses.isEmpty {
                Text("--")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(valueColor)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(addresses, id: \.self) { addr in
                        Text(addr)
                            .font(.system(size: 13.5, weight: .regular).monospacedDigit())
                            .foregroundColor(valueColor)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .padding(.vertical, 15)
        .contentShape(Rectangle())
        .onTapGesture {
            if !addresses.isEmpty {
                copyToClipboard(addresses.joined(separator: "\n"), label: "IPv6 地址")
            }
        }
    }

    private func copyToClipboard(_ text: String, label: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        let message = "已复制 \(label)"
        copiedHint = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if copiedHint == message {
                copiedHint = nil
            }
        }
    }
}
