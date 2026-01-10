import Foundation
import UIKit

class StreamRecorder: NSObject {
    private let streamURL: URL
    private let outputURL: URL
    private var isRecording = false
    private var lastSequence: Int = -1
    private var task: Task<Void, Never>?
    private var urlSession: URLSession
    
    // Track downloaded segments to avoid duplicates
    private var downloadedSegments = Set<String>()
    
    var onCompletion: (() -> Void)?
    var onError: ((Error) -> Void)?
    
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    init(streamURL: URL, outputURL: URL) {
        self.streamURL = streamURL
        self.outputURL = outputURL
        
        let config = URLSessionConfiguration.default
        // Mimic a browser/player to avoid blocking
        config.httpAdditionalHeaders = ["User-Agent": "Nebulo/2.4 (iOS)"]
        self.urlSession = URLSession(configuration: config)
        
        super.init()
        
        // Create empty file if not exists
        if !FileManager.default.fileExists(atPath: outputURL.path) {
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        }
    }
    
    func start() {
        guard !isRecording else { return }
        isRecording = true
        print("🔴 [StreamRecorder] Starting recording for \(streamURL)")
        
        // Request Background Time
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Recording") {
            print("⚠️ [StreamRecorder] Background time expired.")
            self.stop()
        }
        
        task = Task {
            do {
                // 1. Peek at the content to decide strategy
                let (data, response) = try await urlSession.data(from: streamURL)
                if let content = String(data: data, encoding: .utf8), content.contains("#EXTM3U") {
                    // Strategy: HLS Polling
                    print("ℹ️ [StreamRecorder] Strategy: HLS Manifest")
                    try await processManifest(initialData: data, response: response)
                    
                    while isRecording {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        if !isRecording { break }
                        try await processManifest()
                    }
                } else {
                    // Strategy: Continuous Download (TS/Direct)
                    print("ℹ️ [StreamRecorder] Strategy: Continuous Stream")
                    try await downloadContinuousStream()
                }
            } catch {
                print("❌ [StreamRecorder] Critical failure: \(error)")
                onError?(error)
            }
            
            if self.backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }
    }
    
    func stop() {
        isRecording = false
        task?.cancel()
        task = nil
        print("⏹️ [StreamRecorder] Stopped.")
        onCompletion?()
    }
    
    private func downloadContinuousStream() async throws {
        var request = URLRequest(url: streamURL)
        request.timeoutInterval = 30
        
        let (bytes, response) = try await urlSession.bytes(for: request)
        
        if let httpRes = response as? HTTPURLResponse, httpRes.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        
        guard let handle = try? FileHandle(forWritingTo: outputURL) else {
            throw URLError(.cannotCreateFile)
        }
        
        defer { try? handle.close() }
        
        var buffer = Data()
        let maxBufferSize = 1024 * 512 // 512KB Buffer
        
        for try await byte in bytes {
            if !isRecording { break }
            buffer.append(byte)
            
            if buffer.count >= maxBufferSize {
                handle.write(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        
        // Final flush
        if !buffer.isEmpty {
            handle.write(buffer)
        }
    }
    
    private func processManifest(initialData: Data? = nil, response: URLResponse? = nil) async throws {
        let data: Data
        let currentResponse: URLResponse
        
        if let id = initialData, let ir = response {
            data = id
            currentResponse = ir
        } else {
            (data, currentResponse) = try await urlSession.data(from: streamURL)
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
                // It's a segment
                var segmentURL: URL
                if line.hasPrefix("http") {
                    segmentURL = URL(string: line)!
                } else {
                    segmentURL = baseURL.appendingPathComponent(line)
                }
                
                segments.append((segmentURL, currentSequence))
                currentSequence += 1
            }
        }
        
        // Filter new segments (only those we haven't seen, by sequence OR unique URL)
        // Note: Some servers reset sequence on restart, so URL check is backup.
        let newSegments = segments.filter { $0.sequence > lastSequence }
        
        if newSegments.isEmpty { return }
        
        // Update last sequence
        if let maxSeq = newSegments.map({ $0.sequence }).max() {
            lastSequence = maxSeq
        }
        
        for segment in newSegments {
            if !isRecording { break }
            
            // Double check duplicate download
            if downloadedSegments.contains(segment.url.absoluteString) { continue }
            
            print("⬇️ [StreamRecorder] Downloading seq \(segment.sequence)")
            do {
                let (segData, _) = try await urlSession.data(from: segment.url)
                if let handle = try? FileHandle(forWritingTo: outputURL) {
                    handle.seekToEndOfFile()
                    handle.write(segData)
                    handle.closeFile()
                    
                    downloadedSegments.insert(segment.url.absoluteString)
                }
            } catch {
                print("⚠️ [StreamRecorder] Failed to download segment: \(error)")
            }
        }
    }
}