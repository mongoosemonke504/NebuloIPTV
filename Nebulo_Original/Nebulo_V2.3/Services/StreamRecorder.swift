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
    
    
    private let fileQueue = DispatchQueue(label: "com.nebulo.recorder.fileIO", qos: .background)
    
    
    private var downloadedSegments = Set<String>()
    
    var onCompletion: (() -> Void)?
    var onError: ((Error) -> Void)?
    
    private var fileHandle: FileHandle?
    
    
    private var silentAudioPlayer: AVAudioPlayer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    init(streamURL: URL, outputURL: URL) {
        self.streamURL = streamURL
        self.outputURL = outputURL
        super.init()
        
        let config = URLSessionConfiguration.ephemeral
        
        config.httpAdditionalHeaders = [
            "User-Agent": "com.apple.avfoundation.videoplayer (iPhone; iOS 17.5.1; Scale/3.00)",
            "Accept": "*/*",
            "Connection": "keep-alive"
        ]
        
        config.timeoutIntervalForRequest = 300 
        config.timeoutIntervalForResource = 0 
        config.isDiscretionary = false 
        config.sessionSendsLaunchEvents = true
        
        
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
    
    private func beginBackgroundTask() {
        if backgroundTask != .invalid { return }
        print("🛡️ [StreamRecorder] Beginning Background Task assertion.")
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "NebuloRecording") { [weak self] in
            print("⚠️ [StreamRecorder] System forcing expiration of background task!")
            self?.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            print("🛡️ [StreamRecorder] Ending Background Task assertion.")
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    
    private func setupSilentAudio() {
        
        let sampleRate: Int32 = 44100
        let duration = 10 
        let numSamples = sampleRate * Int32(duration)
        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let blockAlign = numChannels * bitsPerSample / 8
        let byteRate = sampleRate * Int32(blockAlign)
        let dataSize = numSamples * Int32(blockAlign)
        let chunkSize = 36 + dataSize
        
        var data = Data()
        
        
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) 
        data.append(withUnsafeBytes(of: UInt32(chunkSize).littleEndian) { Data($0) })
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) 
        
        
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) 
        data.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) }) 
        data.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) 
        data.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        
        
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) 
        data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        data.append(Data(count: Int(dataSize))) 
        
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            
            silentAudioPlayer = try AVAudioPlayer(data: data)
            silentAudioPlayer?.numberOfLoops = -1 
            silentAudioPlayer?.volume = 0.01 
            silentAudioPlayer?.prepareToPlay()
            print("✅ [StreamRecorder] Silent Audio Player Ready")
        } catch {
            print("⚠️ [StreamRecorder] Silent Audio Setup Failed: \(error)")
        }
    }
    
    @objc private func handleDidEnterBackground() {
        guard isRecording else { return }
        print("🌙 [StreamRecorder] App Entering Background.")
        
        if silentAudioPlayer?.isPlaying == false {
            silentAudioPlayer?.play()
        }
    }
    
    @objc private func handleWillEnterForeground() {
        print("☀️ [StreamRecorder] App Entering Foreground.")
        
        
    }
    
    func start() {
        guard !isRecording else { return }
        isRecording = true
        beginBackgroundTask()
        
        
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            silentAudioPlayer?.play()
        } catch {
            print("⚠️ [StreamRecorder] Failed to activate audio session: \(error)")
        }
        
        print("🔴 [StreamRecorder] Starting optimized recording for \(streamURL)")
        
        
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.endBackgroundTask()
        }
        
        Task.detached(priority: .userInitiated) {
            do {
                var request = URLRequest(url: self.streamURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.networkServiceType = .background
                request.allowsCellularAccess = true
                
                
                let (data, response) = try await self.urlSession.data(for: request)
                let contentString = String(data: data.prefix(1024), encoding: .utf8) ?? ""
                
                if contentString.contains("#EXTM3U") {
                    print("ℹ️ [StreamRecorder] HLS Polling Mode")
                    
                    self.fileQueue.sync {
                        self.fileHandle = try? FileHandle(forWritingTo: self.outputURL)
                        self.fileHandle?.seekToEndOfFile()
                    }
                    
                    try await self.processManifest(initialData: data, response: response)
                    self.scheduleNextPoll()
                    
                } else {
                    print("ℹ️ [StreamRecorder] Continuous Chunk Mode")
                    
                    self.fileQueue.sync {
                        self.fileHandle = try? FileHandle(forWritingTo: self.outputURL)
                        self.fileHandle?.seekToEndOfFile()
                        if !data.isEmpty {
                            self.fileHandle?.write(data)
                        }
                    }
                    
                    var streamRequest = URLRequest(url: self.streamURL)
                    streamRequest.networkServiceType = .background
                    streamRequest.allowsCellularAccess = true
                    self.dataTask = self.urlSession.dataTask(with: streamRequest)
                    self.dataTask?.resume()
                }
            } catch {
                print("❌ [StreamRecorder] Fatal: \(error)")
                self.endBackgroundTask()
                self.onError?(error)
            }
        }
    }
    
    private func scheduleNextPoll() {
        guard isRecording else { return }
        
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self = self, self.isRecording else { return }
            Task {
                do {
                    try await self.processManifest()
                    self.scheduleNextPoll()
                } catch {
                    print("⚠️ [StreamRecorder] Poll failed: \(error)")
                    
                    self.scheduleNextPoll()
                }
            }
        }
    }
    
    func stop() {
        isRecording = false
        silentAudioPlayer?.stop()
        dataTask?.cancel()
        dataTask = nil
        
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
    
    
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard isRecording else { return }
        
        fileQueue.async {
            self.fileHandle?.write(data)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return 
            }
            print("❌ [StreamRecorder] Stream Task failed: \(error.localizedDescription)")
            onError?(error)
        }
    }
    
    
    
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
        
        
        if downloadedSegments.count > 100 {
            
        }
    }
}
