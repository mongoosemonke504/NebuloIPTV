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
        for (index, url) in urls.enumerated() {
            print("⏳ [EPGService] Fetching EPG: \(url.absoluteString)")
            
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let result = await parseEPGData(data)
                
                
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