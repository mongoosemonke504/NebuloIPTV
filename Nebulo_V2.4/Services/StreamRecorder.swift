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
        print("🔴 [StreamRecorder] Starting loop for \(streamURL)")
        
        // Request Background Time
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Recording") {
            // Expiration handler
            print("⚠️ [StreamRecorder] Background time expired.")
            self.stop()
        }
        
        task = Task {
            while isRecording {
                do {
                    try await processManifest()
                } catch {
                    print("⚠️ [StreamRecorder] Manifest error: \(error)")
                }
                
                // Wait before next poll (target 5s or half segment duration usually)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            
            // End Background Task when loop finishes
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
        print("obs [StreamRecorder] Stopped.")
        onCompletion?()
    }
    
    private func processManifest() async throws {
        let (data, response) = try await urlSession.data(from: streamURL)
        
        // Check for HTTP Error
        if let httpRes = response as? HTTPURLResponse, httpRes.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        
        guard let content = String(data: data, encoding: .utf8) else { return }
        
        // Basic M3U8 Check
        if !content.contains("#EXTM3U") {
            // Not a manifest? Maybe a direct TS stream? 
            // Writing raw stream dump is complex in a polling loop (needs continuous stream).
            // For now, assume M3U8.
            print("⚠️ [StreamRecorder] Content is not M3U8")
            return 
        }
        
        guard let baseURL = (response.url ?? streamURL).deletingLastPathComponent() as URL? else { return }
        
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