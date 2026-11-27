import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Thread-safe byte counter backed by NSLock (iOS 15+ compatible).
private final class AtomicByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    func add(_ delta: Int64) {
        guard delta > 0 else { return }
        lock.lock()
        value += delta
        lock.unlock()
    }

    func get() -> Int64 {
        lock.lock()
        let v = value
        lock.unlock()
        return v
    }

    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }
}

/// Manages a pool of independent URLSession workers cycling across multiple SpeedEndpoints
/// with automatic failure cooldown and separate TCP/QUIC connections per worker.
private final class TransferWorkerPool: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    enum Mode {
        case download
        case upload
    }

    private struct TaskRecord {
        let endpointURL: String
        var transferredBytes: Int64 = 0
        var isAcceptableDownloadStatus: Bool = true
    }

    private let mode: Mode
    private let lock = NSLock()
    private var isRunning = false
    private var sessions: [URLSession] = []
    private var endpoints: [SpeedEndpoint] = []
    private var nextIndex: Int = 0
    private var cooldownUntil: [String: TimeInterval] = [:]
    private var taskRecords: [Int: TaskRecord] = [:]
    private var uploadPayload: Data = Data()
    private var consecutiveZeroByteFailures = 0

    let byteCounter = AtomicByteCounter()
    var onError: ((String?) -> Void)?

    private static let browserUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.paomanlema.transfer.delegate"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 24
        return q
    }()

    init(mode: Mode) {
        self.mode = mode
        super.init()
    }

    func start(endpoints rawEndpoints: [SpeedEndpoint], threadCount: Int, uploadChunkMB: Int = 4) {
        stop()

        let validEndpoints = rawEndpoints.filter { PaoManConfParser.isValidHTTPURL($0.url) }
        guard !validEndpoints.isEmpty else {
            onError?(mode == .download ? "未配置有效的下载测速节点" : "未配置有效的上传测速节点")
            return
        }

        let payload: Data
        if mode == .upload {
            payload = Self.makeIncompressiblePayload(megabytes: uploadChunkMB)
        } else {
            payload = Data()
        }

        lock.lock()
        self.isRunning = true
        self.endpoints = validEndpoints.shuffled()
        self.nextIndex = 0
        self.cooldownUntil.removeAll()
        self.taskRecords.removeAll()
        self.uploadPayload = payload
        self.consecutiveZeroByteFailures = 0
        self.sessions = []

        let workerCount = max(1, threadCount)
        var createdSessions: [URLSession] = []
        createdSessions.reserveCapacity(workerCount)

        for _ in 0..<workerCount {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 120
            config.httpMaximumConnectionsPerHost = 4
            config.allowsCellularAccess = true
            config.allowsExpensiveNetworkAccess = true
            config.allowsConstrainedNetworkAccess = true
            config.waitsForConnectivity = false

            let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
            createdSessions.append(session)
        }

        self.sessions = createdSessions
        lock.unlock()

        onError?(nil)

        for session in createdSessions {
            launchNextTask(on: session)
        }
    }

    func stop() {
        lock.lock()
        isRunning = false
        let activeSessions = sessions
        sessions = []
        taskRecords.removeAll()
        uploadPayload = Data()
        lock.unlock()

        for session in activeSessions {
            session.invalidateAndCancel()
        }
    }

    /// Selects the next healthy endpoint via round-robin, skipping endpoints currently on cooldown.
    private func pickNextEndpointLocked() -> SpeedEndpoint? {
        guard !endpoints.isEmpty else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let count = endpoints.count

        for _ in 0..<count {
            let candidate = endpoints[nextIndex % count]
            nextIndex = (nextIndex + 1) % count
            if let until = cooldownUntil[candidate.url], until > now {
                continue
            }
            return candidate
        }

        // All endpoints are cooling down: clear cooldowns and pick the next one
        cooldownUntil.removeAll()
        let fallback = endpoints[nextIndex % count]
        nextIndex = (nextIndex + 1) % count
        return fallback
    }

    private func launchNextTask(on session: URLSession) {
        lock.lock()
        guard isRunning, let endpoint = pickNextEndpointLocked() else {
            lock.unlock()
            return
        }
        let payload = uploadPayload
        lock.unlock()

        guard let requestURL = URL(string: endpoint.url) else { return }

        var request = URLRequest(url: requestURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")

        for (k, v) in endpoint.headers where !k.isEmpty {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let task: URLSessionTask
        switch mode {
        case .download:
            request.httpMethod = endpoint.method.isEmpty ? "GET" : endpoint.method
            task = session.dataTask(with: request)
        case .upload:
            request.httpMethod = endpoint.method.isEmpty ? "POST" : endpoint.method
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            }
            task = session.uploadTask(with: request, from: payload)
        }

        lock.lock()
        taskRecords[task.taskIdentifier] = TaskRecord(endpointURL: endpoint.url)
        lock.unlock()

        task.resume()
    }

    /// Generates a shared pseudo-random payload so TLS/proxies cannot compress it away.
    private static func makeIncompressiblePayload(megabytes: Int) -> Data {
        let byteCount = max(1, megabytes) * 1024 * 1024
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { rawBuffer in
            let words = rawBuffer.bindMemory(to: UInt64.self)
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15 ^ UInt64(Date().timeIntervalSince1970.bitPattern)
            for i in 0..<words.count {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                words[i] = state
            }
        }
        return data
    }

    // MARK: - URLSessionDataDelegate (Download response + bytes)

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if mode == .download, let http = response as? HTTPURLResponse {
            let ok = (200...299).contains(http.statusCode)
            lock.lock()
            if var rec = taskRecords[dataTask.taskIdentifier] {
                rec.isAcceptableDownloadStatus = ok
                taskRecords[dataTask.taskIdentifier] = rec
                if !ok {
                    cooldownUntil[rec.endpointURL] = ProcessInfo.processInfo.systemUptime + 20.0
                }
            }
            lock.unlock()

            if !ok {
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard mode == .download else { return }
        let count = Int64(data.count)
        guard count > 0 else { return }

        lock.lock()
        let allowed = taskRecords[dataTask.taskIdentifier]?.isAcceptableDownloadStatus ?? true
        if allowed {
            taskRecords[dataTask.taskIdentifier]?.transferredBytes += count
            consecutiveZeroByteFailures = 0
        }
        lock.unlock()

        if allowed {
            byteCounter.add(count)
        }
    }

    // MARK: - URLSessionTaskDelegate (Upload bytes + loop restart)

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard mode == .upload, bytesSent > 0 else { return }
        byteCounter.add(bytesSent)

        lock.lock()
        taskRecords[task.taskIdentifier]?.transferredBytes += bytesSent
        consecutiveZeroByteFailures = 0
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let active = isRunning
        let record = taskRecords.removeValue(forKey: task.taskIdentifier)
        let bytesMoved = record?.transferredBytes ?? 0

        if !active {
            lock.unlock()
            return
        }

        let nsError = error as NSError?
        let isUserCancel = (nsError?.code == NSURLErrorCancelled)

        // If the task transferred actual bytes (very common for upload endpoints returning 403/405/413
        // after accepting the request body), consider it healthy and immediately cycle to the next node!
        if bytesMoved > 0 {
            consecutiveZeroByteFailures = 0
            lock.unlock()
            onError?(nil)
            launchNextTask(on: session)
            return
        }

        // Zero bytes transferred: cool down this specific endpoint so workers move to healthy nodes.
        if let epURL = record?.endpointURL {
            cooldownUntil[epURL] = ProcessInfo.processInfo.systemUptime + 18.0
        }

        let failureCount: Int
        if !isUserCancel {
            consecutiveZeroByteFailures += 1
            failureCount = consecutiveZeroByteFailures
        } else {
            failureCount = consecutiveZeroByteFailures
        }
        let endpointCount = max(endpoints.count, 1)
        lock.unlock()

        if let nsError, !isUserCancel, failureCount >= max(8, endpointCount) {
            onError?(nsError.localizedDescription)
        }

        let backoff: TimeInterval = failureCount >= endpointCount ? 0.35 : 0.05
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + backoff) { [weak self, weak session] in
            guard let self, let session else { return }
            self.launchNextTask(on: session)
        }
    }
}

