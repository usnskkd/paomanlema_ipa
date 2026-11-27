import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = SpeedTestViewModel()
    @State private var showSettings = false
    @State private var showResetConfirm = false

    private let primaryBlue = Color(red: 0.039, green: 0.337, blue: 0.816)
    private let activeRed = Color(red: 0.851, green: 0.188, blue: 0.145)

    var body: some View {
        ZStack {
            Color(red: 0.969, green: 0.973, blue: 0.984)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                topHeader

                SpeedChartCard(
                    title: "下载",
                    trafficTitle: "下载流量",
                    metrics: viewModel.download,
                    lineColor: Color(red: 0.02, green: 0.36, blue: 0.96),
                    fillColor: Color(red: 0.30, green: 0.56, blue: 0.98).opacity(0.26),
                    badgeColor: primaryBlue
                )

                SpeedChartCard(
                    title: "上传",
                    trafficTitle: "上传流量",
                    metrics: viewModel.upload,
                    lineColor: Color(red: 0.36, green: 0.32, blue: 0.48),
                    fillColor: Color(red: 0.56, green: 0.52, blue: 0.71).opacity(0.24),
                    badgeColor: Color(red: 0.41, green: 0.38, blue: 0.53)
                )

                if let notice = viewModel.importNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundColor(primaryBlue)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else if let error = viewModel.statusError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(activeRed)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                Spacer(minLength: 4)

                actionButtonsRow
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(viewModel: viewModel)
        }
        .confirmationDialog("是否清零总流量与测速曲线？", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("清零", role: .destructive) {
                viewModel.resetAllTraffic()
            }
            Button("取消", role: .cancel) {}
        }
        .onOpenURL { url in
            _ = viewModel.importConfFile(from: url)
        }
    }

    private var topHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("跑满了吗")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(Color(red: 0.10, green: 0.11, blue: 0.14))

                Button {
                    showSettings = true
                } label: {
                    Text("V4.3.2")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(red: 0.38, green: 0.40, blue: 0.44))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                showResetConfirm = true
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("总流量")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(Color(red: 0.19, green: 0.24, blue: 0.36))

                    Text(SpeedFormatter.formatBytes(viewModel.totalTrafficBytes))
                        .font(.system(size: 19, weight: .bold).monospacedDigit())
                        .foregroundColor(Color(red: 0.08, green: 0.11, blue: 0.20))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(minWidth: 122, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(red: 0.882, green: 0.914, blue: 0.996))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var actionButtonsRow: some View {
        HStack(spacing: 12) {
            actionCapsuleButton(
                title: viewModel.isUploadRunning ? "停止上传" : "上传",
                isActive: viewModel.isUploadRunning && !viewModel.isBidirectionalRunning
            ) {
                viewModel.toggleUpload()
            }

            actionCapsuleButton(
                title: viewModel.isDownloadRunning ? "停止下载" : "下载",
                isActive: viewModel.isDownloadRunning && !viewModel.isBidirectionalRunning
            ) {
                viewModel.toggleDownload()
            }

            actionCapsuleButton(
                title: viewModel.isBidirectionalRunning ? "停止双向" : "双向",
                isActive: viewModel.isBidirectionalRunning
            ) {
                viewModel.toggleBidirectional()
            }
        }
    }

    private func actionCapsuleButton(
        title: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    Capsule(style: .continuous)
                        .fill(isActive ? activeRed : primaryBlue)
                )
        }
        .buttonStyle(.plain)
    }
}
