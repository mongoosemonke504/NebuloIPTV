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
        // XMLTV format: 20231027120000 +0000
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
                
                // Merge Map
                for (name, id) in result.map {
                    mergedMap[name] = id
                }
                
                // Merge EPG
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
            let delegate = EPGParserDelegate(dateFormatter: self.dateFormatter)
            parser.delegate = delegate
            parser.parse()
            return (delegate.epgData, delegate.channelNameMap)
        }.value
    }
}

// Separate delegate class to avoid state pollution during concurrent merges if any
class EPGParserDelegate: NSObject, XMLParserDelegate {
    var epgData: [String: [EPGProgram]] = [:]
    var channelNameMap: [String: String] = [:] // Name -> ID
    private let dateFormatter: DateFormatter
    
    private var currentElement = ""
    private var currentChannelID = ""
    private var currentStart: Date?
    private var currentStop: Date?
    private var currentTitle = ""
    private var currentDesc = ""
    private var currentDisplayName = ""
    
    init(dateFormatter: DateFormatter) {
        self.dateFormatter = dateFormatter
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
        // Remove non-numeric characters for simple formats if needed, 
        // but typically XMLTV looks like "20231027120000 +0000" or "20231027120000"
        
        let cleaned = string.trimmingCharacters(in: .whitespaces)
        
        // Try standard format: 20231027120000 +0000
        if let date = dateFormatter.date(from: cleaned) {
            return date
        }
        
        // Try fallback format: 20231027120000
        let fallbackFormatter = DateFormatter()
        fallbackFormatter.dateFormat = "yyyyMMddHHmmss"
        if let date = fallbackFormatter.date(from: cleaned) {
            return date
        }
        
        // Try another common variant: 2023-10-27 12:00:00
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = isoFormatter.date(from: cleaned) {
            return date
        }

        return nil
    }
}