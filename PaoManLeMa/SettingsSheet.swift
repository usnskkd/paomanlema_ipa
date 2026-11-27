import SwiftUI
import UniformTypeIdentifiers

/// Configuration sheet opened by tapping "V4.3.2" so the main speed test screen
/// stays 100% faithful and uncluttered.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: SpeedTestViewModel

    @State private var selectedProfileId: Int = 1
    @State private var downloadUrlsText: String = ""
    @State private var uploadUrlsText: String = ""
    @State private var downloadThreads: Int = 8
    @State private var uploadThreads: Int = 8
    @State private var uploadChunkMB: Int = 4

    @State private var showFileImporter = false
    @State private var alertMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("节点配置方案（兼容 Android .conf）")) {
                    ForEach(viewModel.config.profiles) { profile in
                        Button {
                            selectProfile(profile)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text("下载 \(profile.downloadEndpoints.count) 节点 · 上传 \(profile.uploadEndpoints.count) 节点")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if profile.id == selectedProfileId {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Color(red: 0.04, green: 0.34, blue: 0.82))
                                }
                            }
                        }
                    }

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("导入 .conf 配置文件", systemImage: "doc.badge.plus")
                            .foregroundColor(Color(red: 0.04, green: 0.34, blue: 0.82))
                    }

                    Button {
                        viewModel.restoreBuiltInDefaults()
                        syncFromViewModel()
                        alertMessage = "已恢复内置国内多节点配置（64 下载 + 119 上传）与 Cloudflare 方案"
                    } label: {
                        Label("恢复内置默认方案", systemImage: "arrow.counterclockwise")
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("并发参数")) {
                    Stepper("下载并发线程：\(downloadThreads)", value: $downloadThreads, in: 1...24)
                    Stepper("上传并发线程：\(uploadThreads)", value: $uploadThreads, in: 1...24)
                    Stepper("单次上传块：\(uploadChunkMB) MB", value: $uploadChunkMB, in: 1...16)
                }

                Section(header: Text("当前方案下载 URL（每行一个，共 \(PaoManConfParser.parseLines(downloadUrlsText).count) 个）")) {
                    TextEditor(text: $downloadUrlsText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 110)
                        .disableAutocorrection(true)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }

                Section(header: Text("当前方案上传 URL（每行一个，共 \(PaoManConfParser.parseLines(uploadUrlsText).count) 个）")) {
                    TextEditor(text: $uploadUrlsText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 110)
                        .disableAutocorrection(true)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
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
            .navigationTitle("节点与测速参数")
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
                        saveChanges()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            syncFromViewModel()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                switch viewModel.importConfFile(from: url) {
                case .success(let summary):
                    syncFromViewModel()
                    alertMessage = summary
                case .failure(let error):
                    alertMessage = "导入失败：\(error.localizedDescription)"
                }
            case .failure(let error):
                alertMessage = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .alert("提示", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func syncFromViewModel() {
        let cfg = viewModel.config
        selectedProfileId = cfg.activeProfile.id
        downloadUrlsText = cfg.activeProfile.downloadUrlsText
        uploadUrlsText = cfg.activeProfile.uploadUrlsText
        downloadThreads = cfg.downloadThreads
        uploadThreads = cfg.uploadThreads
        uploadChunkMB = cfg.uploadChunkMB
    }

    private func selectProfile(_ profile: SpeedProfile) {
        selectedProfileId = profile.id
        downloadUrlsText = profile.downloadUrlsText
        uploadUrlsText = profile.uploadUrlsText
    }

    private func saveChanges() {
        var updated = viewModel.config
        updated.selectedProfileId = selectedProfileId
        updated.downloadThreads = downloadThreads
        updated.uploadThreads = uploadThreads
        updated.uploadChunkMB = uploadChunkMB

        let parsedDL = PaoManConfParser.parseLines(downloadUrlsText)
        let parsedUL = PaoManConfParser.parseLines(uploadUrlsText)

        if let idx = updated.profiles.firstIndex(where: { $0.id == selectedProfileId }) {
            if !parsedDL.isEmpty {
                updated.profiles[idx].downloadEndpoints = parsedDL
            }
            if !parsedUL.isEmpty {
                updated.profiles[idx].uploadEndpoints = parsedUL
            }
        }

        viewModel.updateConfig(updated)
    }
}
