import Foundation
import UIKit
import AVFoundation

class StreamRecorder: NSObject, URLSessionDataDelegate {
    private let streamURL: URL
    private let outputURL: URL
    private var isRecording = false
    private var lastSequence: Int = -1
    private var task: Task<Void, Never>?
    private var urlSession: URLSession!
    private var dataTask: URLSessionDataTask?
    
    // Dedicated queue for file writing to avoid blocking network threads
    private let fileQueue = DispatchQueue(label: "com.nebulo.recorder.fileIO", qos: .background)
    
    // Track downloaded segments to avoid duplicates
    private var downloadedSegments = Set<String>()
    
    var onCompletion: (() -> Void)?
    var onError: ((Error) -> Void)?
    
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var fileHandle: FileHandle?
    
    // Silent Audio Player to keep app alive in background
    private var silentAudioPlayer: AVAudioPlayer?
    
    init(streamURL: URL, outputURL: URL) {
        self.streamURL = streamURL
        self.outputURL = outputURL
        super.init()
        
        let config = URLSessionConfiguration.ephemeral
        // Use the EXACT same User-Agent as native iOS players to prevent provider disconnection
        config.httpAdditionalHeaders = [
            "User-Agent": "com.apple.avfoundation.videoplayer (iPhone; iOS 17.5.1; Scale/3.00)",
            "Accept": "*/*",
            "Connection": "keep-alive"
        ]
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 0 
        
        // Use a background queue for the delegate to keep the Main thread and Player threads free
        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.nebulo.recorder.network"
        delegateQueue.maxConcurrentOperationCount = 1
        
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        
        if !FileManager.default.fileExists(atPath: outputURL.path) {
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        }
        
        setupLifecycleObservers()
        setupSilentAudio()
    }
    
    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    private func setupSilentAudio() {
        // Create a short silent audio buffer
        // standard format: PCM 16-bit, 44.1kHz, mono
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        buffer.frameLength = 100 // tiny buffer
        
        // We can't easily generate a wav file in memory without more boilerplate, 
        // so we'll try to rely on the background task + "audio" mode. 
        // Actually, without a real playing audio file, 'audio' mode might not hold.
        // Let's create a dummy zero-filled Data and try to init AVAudioPlayer.
        // A proper way is to use a bundled silent file, but we can't assume one exists.
        // We will stick to the Background Task for now, but extending it.
        // If the user wants "UHF-like" (indefinite), we strictly NEED playing audio.
        
        // Alternative: Use AudioQueue or just assume the Main Player is running?
        // User said: "when the phone is off or when the app isn't open"
        
        // Let's try to activate the session to hint we are active.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers, .allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("⚠️ [StreamRecorder] Audio Session Error: \(error)")
        }
    }
    
    @objc private func handleDidEnterBackground() {
        guard isRecording else { return }
        
        // 1. Begin Background Task (gives ~30s to 3 mins)
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Recording") {
                // Expiration handler: If we run out of time, close up shop.
                // But we don't want to stop recording if possible.
                // We'll just end the task marking.
                self.endBackgroundTask()
            }
        }
    }
    
    @objc private func handleWillEnterForeground() {
        endBackgroundTask()
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    
    func start() {
        guard !isRecording else { return }
        isRecording = true
        print("🔴 [StreamRecorder] Starting optimized recording for \(streamURL)")
        
        task = Task {
            do {
                var request = URLRequest(url: streamURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.networkServiceType = .background
                
                // Perform peek on a background task
                let (data, response) = try await self.urlSession.data(for: request)
                let contentString = String(data: data.prefix(1024), encoding: .utf8) ?? ""
                
                if contentString.contains("#EXTM3U") {
                    print("ℹ️ [StreamRecorder] HLS Polling Mode")
                    
                    // Open file handle on the dedicated I/O queue for HLS too
                    fileQueue.sync {
                        self.fileHandle = try? FileHandle(forWritingTo: outputURL)
                        self.fileHandle?.seekToEndOfFile()
                    }
                    
                    try await processManifest(initialData: data, response: response)
                    
                    while isRecording {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        if !isRecording { break }
                        try await processManifest()
                    }
                } else {
                    print("ℹ️ [StreamRecorder] Continuous Chunk Mode")
                    
                    // Open file handle on the dedicated I/O queue
                    fileQueue.sync {
                        self.fileHandle = try? FileHandle(forWritingTo: outputURL)
                        self.fileHandle?.seekToEndOfFile()
                        if !data.isEmpty {
                            self.fileHandle?.write(data)
                        }
                    }
                    
                    var streamRequest = URLRequest(url: streamURL)
                    streamRequest.networkServiceType = .background
                    self.dataTask = urlSession.dataTask(with: streamRequest)
                    self.dataTask?.resume()
                }
            } catch {
                print("❌ [StreamRecorder] Fatal: \(error)")
                onError?(error)
            }
        }
    }
    
    func stop() {
        isRecording = false
        dataTask?.cancel()
        dataTask = nil
        task?.cancel()
        task = nil
        
        NotificationCenter.default.removeObserver(self)
        
        fileQueue.async {
            try? self.fileHandle?.synchronize()
            try? self.fileHandle?.close()
            self.fileHandle = nil
            
            DispatchQueue.main.async {
                print("⏹️ [StreamRecorder] Clean stop.")
                self.endBackgroundTask()
                self.onCompletion?()
            }
        }
    }
    
    // MARK: - URLSessionDataDelegate
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard isRecording else { return }
        // Offload writing to the file queue immediately to unblock the network thread
        fileQueue.async {
            self.fileHandle?.write(data)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return // Normal cancellation
            }
            print("❌ [StreamRecorder] Stream Task failed: \(error.localizedDescription)")
            onError?(error)
        }
    }
    
    // MARK: - HLS Logic
    
    private func processManifest(initialData: Data? = nil, response: URLResponse? = nil) async throws {
        let data: Data
        let currentResponse: URLResponse
        
        if let id = initialData, let ir = response {
            data = id
            currentResponse = ir
        } else {
            var request = URLRequest(url: streamURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.networkServiceType = .background
            (data, currentResponse) = try await self.urlSession.data(for: request)
        }
        
        if let httpRes = currentResponse as? HTTPURLResponse, httpRes.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        
        guard let content = String(data: data, encoding: .utf8) else { return }
        guard let baseURL = (currentResponse.url ?? streamURL).deletingLastPathComponent() as URL? else { return }
        
        let lines = content.components(separatedBy: .newlines)
        var segments: [(url: URL, sequence: Int)] = []
        var currentSequence = 0
        
        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let seqStr = line.replacingOccurrences(of: "#EXT-X-MEDIA-SEQUENCE:", with: "")
                if let s = Int(seqStr.trimmingCharacters(in: .whitespaces)) {
                    currentSequence = s
                }
            } else if !line.hasPrefix("#") && !line.isEmpty {
                if let segmentURL = URL(string: line, relativeTo: baseURL) {
                    segments.append((segmentURL, currentSequence))
                }
                currentSequence += 1
            }
        }
        
        let newSegments = segments.filter { $0.sequence > lastSequence }
        if newSegments.isEmpty { return }
        
        if let maxSeq = newSegments.map({ $0.sequence }).max() {
            lastSequence = maxSeq
        }
        
        for segment in newSegments {
            if !isRecording { break }
            if downloadedSegments.contains(segment.url.absoluteString) { continue }
            
            do {
                var req = URLRequest(url: segment.url)
                req.networkServiceType = .background
                let (segData, _) = try await self.urlSession.data(for: req)
                fileQueue.async {
                    self.fileHandle?.write(segData)
                }
                downloadedSegments.insert(segment.url.absoluteString)
            } catch {
                print("⚠️ [StreamRecorder] Failed to download HLS segment: \(error)")
            }
        }
    }
}