/// Sliding-window throughput tracker sampled every 0.5 seconds.
private final class DirectionTracker {
    private let sampleInterval: TimeInterval = 0.5
    private let windowSamplesCount = 90 // 45 seconds window matching -30s / -15s / 现在

    private var runStartTime: TimeInterval?
    private var runStartBytes: Int64 = 0
    private var recentSnapshots: [(time: TimeInterval, bytes: Int64)] = []
    private var sampleSeq: Int = 0

    func startRun(currentTotalBytes: Int64, now: TimeInterval) {
        runStartTime = now
        runStartBytes = currentTotalBytes
        recentSnapshots = [(now, currentTotalBytes)]
    }

    func stopRun() {
        runStartTime = nil
        recentSnapshots.removeAll()
    }

    func reset() {
        runStartTime = nil
        runStartBytes = 0
        recentSnapshots.removeAll()
        sampleSeq = 0
    }

    func tick(
        totalBytes: Int64,
        now: TimeInterval,
        metrics: inout DirectionMetrics
    ) {
        metrics.totalBytes = totalBytes

        guard metrics.isRunning, let startTime = runStartTime else {
            return
        }

        recentSnapshots.append((now, totalBytes))
        while recentSnapshots.count > 2, let first = recentSnapshots.first, now - first.time > 1.5 {
            recentSnapshots.removeFirst()
        }

        let instantMbps: Double
        if let oldest = recentSnapshots.first, now - oldest.time >= 0.2 {
            let deltaBytes = max(0, totalBytes - oldest.bytes)
            let dt = now - oldest.time
            instantMbps = (Double(deltaBytes) * 8.0) / (dt * 1_000_000.0)
        } else {
            instantMbps = 0
        }

        let elapsed = max(now - startTime, sampleInterval)
        let runBytes = max(0, totalBytes - runStartBytes)
        let avgMbps = (Double(runBytes) * 8.0) / (elapsed * 1_000_000.0)

        metrics.currentMbps = instantMbps
        metrics.averageMbps = avgMbps
        metrics.finalMbps = avgMbps

        sampleSeq += 1
        let sample = SpeedSample(id: sampleSeq, elapsedSeconds: elapsed, mbps: instantMbps)
        metrics.samples.append(sample)
        if metrics.samples.count > windowSamplesCount {
            metrics.samples.removeFirst(metrics.samples.count - windowSamplesCount)
        }
    }
}

