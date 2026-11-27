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

/// Manages a pool of independent URLSession workers for one direction (download or upload).
/// Each worker owns its own ephemeral URLSession to establish separate TCP/QUIC connections
/// and avoid HTTP/2 single-connection multiplexing bottlenecks.
private final class TransferWorkerPool: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    enum Mode {
        case download
        case upload
    }

    private let mode: Mode
    private let lock = NSLock()
    private var isRunning = false
    private var sessions: [URLSession] = []
    private var targetURL: URL?
    private var uploadPayload: Data = Data()
    private var consecutiveErrors = 0

    let byteCounter = AtomicByteCounter()
    var onError: ((String?) -> Void)?

    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.paomanlema.transfer.delegate"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 16
        return q
    }()

    init(mode: Mode) {
        self.mode = mode
        super.init()
    }

    func start(urlString: String, threadCount: Int, uploadChunkMB: Int = 8) {
        stop()

        guard let url = URL(string: urlString) else {
            onError?("无效的测速地址：\(urlString)")
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
        self.targetURL = url
        self.uploadPayload = payload
        self.consecutiveErrors = 0
        self.sessions = []

        let workerCount = max(1, threadCount)
        var createdSessions: [URLSession] = []
        createdSessions.reserveCapacity(workerCount)

        for _ in 0..<workerCount {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 180
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
        uploadPayload = Data()
        lock.unlock()

        for session in activeSessions {
            session.invalidateAndCancel()
        }
    }

    private func launchNextTask(on session: URLSession) {
        lock.lock()
        guard isRunning, let baseURL = targetURL else {
            lock.unlock()
            return
        }
        let payload = uploadPayload
        lock.unlock()

        let requestURL = cacheBustedURL(baseURL)
        var request = URLRequest(url: requestURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")

        switch mode {
        case .download:
            request.httpMethod = "GET"
            let task = session.dataTask(with: request)
            task.resume()
        case .upload:
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let task = session.uploadTask(with: request, from: payload)
            task.resume()
        }
    }

    private func cacheBustedURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "_t", value: String(Int.random(in: 100_000...999_999_999))))
        components.queryItems = items
        return components.url ?? url
    }

    /// Generates a shared pseudo-random payload so proxies/TLS layers cannot compress it away.
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

    // MARK: - URLSessionDataDelegate (Download bytes)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard mode == .download else { return }
        byteCounter.add(Int64(data.count))
        lock.lock()
        consecutiveErrors = 0
        lock.unlock()
    }

    // MARK: - URLSessionTaskDelegate (Upload bytes + loop restart)

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard mode == .upload else { return }
        byteCounter.add(bytesSent)
        lock.lock()
        consecutiveErrors = 0
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let active = isRunning
        if let err = error as NSError?, err.code != NSURLErrorCancelled {
            consecutiveErrors += 1
            let errCount = consecutiveErrors
            lock.unlock()

            if active {
                if errCount >= 6 {
                    onError?(err.localizedDescription)
                }
                let delay = min(Double(errCount) * 0.25, 2.0)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.launchNextTask(on: session)
                }
            }
            return
        }
        lock.unlock()

        if active {
            launchNextTask(on: session)
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
        // Keep ~1.5s sliding window for smooth yet responsive instantaneous speed
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
        downloadPool.start(urlString: config.downloadURL, threadCount: config.downloadThreads)
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
            urlString: config.uploadURL,
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
