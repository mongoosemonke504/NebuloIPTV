import Foundation

// MARK: - STALKER SERVICE
final class StalkerService: Sendable {
    
    static let shared = StalkerService()
    
    // MARK: - HELPERS
    private static func constructAPIURL(from inputURL: URL) -> URL {
        // Common paths: /portal.php or /server/load.php
        // If the user provided path ends in /, append portal.php or server/load.php
        // We'll prioritize /server/load.php as per the prompt instruction for "iSTB style"
        // But many use /portal.php.
        // Let's try to detect or default to one.
        // If the user URL contains "portal.php" or "load.php", use it.
        let str = inputURL.absoluteString
        if str.contains("portal.php") || str.contains("load.php") {
            return inputURL
        }
        
        // Default check
        return inputURL.appendingPathComponent("server/load.php")
    }
    
    // MARK: - AUTHENTICATION (HANDSHAKE)
    func performHandshake(portalURL: URL, mac: String) async throws -> (String, URL) {
        let apiURL = StalkerService.constructAPIURL(from: portalURL)
        
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "type", value: "stb"),
            URLQueryItem(name: "action", value: "handshake"),
            URLQueryItem(name: "token", value: ""), // Empty initially
            URLQueryItem(name: "mac", value: mac),
            URLQueryItem(name: "deviceId", value: generateDeviceID(mac)), // Emulate MAG
            URLQueryItem(name: "deviceId2", value: generateDeviceID2(mac)),
            URLQueryItem(name: "signature", value: generateSignature(mac))
        ]
        
        guard let url = components?.url else { throw URLError(.badURL) }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3", forHTTPHeaderField: "User-Agent")
        request.setValue("mac=\(mac); stb_lang=en; timezone=Europe/London;", forHTTPHeaderField: "Cookie")
        request.setValue("Bearer ", forHTTPHeaderField: "Authorization") // Some require empty bearer initially?
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Validate JSON
        // Response: {"js":{"token":"..."}}
        struct StalkerResponse: Codable {
            struct JS: Codable { let token: String? }
            let js: JS?
        }
        
        do {
            let res = try JSONDecoder().decode(StalkerResponse.self, from: data)
            if let token = res.js?.token {
                return (token, apiURL)
            }
        } catch {
            // Fallback: Check if it's portal.php instead of server/load.php
            // If we defaulted to load.php and it failed (404), maybe try portal.php?
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 404 {
                // Retry with portal.php logic if implemented, but for now throw
            }
        }
        
        throw URLError(.userAuthenticationRequired)
    }
    
    // MARK: - FETCH PROFILE
    func fetchProfile(apiURL: URL, token: String, mac: String) async throws {
        // action=get_profile
        // Just to validate session and set timezone
        let _ = try await sendRequest(apiURL: apiURL, action: "get_profile", token: token, mac: mac)
    }
    
    // MARK: - FETCH GENRES
    func fetchGenres(apiURL: URL, token: String, mac: String) async throws -> [StreamCategory] {
        // action=get_itv_genres OR get_genres
        // Try get_genres first as it's standard Stalker, get_itv_genres is newer
        
        let data = try await sendRequest(apiURL: apiURL, action: "get_genres", token: token, mac: mac)
        
        struct StalkerCategory: Codable { let id: String; let title: String }
        struct GenreResponse: Codable { let js: [StalkerCategory]? }
        
        // Fallback to get_itv_genres if needed? usually get_genres works for both
        
        let res = try JSONDecoder().decode(GenreResponse.self, from: data)
        guard let cats = res.js else { return [] }
        
        return cats.compactMap {
            guard let id = Int($0.id) else { return nil }
            return StreamCategory(id: id, name: $0.title)
        }
    }
    
    // MARK: - FETCH CHANNELS
    func fetchChannels(apiURL: URL, token: String, mac: String) async throws -> [StreamChannel] {
        // action=get_all_channels
        let data = try await sendRequest(apiURL: apiURL, action: "get_all_channels", token: token, mac: mac)
        
        struct StalkerChannel: Codable {
            let id: String? // Usually "cmd" or "id"
            let name: String
            let cmd: String?
            let tv_genre_id: String?
            let logo: String?
            let epg_id: String?
        }
        struct ChannelResponse: Codable { let js: [StalkerChannel]? }
        
        let res = try JSONDecoder().decode(ChannelResponse.self, from: data)
        guard let list = res.js else { return [] }
        
        return list.compactMap { c in
            // Stalker ID often used for fetching link is "cmd" or "id"
            // Usually we play by cmd index if it's "ffrt http..."
            // But for get_link, we usually pass the "cmd" string value as "cmd" param.
            
            // We use a unique Int ID for internal storage. If ID is missing, hash the name.
            let intID = Int(c.id ?? "") ?? abs(c.name.hashValue)
            let catID = Int(c.tv_genre_id ?? "0") ?? 0
            
            // Store the "cmd" as streamURL temporarily.
            // NebuloPlayer needs to resolve this.
            // If cmd is missing, use id?
            let command = c.cmd ?? c.id ?? ""
            
            // Icon
            // Stalker often returns relative icon paths.
            // We should prepend portal URL if it's not http
            var iconURL = c.logo
            if let i = iconURL, !i.hasPrefix("http") {
                // Base is usually portal root
                let base = apiURL.deletingLastPathComponent().deletingLastPathComponent() // remove server/load.php
                iconURL = base.appendingPathComponent(i).absoluteString
            }
            
            return StreamChannel(
                id: intID,
                name: c.name,
                streamURL: command, // This is the "cmd" to resolve later
                icon: iconURL,
                categoryID: catID,
                originalName: c.name,
                epgID: c.epg_id
            )
        }
    }
    
    // MARK: - RESOLVE STREAM LINK
    func resolveLink(apiURL: URL, token: String, mac: String, cmd: String) async throws -> String {
        // action=create_link&type=itv&cmd=<channel_id/cmd>
        // Check if cmd is already a URL
        if cmd.hasPrefix("http") && !cmd.contains("ffmpeg") { return cmd }
        
        let items = [
            URLQueryItem(name: "type", value: "itv"),
            URLQueryItem(name: "action", value: "create_link"),
            URLQueryItem(name: "cmd", value: cmd),
            // Often forced_storage=0 or something
        ]
        
        let data = try await sendRequest(apiURL: apiURL, action: "create_link", token: token, mac: mac, extraParams: items)
        
        struct LinkResponse: Codable {
            struct JS: Codable { let cmd: String? }
            let js: JS?
        }
        
        let res = try JSONDecoder().decode(LinkResponse.self, from: data)
        guard let finalLink = res.js?.cmd else { throw URLError(.resourceUnavailable) }
        
        // Strip ffmpeg/ffrt
        // "ffmpeg http://..."
        var clean = finalLink
        if let range = clean.range(of: "http") {
            clean = String(clean[range.lowerBound...])
        }
        clean = clean.trimmingCharacters(in: .whitespaces)
        return clean
    }
    
    // MARK: - PRIVATE HELPERS
    private func sendRequest(apiURL: URL, action: String, token: String, mac: String, extraParams: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        var query = [
            URLQueryItem(name: "type", value: "itv"), // usually itv for data
            URLQueryItem(name: "action", value: action),
            URLQueryItem(name: "mac", value: mac),
            URLQueryItem(name: "Authorization", value: "Bearer \(token)") // Some older portals read from query
        ]
        query.append(contentsOf: extraParams)
        components?.queryItems = query
        
        guard let url = components?.url else { throw URLError(.badURL) }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("mac=\(mac);", forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        
        return data
    }
    
    // Pseudo-random generation for "spoofing" if needed
    private func generateDeviceID(_ mac: String) -> String {
        // Just hash the mac or return random
        return String(mac.hashValue).filter { $0.isNumber }
    }
    
    private func generateDeviceID2(_ mac: String) -> String {
        return String(mac.reversed().hashValue).filter { $0.isNumber }
    }
    
    private func generateSignature(_ mac: String) -> String {
        // Real signature logic is proprietary/complex, often just empty or simple hash is accepted by loose portals
        return "" 
    }
}
