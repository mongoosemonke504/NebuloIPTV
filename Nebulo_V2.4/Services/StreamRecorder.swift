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
        // Create a proper silent WAV file in memory
        let sampleRate: Int32 = 44100
        let duration = 10 // seconds
        let numSamples = sampleRate * Int32(duration)
        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let blockAlign = numChannels * bitsPerSample / 8
        let byteRate = sampleRate * Int32(blockAlign)
        let dataSize = numSamples * Int32(blockAlign)
        let chunkSize = 36 + dataSize
        
        var data = Data()
        
        // RIFF chunk
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.append(withUnsafeBytes(of: UInt32(chunkSize).littleEndian) { Data($0) })
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        
        // fmt chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        data.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) }) // chunk size 16
        data.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // PCM
        data.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        
        // data chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        data.append(Data(count: Int(dataSize))) // Zeroed data
        
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers, .allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true)
            
            silentAudioPlayer = try AVAudioPlayer(data: data)
            silentAudioPlayer?.numberOfLoops = -1 // Infinite loop
            silentAudioPlayer?.volume = 0.0 // Silent
            silentAudioPlayer?.prepareToPlay()
            print("✅ [StreamRecorder] Silent Audio Player Ready")
        } catch {
            print("⚠️ [StreamRecorder] Silent Audio Setup Failed: \(error)")
        }
    }
    
    @objc private func handleDidEnterBackground() {
        guard isRecording else { return }
        print("🌙 [StreamRecorder] App Entering Background. Starting Silent Audio Keeper.")
        silentAudioPlayer?.play()
    }
    
    @objc private func handleWillEnterForeground() {
        print("☀️ [StreamRecorder] App Entering Foreground. Stopping Silent Audio Keeper.")
        silentAudioPlayer?.stop()
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