/// Main observable ViewModel driving the PaoManLeMa iOS UI.
@MainActor
public final class SpeedTestViewModel: ObservableObject {
    @Published public var download = DirectionMetrics()
    @Published public var upload = DirectionMetrics()
    @Published public var config: SpeedTestConfig = SpeedTestConfig.load()
    @Published public var statusError: String?
    @Published public var importNotice: String?

    public var totalTrafficBytes: Int64 {
        download.totalBytes + upload.totalBytes
    }

    public var isDownloadRunning: Bool { download.isRunning }
    public var isUploadRunning: Bool { upload.isRunning }
    public var isBidirectionalRunning: Bool { download.isRunning && upload.isRunning }
    public var isAnyRunning: Bool { download.isRunning || upload.isRunning }

    private let downloadPool = TransferWorkerPool(mode: .download)
    private let uploadPool = TransferWorkerPool(mode: .upload)
    private let downloadTracker = DirectionTracker()
    private let uploadTracker = DirectionTracker()

    private var timer: Timer?

    public init() {
        downloadPool.onError = { [weak self] msg in
            Task { @MainActor [weak self] in
                guard let self, self.download.isRunning else { return }
                self.statusError = msg.map { "下载异常：\($0)" }
            }
        }
        uploadPool.onError = { [weak self] msg in
            Task { @MainActor [weak self] in
                guard let self, self.upload.isRunning else { return }
                self.statusError = msg.map { "上传异常：\($0)" }
            }
        }
    }

    // MARK: - User Actions

    public func toggleDownload() {
        if download.isRunning {
            stopDownload()
        } else {
            startDownload()
        }
    }

    public func toggleUpload() {
        if upload.isRunning {
            stopUpload()
        } else {
            startUpload()
        }
    }

    public func toggleBidirectional() {
        if isBidirectionalRunning {
            stopAll()
        } else {
            startBidirectional()
        }
    }

    public func startDownload() {
        statusError = nil
        let now = ProcessInfo.processInfo.systemUptime
        download.isRunning = true
        download.hasCompletedRun = false
        download.currentMbps = 0
        download.averageMbps = 0
        download.samples.removeAll()

        downloadTracker.startRun(currentTotalBytes: downloadPool.byteCounter.get(), now: now)
        downloadPool.start(
            endpoints: config.activeProfile.downloadEndpoints,
            threadCount: config.downloadThreads
        )
        ensureTimerRunning()
        updateIdleTimer()
    }

    public func stopDownload() {
        guard download.isRunning else { return }
        downloadPool.stop()
        let now = ProcessInfo.processInfo.systemUptime
        downloadTracker.tick(totalBytes: downloadPool.byteCounter.get(), now: now, metrics: &download)
        download.isRunning = false
        download.hasCompletedRun = true
        download.finalMbps = download.averageMbps
        download.currentMbps = 0
        downloadTracker.stopRun()
        cleanupTimerIfIdle()
        updateIdleTimer()
    }

