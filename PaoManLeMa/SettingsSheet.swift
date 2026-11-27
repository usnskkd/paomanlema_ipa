import SwiftUI

/// Optional lightweight configuration sheet (opened by tapping the version label "V4.3.2")
/// so the main screen remains 100% pure and uncluttered.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: SpeedTestViewModel

    @State private var downloadURL: String = ""
    @State private var uploadURL: String = ""
    @State private var downloadThreads: Int = 6
    @State private var uploadThreads: Int = 4
    @State private var uploadChunkMB: Int = 8

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("测速节点 URL")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("下载测速地址 (GET)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        #if os(iOS)
                        TextField("https://speed.cloudflare.com/__down?bytes=50000000", text: $downloadURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .font(.footnote)
                        #else
                        TextField("https://speed.cloudflare.com/__down?bytes=50000000", text: $downloadURL)
                            .disableAutocorrection(true)
                            .font(.footnote)
                        #endif
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("上传测速地址 (POST)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        #if os(iOS)
                        TextField("https://speed.cloudflare.com/__up", text: $uploadURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .font(.footnote)
                        #else
                        TextField("https://speed.cloudflare.com/__up", text: $uploadURL)
                            .disableAutocorrection(true)
                            .font(.footnote)
                        #endif
                    }

                    Button("恢复默认 Cloudflare 双向节点") {
                        downloadURL = SpeedTestConfig.defaultDownloadURL
                        uploadURL = SpeedTestConfig.defaultUploadURL
                    }
                    .foregroundColor(Color(red: 0.04, green: 0.34, blue: 0.82))
                }

                Section(header: Text("并发参数")) {
                    Stepper("下载线程数：\(downloadThreads)", value: $downloadThreads, in: 1...16)
                    Stepper("上传线程数：\(uploadThreads)", value: $uploadThreads, in: 1...12)
                    Stepper("单次上传块大小：\(uploadChunkMB) MB", value: $uploadChunkMB, in: 2...20, step: 2)
                }

                Section {
                    Button(role: .destructive) {
                        viewModel.resetAllTraffic()
                        dismiss()
                    } label: {
                        Text("清零总流量与图表记录")
                    }
                }
            }
            .navigationTitle("测速参数")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let updated = SpeedTestConfig(
                            downloadURL: downloadURL,
                            uploadURL: uploadURL,
                            downloadThreads: downloadThreads,
                            uploadThreads: uploadThreads,
                            uploadChunkMB: uploadChunkMB
                        )
                        viewModel.updateConfig(updated)
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            downloadURL = viewModel.config.downloadURL
            uploadURL = viewModel.config.uploadURL
            downloadThreads = viewModel.config.downloadThreads
            uploadThreads = viewModel.config.uploadThreads
            uploadChunkMB = viewModel.config.uploadChunkMB
        }
    }
}
