import Foundation

// MARK: - EPG SERVICE (XMLTV PARSER)
final class EPGService: Sendable {
    
    nonisolated private var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("epg_cache.json")
    }
    
    func fetchAndParseEPG(url: URL, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async -> [String: [EPGProgram]] {
        return await Task.detached {
            let delegate = await EPGParserDelegate(onProgress: onProgress)
            let result = await delegate.parse(url: url)
            if !result.isEmpty {
                self.saveToDisk(result)
            }
            return result
        }.value
    }
    
    func loadFromDisk() -> [String: [EPGProgram]]? {
        guard let url = cacheURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: [EPGProgram]].self, from: data)
        } catch {
            return nil
        }
    }
    
    nonisolated private func saveToDisk(_ programs: [String: [EPGProgram]]) {
        guard let url = cacheURL else { return }
        do {
            let data = try JSONEncoder().encode(programs)
            try data.write(to: url)
        } catch {
            print("Failed to save EPG cache: \(error)")
        }
    }
}

// MARK: - INTERNAL PARSER DELEGATE
private final class EPGParserDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {
    private var programs: [String: [EPGProgram]] = [:]
    private var currentElement = ""
    private var currentChannelID = ""
    private var currentTitleBuffer = ""
    private var currentDescBuffer = ""
    private var currentStart: Date?
    private var currentStop: Date?
    
    private var totalBytes: Double = 0
    private var bytesRead: Double = 0
    private var lastProgressUpdate: TimeInterval = 0
    private let progressCallback: (@MainActor @Sendable (Double) -> Void)
    
    // DateFormatters are expensive, but creating them once as static is efficient
    private static let dateFormatterWithSpace: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMddHHmmss Z"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()
    
    private static let dateFormatterNoSpace: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMddHHmmssZ"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()
    
    private static let fallbackFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMddHHmmss"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()
    
    init(onProgress: @escaping @MainActor @Sendable (Double) -> Void) {
        self.progressCallback = onProgress
        super.init()
    }

    func parse(url: URL) async -> [String: [EPGProgram]] {
        self.programs = [:]
        self.bytesRead = 0
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            self.totalBytes = Double(response.expectedContentLength)
            if self.totalBytes <= 0 { self.totalBytes = Double(data.count) }
            
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.parse()
            
            await MainActor.run { progressCallback(1.0) }
            return self.programs
        } catch {
            print("EPG Error: \(error)")
            await MainActor.run { progressCallback(0.0) }
            return [:]
        }
    }
    
    private func parseDate(_ dateStr: String) -> Date? {
        if let d = EPGParserDelegate.dateFormatterWithSpace.date(from: dateStr) { return d }
        if let d = EPGParserDelegate.dateFormatterNoSpace.date(from: dateStr) { return d }
        let prefix = String(dateStr.prefix(14))
        return EPGParserDelegate.fallbackFormatter.date(from: prefix)
    }

    // MARK: - XMLParserDelegate
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
            currentTitleBuffer = ""
            currentDescBuffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "title" {
            currentTitleBuffer += string
        } else if currentElement == "desc" {
            currentDescBuffer += string
        }
        
        bytesRead += Double(string.utf8.count)
        if totalBytes > 0 {
            let now = Date().timeIntervalSince1970
            if now - lastProgressUpdate > 1.0 {
                lastProgressUpdate = now
                let progress = min(bytesRead / totalBytes, 0.99)
                Task { @MainActor [progressCallback] in progressCallback(progress) }
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "programme" {
            let cleanTitle = currentTitleBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanDesc = currentDescBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !currentChannelID.isEmpty, !cleanTitle.isEmpty, let start = currentStart, let stop = currentStop else { return }
            let prog = EPGProgram(channelID: currentChannelID, title: cleanTitle, description: cleanDesc.isEmpty ? nil : cleanDesc, start: start, stop: stop)
            if programs[currentChannelID] == nil { programs[currentChannelID] = [] }
            programs[currentChannelID]?.append(prog)
        }
    }
}