    public func startUpload() {
        statusError = nil
        let now = ProcessInfo.processInfo.systemUptime
        upload.isRunning = true
        upload.hasCompletedRun = false
        upload.currentMbps = 0
        upload.averageMbps = 0
        upload.samples.removeAll()

        uploadTracker.startRun(currentTotalBytes: uploadPool.byteCounter.get(), now: now)
        uploadPool.start(
            endpoints: config.activeProfile.uploadEndpoints,
            threadCount: config.uploadThreads,
            uploadChunkMB: config.uploadChunkMB
        )
        ensureTimerRunning()
        updateIdleTimer()
    }

    public func stopUpload() {
        guard upload.isRunning else { return }
        uploadPool.stop()
        let now = ProcessInfo.processInfo.systemUptime
        uploadTracker.tick(totalBytes: uploadPool.byteCounter.get(), now: now, metrics: &upload)
        upload.isRunning = false
        upload.hasCompletedRun = true
        upload.finalMbps = upload.averageMbps
        upload.currentMbps = 0
        uploadTracker.stopRun()
        cleanupTimerIfIdle()
        updateIdleTimer()
    }

    public func startBidirectional() {
        statusError = nil
        if !download.isRunning {
            startDownload()
        }
        if !upload.isRunning {
            startUpload()
        }
    }

    public func stopAll() {
        stopDownload()
        stopUpload()
    }

    public func resetAllTraffic() {
        stopAll()
        downloadPool.byteCounter.reset()
        uploadPool.byteCounter.reset()
        downloadTracker.reset()
        uploadTracker.reset()
        download = DirectionMetrics()
        upload = DirectionMetrics()
        statusError = nil
    }

    public func updateConfig(_ newConfig: SpeedTestConfig) {
        let wasDownloadRunning = download.isRunning
        let wasUploadRunning = upload.isRunning
        config = newConfig.sanitized()
        config.save()

        if wasDownloadRunning {
            stopDownload()
            startDownload()
        }
        if wasUploadRunning {
            stopUpload()
            startUpload()
        }
    }

    /// Imports an Android `PAOMAN_SPEED_TEST_CONFIG` `.conf` file from a local URL (Files / WeChat Share).
    @discardableResult
    public func importConfFile(from url: URL) -> Result<String, Error> {
        let needsSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if needsSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)
            return importConfData(data)
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    public func importConfData(_ data: Data) -> Result<String, Error> {
        do {
            let parsed = try PaoManConfParser.parse(data: data)
            var mergedProfiles = parsed.profiles
            if !mergedProfiles.contains(where: { $0.id == SpeedProfile.cloudflareDefault.id }) {
                mergedProfiles.append(.cloudflareDefault)
            }
            var updated = config
            updated.profiles = mergedProfiles
            updated.selectedProfileId = parsed.selectedProfileId
            updateConfig(updated)

            let active = updated.activeProfile
            let summary = "已导入「\(active.name)」：下载 \(active.downloadEndpoints.count) 节点 / 上传 \(active.uploadEndpoints.count) 节点"
            showTemporaryNotice(summary)
            return .success(summary)
        } catch {
            return .failure(error)
        }
    }

    public func restoreBuiltInDefaults() {
        let defaults = SpeedTestConfig.makeDefault()
        updateConfig(defaults)
        let active = defaults.activeProfile
        showTemporaryNotice("已恢复内置「\(active.name)」")
    }

    private func showTemporaryNotice(_ message: String) {
        importNotice = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self?.importNotice == message {
                self?.importNotice = nil
            }
        }
    }

    // MARK: - Timer & Idle Screen Guard

    private func ensureTimerRunning() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sampleMetrics()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func cleanupTimerIfIdle() {
        if !isAnyRunning {
            timer?.invalidate()
            timer = nil
        }
    }

    private func sampleMetrics() {
        let now = ProcessInfo.processInfo.systemUptime
        if download.isRunning {
            downloadTracker.tick(totalBytes: downloadPool.byteCounter.get(), now: now, metrics: &download)
        }
        if upload.isRunning {
            uploadTracker.tick(totalBytes: uploadPool.byteCounter.get(), now: now, metrics: &upload)
        }
        if !isAnyRunning {
            cleanupTimerIfIdle()
        }
    }

    private func updateIdleTimer() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = isAnyRunning
        #endif
    }
}
