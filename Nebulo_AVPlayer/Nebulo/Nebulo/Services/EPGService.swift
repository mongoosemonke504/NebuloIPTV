import Foundation
import Compression

fileprivate actor ProgressState {
    var values: [Int: Double] = [:]
    let total: Int
    let onUpdate: (Double) -> Void
    
    init(total: Int, onUpdate: @escaping (Double) -> Void) {
        self.total = total
        self.onUpdate = onUpdate
    }
    
    func update(index: Int, value: Double) {
        values[index] = value
        let sum = values.values.reduce(0, +)
        onUpdate(sum / Double(total))
    }
}

class EPGService: NSObject, XMLParserDelegate {
    
    nonisolated func loadFromDisk() -> (epg: [String: [EPGProgram]], map: [String: String])? {
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
    
    nonisolated func saveToDisk(epg: [String: [EPGProgram]], map: [String: String]) {
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
    
    nonisolated private func getCacheURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epg_cache_v2.json")
    }
    
    func fetchAndMergeEPGs(urls: [URL], progress: @escaping (Double) -> Void) async -> (epg: [String: [EPGProgram]], map: [String: String]) {
        return await Task.detached(priority: .userInitiated) {
            var mergedEPG: [String: [EPGProgram]] = [:]
            var mergedMap: [String: String] = [:]
            
            let total = Double(urls.count)
            if total == 0 { return ([:], [:]) }
            
            let tracker = ProgressState(total: urls.count, onUpdate: progress)
            
            let downloadShare = 0.2
            let parseShare = 0.8
            
            let results = await withTaskGroup(of: (url: URL, epg: [String: [EPGProgram]], map: [String: String])?.self) { group -> [(url: URL, epg: [String: [EPGProgram]], map: [String: String])] in
                
                for (index, url) in urls.enumerated() {
                    group.addTask {
                        print("⏳ [EPGService] Fetching: \(url.absoluteString)")
                        
                        let sizeKey = "epg_size_" + url.absoluteString
                        let timeKey = "epg_parse_time_" + url.absoluteString
                        
                        let cachedSize = UserDefaults.standard.integer(forKey: sizeKey)
                        let cachedTime = UserDefaults.standard.double(forKey: timeKey)
                        
                        let expectedSize = cachedSize > 0 ? Int64(cachedSize) : nil
                        let expectedParseTime = cachedTime > 0 ? cachedTime : 20.0
                        
                        do {
                            let fileURL = try await self.downloadFileWithProgress(url: url, expectedSize: expectedSize) { fileProgress in
                                let currentFileProgress = fileProgress * downloadShare
                                Task { await tracker.update(index: index, value: currentFileProgress) }
                            }
                            
                            if let attr = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                               let fileSize = attr[.size] as? Int64 {
                                UserDefaults.standard.set(Int(fileSize), forKey: sizeKey)
                            }
                            
                            if let data = try? Data(contentsOf: fileURL) {
                                let ticker = Task {
                                    let startTime = Date()
                                    while !Task.isCancelled {
                                        let elapsed = Date().timeIntervalSince(startTime)
                                        let progressFactor = elapsed / expectedParseTime
                                        let estimatedProgress = min(1.0 - exp(-2.5 * progressFactor), 0.99)
                                        let totalFileProgress = downloadShare + (estimatedProgress * parseShare)
                                        await tracker.update(index: index, value: totalFileProgress)
                                        try? await Task.sleep(nanoseconds: 100_000_000)
                                    }
                                }
                                
                                let parseStart = Date()
                                let result = await self.parseEPGData(data)
                                ticker.cancel()
                                
                                let actualDuration = Date().timeIntervalSince(parseStart)
                                UserDefaults.standard.set(actualDuration, forKey: timeKey)
                                
                                try? FileManager.default.removeItem(at: fileURL)
                                
                                await tracker.update(index: index, value: 1.0)
                                return (url, result.epg, result.map)
                            }
                        } catch {
                            print("❌ [EPGService] Error fetching \(url): \(error)")
                            Task { await tracker.update(index: index, value: 1.0) }
                        }
                        return nil
                    }
                }
                
                var gathered: [(url: URL, epg: [String: [EPGProgram]], map: [String: String])] = []
                for await result in group {
                    if let r = result { gathered.append(r) }
                }
                return gathered
            }
            
            for result in results {
                for (name, id) in result.map { mergedMap[name] = id }
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
            
            let totalPrograms = mergedEPG.values.reduce(0) { $0 + $1.count }
            print("✅ [EPGService] Merged Total: \(totalPrograms) programs for \(mergedEPG.count) channels.")
            
            self.saveToDisk(epg: mergedEPG, map: mergedMap)
            return (mergedEPG, mergedMap)
        }.value
    }
    
    
    private func decompress(data: Data) -> Data? {
        let bufferSize = 64_000_000
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        
        let decodedSize = data.withUnsafeBytes { sourcePtr in
            return compression_decode_buffer(
                destinationBuffer,
                bufferSize,
                sourcePtr.bindMemory(to: UInt8.self).baseAddress!,
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        
        if decodedSize > 0 {
            let res = Data(bytes: destinationBuffer, count: decodedSize)
            destinationBuffer.deallocate()
            return res
        }
        
        destinationBuffer.deallocate()
        return nil
    }
    
    private func downloadFileWithProgress(url: URL, expectedSize: Int64?, onProgress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = EPGDownloadDelegate(onProgress: onProgress, continuation: continuation, expectedSize: expectedSize)
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
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
