import Foundation
import UIKit

class StreamRecorder: NSObject, URLSessionDataDelegate {
    private let streamURL: URL
    private let outputURL: URL
    private var isRecording = false
    private var lastSequence: Int = -1
    private var task: Task<Void, Never>?
    private var urlSession: URLSession!
    private var dataTask: URLSessionDataTask?
    
    // Track downloaded segments to avoid duplicates
    private var downloadedSegments = Set<String>()
    
    var onCompletion: (() -> Void)?
    var onError: ((Error) -> Void)?
    
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var fileHandle: FileHandle?
    
    init(streamURL: URL, outputURL: URL) {
        self.streamURL = streamURL
        self.outputURL = outputURL
        super.init()
        
        let config = URLSessionConfiguration.default
        // Use a more standard User-Agent to avoid being flagged/dropped by providers
        config.httpAdditionalHeaders = [
            "User-Agent": "AppleCoreMedia/1.0.0.21G71 (iPhone; U; CPU OS 17_5_1 like Mac OS X; en_us)",
            "Accept": "*/*",
            "Connection": "keep-alive"
        ]
        // Increase timeout for slow streams
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 0 // Allow infinite duration for live streams
        
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        
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
                // 1. Peek at the content type or first few bytes to decide strategy
                var request = URLRequest(url: streamURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                
                let (data, response) = try await URLSession.shared.data(for: request)
                let contentString = String(data: data.prefix(1024), encoding: .utf8) ?? ""
                
                if contentString.contains("#EXTM3U") {
                    // Strategy: HLS Polling (Separate connections for each segment)
                    print("ℹ️ [StreamRecorder] Strategy: HLS Manifest")
                    try await processManifest(initialData: data, response: response)
                    
                    while isRecording {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        if !isRecording { break }
                        try await processManifest()
                    }
                } else {
                    // Strategy: Continuous Download (Chunk-based)
                    print("ℹ️ [StreamRecorder] Strategy: Continuous Stream")
                    
                    // Open file handle once for the duration of the stream
                    self.fileHandle = try? FileHandle(forWritingTo: outputURL)
                    self.fileHandle?.seekToEndOfFile()
                    
                    // Write the header we already pulled during peek
                    if !data.isEmpty {
                        self.fileHandle?.write(data)
                    }
                    
                    // Start the delegate-based task
                    let streamRequest = URLRequest(url: streamURL)
                    self.dataTask = urlSession.dataTask(with: streamRequest)
                    self.dataTask?.resume()
                }
            } catch {
                print("❌ [StreamRecorder] Critical failure: \(error)")
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
        
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
        
        print("⏹️ [StreamRecorder] Stopped.")
        
        if self.backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
        
        onCompletion?()
    }
    
    // MARK: - URLSessionDataDelegate
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard isRecording else { return }
        // Write chunks immediately as they arrive (Delegate handles buffering efficiently)
        fileHandle?.write(data)
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
            (data, currentResponse) = try await URLSession.shared.data(for: request)
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
                let (segData, _) = try await URLSession.shared.data(from: segment.url)
                if let handle = try? FileHandle(forWritingTo: outputURL) {
                    handle.seekToEndOfFile()
                    handle.write(segData)
                    handle.closeFile()
                    downloadedSegments.insert(segment.url.absoluteString)
                }
            } catch {
                print("⚠️ [StreamRecorder] Failed to download HLS segment: \(error)")
            }
        }
    }
}
