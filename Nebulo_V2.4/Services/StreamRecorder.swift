import Foundation

class StreamRecorder: NSObject {
    private let streamURL: URL
    private let outputURL: URL
    private var isRecording = false
    private var lastSequence: Int = -1
    private var task: Task<Void, Never>?
    private var urlSession = URLSession.shared
    
    // Track downloaded segments to avoid duplicates
    private var downloadedSegments = Set<String>()
    
    var onCompletion: (() -> Void)?
    var onError: ((Error) -> Void)?
    
    init(streamURL: URL, outputURL: URL) {
        self.streamURL = streamURL
        self.outputURL = outputURL
        super.init()
        
        // Create empty file
        if !FileManager.default.fileExists(atPath: outputURL.path) {
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        }
    }
    
    func start() {
        guard !isRecording else { return }
        isRecording = true
        print("🔴 [StreamRecorder] Starting loop for \(streamURL)")
        
        task = Task {
            while isRecording {
                do {
                    try await processManifest()
                } catch {
                    print("⚠️ [StreamRecorder] Manifest error: \(error)")
                }
                
                // Wait before next poll (target 5s or half segment duration usually)
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
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
        guard let content = String(data: data, encoding: .utf8),
              let baseURL = (response.url ?? streamURL).deletingLastPathComponent() as URL? else { return }
        
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
                let segmentURL: URL
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
        
        for segment in newSegments {
            if !isRecording { break }
            
            // Avoid re-downloading if sequence logic failed but URL is same
            if downloadedSegments.contains(segment.url.absoluteString) { continue }
            
            print("⬇️ [StreamRecorder] Downloading seq \(segment.sequence)")
            do {
                let (segData, _) = try await urlSession.data(from: segment.url)
                if let handle = try? FileHandle(forWritingTo: outputURL) {
                    handle.seekToEndOfFile()
                    handle.write(segData)
                    handle.closeFile()
                    
                    lastSequence = segment.sequence
                    downloadedSegments.insert(segment.url.absoluteString)
                }
            } catch {
                print("⚠️ [StreamRecorder] Failed to download segment: \(error)")
            }
        }
    }
}
