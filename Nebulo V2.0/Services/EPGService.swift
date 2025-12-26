import Foundation

// MARK: - EPG SERVICE (XMLTV PARSER)
class EPGService: NSObject, XMLParserDelegate, Sendable {
    private var programs: [String: [EPGProgram]] = [:]
    private var currentElement = ""
    private var currentChannelID = ""
    private var currentTitle = ""
    private var currentStart: Date?
    private var currentStop: Date?
    
    private var totalBytes: Double = 0
    private var bytesRead: Double = 0
    private var progressCallback: (@MainActor @Sendable (Double) -> Void)?
    
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMddHHmmss Z"
        return df
    }()
    
    private let fallbackFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMddHHmmss"
        return df
    }()

    @MainActor
    func fetchAndParseEPG(url: URL, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async -> [String: [EPGProgram]] {
        self.programs = [:]
        self.progressCallback = onProgress
        self.bytesRead = 0
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            self.totalBytes = Double(response.expectedContentLength)
            if self.totalBytes <= 0 { self.totalBytes = Double(data.count) }
            
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.parse()
            
            onProgress(1.0)
            return self.programs
        } catch {
            print("EPG Error: \(error)")
            onProgress(0.0)
            return [:]
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        if elementName == "programme" {
            currentChannelID = attributeDict["channel"] ?? ""
            if let startStr = attributeDict["start"] {
                currentStart = dateFormatter.date(from: startStr) ?? fallbackFormatter.date(from: String(startStr.prefix(14)))
            }
            if let stopStr = attributeDict["stop"] {
                currentStop = dateFormatter.date(from: stopStr) ?? fallbackFormatter.date(from: String(stopStr.prefix(14)))
            }
            currentTitle = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "title" {
            currentTitle += string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        bytesRead += Double(string.utf8.count)
        if let callback = progressCallback, totalBytes > 0 {
            let progress = min(bytesRead / totalBytes, 0.99)
            Task { @MainActor in callback(progress) }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "programme" {
            guard !currentChannelID.isEmpty, !currentTitle.isEmpty, let start = currentStart, let stop = currentStop else { return }
            let prog = EPGProgram(channelID: currentChannelID, title: currentTitle, start: start, stop: stop)
            if programs[currentChannelID] == nil { programs[currentChannelID] = [] }
            programs[currentChannelID]?.append(prog)
        }
    }
}
