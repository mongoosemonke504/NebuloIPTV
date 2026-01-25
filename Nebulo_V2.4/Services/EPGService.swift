import Foundation

class EPGService: NSObject, XMLParserDelegate {
    private var currentEPG: [String: [EPGProgram]] = [:]
    private var currentProgram: EPGProgram?
    private var currentElement = ""
    private var currentTitle = ""
    private var currentDesc = ""
    private var currentChannelID = ""
    private var currentStart: Date?
    private var currentStop: Date?
    
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        
        df.dateFormat = "yyyyMMddHHmmss Z"
        return df
    }()
    
    func loadFromDisk() -> (epg: [String: [EPGProgram]], map: [String: String])? {
        let url = getCacheURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        struct Cache: Codable {
            let epg: [String: [EPGProgram]]
            let map: [String: String]
        }
        if let cached = try? JSONDecoder().decode(Cache.self, from: data) {
            return (cached.epg, cached.map)
        }
        return nil
    }
    
    func saveToDisk(epg: [String: [EPGProgram]], map: [String: String]) {
        let url = getCacheURL()
        struct Cache: Codable {
            let epg: [String: [EPGProgram]]
            let map: [String: String]
        }
        let cache = Cache(epg: epg, map: map)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: url)
        }
    }
    
    private func getCacheURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epg_cache_v2.json")
    }
    
    func fetchAndMergeEPGs(urls: [URL], progress: @escaping (Double) -> Void) async -> (epg: [String: [EPGProgram]], map: [String: String]) {
        var mergedEPG: [String: [EPGProgram]] = [:]
        var mergedMap: [String: String] = [:]
        
        let total = Double(urls.count)
        
        // Split progress: 20% for download, 80% for parsing (since parsing is the bottleneck)
        let downloadShare = 0.2
        let parseShare = 0.8
        
        for (index, url) in urls.enumerated() {
            print("⏳ [EPGService] Fetching EPG: \(url.absoluteString)")
            
            // Retrieve cached size & parse time for better progress estimation
            let sizeKey = "epg_size_" + url.absoluteString
            let timeKey = "epg_parse_time_" + url.absoluteString
            
            let cachedSize = UserDefaults.standard.integer(forKey: sizeKey)
            let cachedTime = UserDefaults.standard.double(forKey: timeKey)
            
            let expectedSize = cachedSize > 0 ? Int64(cachedSize) : nil
            let expectedParseTime = cachedTime > 0 ? cachedTime : 20.0 // Default to 20s if unknown
            
            let base = Double(index) / total
            let fileShare = 1.0 / total
            
            do {
                // Report progress during download (0.0 to 0.2 of this file's share)
                let fileURL = try await downloadFileWithProgress(url: url, expectedSize: expectedSize) { fileProgress in
                    let currentFileProgress = fileProgress * downloadShare
                    progress(base + (currentFileProgress * fileShare))
                }
                
                // Cache the downloaded file size
                if let attr = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let fileSize = attr[.size] as? Int64 {
                    UserDefaults.standard.set(Int(fileSize), forKey: sizeKey)
                }
                
                // Parsing (0.2 to 1.0 of this file's share)
                if let data = try? Data(contentsOf: fileURL) {
                    
                    // Start a "smart ticker" that uses historical parse time
                    let ticker = Task {
                        let startTime = Date()
                        while !Task.isCancelled {
                            let elapsed = Date().timeIntervalSince(startTime)
                            
                            // Linear progress based on expected duration, capped at 99%
                            let estimatedProgress = min(elapsed / expectedParseTime, 0.99)
                            
                            let totalFileProgress = downloadShare + (estimatedProgress * parseShare)
                            progress(base + (totalFileProgress * fileShare))
                            
                            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                        }
                    }
                    
                    let parseStart = Date()
                    let result = await parseEPGData(data)
                    ticker.cancel() // Stop the ticker
                    
                    // Cache the actual parse duration for next time
                    let actualDuration = Date().timeIntervalSince(parseStart)
                    UserDefaults.standard.set(actualDuration, forKey: timeKey)
                    
                    try? FileManager.default.removeItem(at: fileURL)
                    
                    for (name, id) in result.map {
                        mergedMap[name] = id
                    }
                    
                    for (channelID, programs) in result.epg {
                        if mergedEPG[channelID] == nil {
                            mergedEPG[channelID] = programs
                        } else {
                            var existing = mergedEPG[channelID] ?? []
                            existing.append(contentsOf: programs)
                            existing.sort { $0.start < $1.start }
                            
                            var seen = Set<Date>()
                            mergedEPG[channelID] = existing.filter { prog in
                                if seen.contains(prog.start) { return false }
                                seen.insert(prog.start)
                                return true
                            }
                        }
                    }
                }
            } catch {
                print("❌ [EPGService] Error fetching/parsing: \(error)")
            }
            
            progress(Double(index + 1) / total)
        }
        
        let totalPrograms = mergedEPG.values.reduce(0) { $0 + $1.count }
        print("✅ [EPGService] Successfully parsed \(totalPrograms) programs for \(mergedEPG.count) channels.")
        
        saveToDisk(epg: mergedEPG, map: mergedMap)
        return (mergedEPG, mergedMap)
    }
    
    private func downloadFileWithProgress(url: URL, expectedSize: Int64?, onProgress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = EPGDownloadDelegate(onProgress: onProgress, continuation: continuation, expectedSize: expectedSize)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }
    
    private func parseEPGData(_ data: Data) async -> (epg: [String: [EPGProgram]], map: [String: String]) {
        return await Task.detached(priority: .userInitiated) {
            let parser = XMLParser(data: data)
            let delegate = EPGParserDelegate()
            parser.delegate = delegate
            parser.parse()
            return (delegate.epgData, delegate.channelNameMap)
        }.value
    }
}

class EPGDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    let continuation: CheckedContinuation<URL, Error>
    let expectedSize: Int64?
    private var isResumed = false
    
    init(onProgress: @escaping (Double) -> Void, continuation: CheckedContinuation<URL, Error>, expectedSize: Int64?) {
        self.onProgress = onProgress
        self.continuation = continuation
        self.expectedSize = expectedSize
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        var total = Double(totalBytesExpectedToWrite)
        if total <= 0 {
            total = Double(expectedSize ?? 10_000_000)
        }
        
        let p = min(Double(totalBytesWritten) / total, 0.99)
        onProgress(p)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !isResumed else { return }
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: location, to: tempURL)
            isResumed = true
            continuation.resume(returning: tempURL)
        } catch {
            isResumed = true
            continuation.resume(throwing: error)
        }
        session.finishTasksAndInvalidate()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error, !isResumed {
            isResumed = true
            continuation.resume(throwing: error)
            session.finishTasksAndInvalidate()
        }
    }
}

nonisolated class EPGParserDelegate: NSObject, XMLParserDelegate {
    var epgData: [String: [EPGProgram]] = [:]
    var channelNameMap: [String: String] = [:] 
    
    private static let fallbackFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMddHHmmss"
        return df
    }()
    
    private static let isoFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()
    
    
    private static let xmltvFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMddHHmmss Z"
        return df
    }()
    
    private var currentElement = ""
    private var currentChannelID = ""
    private var currentStart: Date?
    private var currentStop: Date?
    private var currentTitle = ""
    private var currentDesc = ""
    private var currentDisplayName = ""
    
    override init() {
        super.init()
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        
        if elementName == "programme" {
            currentChannelID = attributeDict["channel"] ?? ""
            if let startStr = attributeDict["start"] {
                currentStart = parseDate(startStr)
            }
            if let stopStr = attributeDict["stop"] {
                currentStop = parseDate(stopStr)
            }
            currentTitle = ""
            currentDesc = ""
        } else if elementName == "channel" {
            currentChannelID = attributeDict["id"] ?? ""
            currentDisplayName = ""
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "title" {
            currentTitle += string
        } else if currentElement == "desc" {
            currentDesc += string
        } else if currentElement == "display-name" {
            currentDisplayName += string
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "programme" {
            guard !currentChannelID.isEmpty, let start = currentStart, let stop = currentStop else { return }
            
            let program = EPGProgram(
                channelID: currentChannelID,
                title: currentTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                description: currentDesc.isEmpty ? nil : currentDesc.trimmingCharacters(in: .whitespacesAndNewlines),
                start: start,
                stop: stop
            )
            
            if epgData[currentChannelID] == nil {
                epgData[currentChannelID] = []
            }
            epgData[currentChannelID]?.append(program)
        } else if elementName == "channel" {
            let name = currentDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !name.isEmpty && !currentChannelID.isEmpty {
                channelNameMap[name] = currentChannelID
            }
        }
        currentElement = ""
    }
    
    private func parseDate(_ string: String) -> Date? {
        let cleaned = string.trimmingCharacters(in: .whitespaces)
        
        if let date = EPGParserDelegate.xmltvFormatter.date(from: cleaned) {
            return date
        }
        
        if let date = EPGParserDelegate.fallbackFormatter.date(from: cleaned) {
            return date
        }
        
        if let date = EPGParserDelegate.isoFormatter.date(from: cleaned) {
            return date
        }

        return nil
    }
}