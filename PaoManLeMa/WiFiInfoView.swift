import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Second screen displaying the connected Wi-Fi name and technical details
/// arranged identically to the user's reference layout, enhanced with
/// Apple Shortcuts (`x-callback-url`) sync for full iOS 17+ radio metrics.
struct WiFiInfoView: View {
    @ObservedObject var monitor: WiFiInfoMonitor
    @State private var copiedHint: String?
    @State private var showShortcutGuide = false

    private let primaryBlue = Color(red: 0.039, green: 0.337, blue: 0.816)
    private let dividerColor = Color(red: 0.941, green: 0.945, blue: 0.957)
    private let labelColor = Color(red: 0.10, green: 0.11, blue: 0.14)
    private let valueColor = Color(red: 0.557, green: 0.573, blue: 0.608)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                headerRow

                infoCard

                if let msg = monitor.shortcutStatusMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(primaryBlue)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 6)
                }

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
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .onAppear {
            monitor.start()
        }
        .sheet(isPresented: $showShortcutGuide) {
            ShortcutSetupSheet(monitor: monitor)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 8) {
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
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(Color(red: 0.38, green: 0.40, blue: 0.44))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }

            Spacer(minLength: 4)

            Button {
                showShortcutGuide = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(primaryBlue)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(Color(red: 0.882, green: 0.914, blue: 0.996))
                    )
            }
            .buttonStyle(.plain)

            Button {
                monitor.refresh()
                if monitor.snapshot.isWiFiConnected {
                    monitor.triggerShortcutSync()
                }
            } label: {
                Text("同步")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(primaryBlue)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var infoCard: some View {
        let s = monitor.snapshot

        return VStack(spacing: 0) {
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
            infoRow(
                label: "MAC 地址",
                value: s.macAddressText,
                copyValue: s.bssid ?? (s.macAddressText != "--" ? s.macAddressText : nil)
            )
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
            .padding(.vertical, 14)
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
        .padding(.vertical, 14)
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

/// Built-in guide sheet explaining how to create the companion Apple Shortcut
/// (takes ~30 seconds, one-time setup) and customize its name.
private struct ShortcutSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var monitor: WiFiInfoMonitor
    @State private var nameInput: String = ""
    @State private var copiedTemplate = false

    private let primaryBlue = Color(red: 0.039, green: 0.337, blue: 0.816)

    private let shortcutTextTemplate = """
    ssid=【在此插入：网络名称】
    std=【在此插入：Wi-Fi标准】
    rssi=【在此插入：RSSI】
    rx=【在此插入：RX速率】
    tx=【在此插入：TX速率】
    ch=【在此插入：信道】
    mac=【在此插入：硬件MAC地址】
    """

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("配套快捷指令")) {
                    if let icloudURL = URL(string: "https://www.icloud.com/shortcuts/bdb3f7b290b0414297bc042e921e9c7a") {
                        Link(destination: icloudURL) {
                            Label("一键安装配套快捷指令（iCloud）", systemImage: "square.and.arrow.down")
                                .foregroundColor(primaryBlue)
                        }
                    }

                    TextField("跑满了吗WiFi", text: $nameInput)
                        .disableAutocorrection(true)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif

                    Button("立即调用该快捷指令同步") {
                        saveName()
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            monitor.triggerShortcutSync()
                        }
                    }
                    .foregroundColor(primaryBlue)
                }

                Section(header: Text("30 秒配置步骤（只需一次）")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. 打开系统自带「快捷指令」App，点右上角「+」新建快捷指令，命名为「\(nameInput.isEmpty ? WiFiInfoMonitor.defaultShortcutName : nameInput)」。")
                        Text("2. 添加多个「获取网络详情」动作，分别勾选：网络名称、Wi-Fi 标准、RSSI、RX 速率、TX 速率、信道、硬件 MAC 地址。")
                        Text("3. 最后添加一个「文本」动作（必须是最后一步，不要弹提醒框），粘贴下方模板并把【】替换为上面对应变量即可。")
                        Text("4. 回到本 App 点右上角「同步」，即可自动读完并秒切回来显示全部真实参数。")
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
                }

                Section(header: Text("「文本」动作模板（同时兼容中文键名）")) {
                    Text(shortcutTextTemplate)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)

                    Button(copiedTemplate ? "已复制模板 ✓" : "复制模板") {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = shortcutTextTemplate
                        #endif
                        copiedTemplate = true
                    }
                    .foregroundColor(primaryBlue)
                }
            }
            .navigationTitle("快捷指令联动设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveName()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            nameInput = monitor.shortcutName
        }
    }

    private func saveName() {
        let trimmed = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        monitor.shortcutName = trimmed.isEmpty ? WiFiInfoMonitor.defaultShortcutName : trimmed
    }
}
