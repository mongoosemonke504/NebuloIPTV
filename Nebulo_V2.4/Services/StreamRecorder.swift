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
                // 1. Light-weight Peek at the content to decide strategy
                var request = URLRequest(url: streamURL)
                request.setValue("Nebulo/2.4 (iOS)", forHTTPHeaderField: "User-Agent")
                // Use a short timeout for the peek to prevent hanging
                request.timeoutInterval = 10
                
                let (bytes, response) = try await urlSession.bytes(for: request)
                
                if let httpRes = response as? HTTPURLResponse, httpRes.statusCode >= 400 {
                    throw URLError(.badServerResponse)
                }
                
                // Read just enough to check for M3U8 header
                var headerData = Data()
                var byteIterator = bytes.makeAsyncIterator()
                
                // Read first 1024 bytes or until end
                for _ in 0..<1024 {
                    if let byte = try await byteIterator.next() {
                        headerData.append(byte)
                    } else {
                        break
                    }
                }
                
                let contentString = String(data: headerData, encoding: .utf8) ?? ""
                
                if contentString.contains("#EXTM3U") {
                    // Strategy: HLS Polling
                    print("ℹ️ [StreamRecorder] Strategy: HLS Manifest")
                    // For HLS, we need to finish this 'bytes' request and use polling
                    // because HLS requires multiple separate requests.
                    try await processManifest(initialData: headerData, response: response)
                    
                    while isRecording {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        if !isRecording { break }
                        try await processManifest()
                    }
                } else {
                    // Strategy: Continuous Download (TS/Direct)
                    print("ℹ️ [StreamRecorder] Strategy: Continuous Stream")
                    
                    // Write the header we already pulled
                    if !headerData.isEmpty {
                        try appendToFile(data: headerData)
                    }
                    
                    // Continue downloading from the EXISTING byte stream
                    try await downloadFromByteStream(byteIterator)
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
    
    private func appendToFile(data: Data) throws {
        guard let handle = try? FileHandle(forWritingTo: outputURL) else {
            throw URLError(.cannotCreateFile)
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }
    
    private func downloadFromByteStream(_ iterator: URLSession.AsyncBytes.Iterator) async throws {
        var mutableIterator = iterator
        var buffer = Data()
        let maxBufferSize = 1024 * 512 // 512KB Buffer
        
        while isRecording {
            if let byte = try await mutableIterator.next() {
                buffer.append(byte)
                
                if buffer.count >= maxBufferSize {
                    try appendToFile(data: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            } else {
                // End of stream
                break
            }
        }
        
        // Final flush
        if !buffer.isEmpty {
            try appendToFile(data: buffer)
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
            request.setValue("Nebulo/2.4 (iOS)", forHTTPHeaderField: "User-Agent")
            (data, currentResponse) = try await urlSession.data(for: request)
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
        
        // Filter new segments
        let newSegments = segments.filter { $0.sequence > lastSequence }
        
        if newSegments.isEmpty { return }
        
        if let maxSeq = newSegments.map({ $0.sequence }).max() {
            lastSequence = maxSeq
        }
        
        for segment in newSegments {
            if !isRecording { break }
            if downloadedSegments.contains(segment.url.absoluteString) { continue }
            
            print("⬇️ [StreamRecorder] Downloading HLS seq \(segment.sequence)")
            do {
                var request = URLRequest(url: segment.url)
                request.setValue("Nebulo/2.4 (iOS)", forHTTPHeaderField: "User-Agent")
                let (segData, _) = try await urlSession.data(for: request)
                try appendToFile(data: segData)
                downloadedSegments.insert(segment.url.absoluteString)
            } catch {
                print("⚠️ [StreamRecorder] Failed to download segment: \(error)")
            }
        }
    }
}