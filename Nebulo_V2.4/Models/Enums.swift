import Foundation

// MARK: - MODELS
enum ViewMode: String, CaseIterable, Sendable { case automatic = "Automatic", sidebar = "Sidebar", standard = "Standard" }
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
}
enum LoginType: String, CaseIterable, Identifiable, Sendable, Codable {
    case xtream = "Xtream Codes API"
    case m3u = "M3U Playlist / Stalker"
    case mac = "Mac Address / Portal"
    var id: String { rawValue }
}

enum SportType: String, CaseIterable, Identifiable, Sendable {
    case soccerLeagues = "Soccer Leagues"
    case domesticCups = "Domestic Soccer Cups"
    case continental = "Continental Soccer"
    case international = "International Soccer"
    case cbb = "NCAAB", cfb = "NCAAF", nfl = "NFL", nba = "NBA", wnba = "WNBA", nhl = "NHL", mlb = "MLB"
    case f1 = "Formula 1"
    case collegeHockey = "NCAA Hockey"
    case softball = "NCAA Softball"
    case mLacrosse = "NCAA M-Lacrosse"
    case wLacrosse = "NCAA W-Lacrosse"
    case mVolleyball = "NCAA M-Volleyball"
    case wVolleyball = "NCAA W-Volleyball"
    case mma = "MMA"
    
    var id: String { rawValue }
    nonisolated var endpoint: String {
        switch self {
        case .nfl: return "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard"
        case .mlb: return "https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/scoreboard"
        case .nhl: return "https://site.api.espn.com/apis/site/v2/sports/hockey/nhl/scoreboard"
        case .nba: return "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard"
        case .wnba: return "https://site.api.espn.com/apis/site/v2/sports/basketball/wnba/scoreboard"
        case .cbb: return "https://site.api.espn.com/apis/site/v2/sports/basketball/mens-college-basketball/scoreboard"
        case .cfb: return "https://site.api.espn.com/apis/site/v2/sports/football/college-football/scoreboard"
        case .collegeHockey: return "https://site.api.espn.com/apis/site/v2/sports/hockey/mens-college-hockey/scoreboard"
        case .softball: return "https://site.api.espn.com/apis/site/v2/sports/baseball/college-softball/scoreboard"
        case .mLacrosse: return "https://site.api.espn.com/apis/site/v2/sports/lacrosse/mens-college-lacrosse/scoreboard"
        case .wLacrosse: return "https://site.api.espn.com/apis/site/v2/sports/lacrosse/womens-college-lacrosse/scoreboard"
        case .mVolleyball: return "https://site.api.espn.com/apis/site/v2/sports/volleyball/mens-college-volleyball/scoreboard"
        case .wVolleyball: return "https://site.api.espn.com/apis/site/v2/sports/volleyball/womens-college-volleyball/scoreboard"
        case .soccerLeagues, .domesticCups, .continental, .international: return "" // Handled internally
        case .f1: return "https://site.api.espn.com/apis/site/v2/sports/racing/f1/scoreboard"
        case .mma: return "https://site.api.espn.com/apis/site/v2/sports/mma/ufc/scoreboard"
        }
    }
}

enum StreamQuality: String, CaseIterable, Identifiable, Sendable {
    case best = "Best Available"
    case fourK = "4K / UHD"
    case fhd = "FHD (1080p)"
    case hd = "HD (720p)"
    case sd = "SD"
    
    var id: String { rawValue }
    
    var scoreWeight: Int {
        switch self {
        case .best: return 0 // Dynamic
        case .fourK: return 400
        case .fhd: return 300
        case .hd: return 200
        case .sd: return 100
        }
    }
}

enum LanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case any = "Any"
    case us = "English (US)"
    case uk = "English (UK)"
    case ca = "English (Canada)"
    case es = "Spanish"
    case fr = "French"
    case de = "German"
    case it = "Italian"
    
    var id: String { rawValue }
    
    nonisolated var searchTokens: [String] {
        switch self {
        case .any: return []
        case .us: return ["us", "usa", "america"]
        case .uk: return ["uk", "gbr", "britain"]
        case .ca: return ["ca", "can", "canada"]
        case .es: return ["es", "esp", "mx", "mex", "latino"]
        case .fr: return ["fr", "fra", "france"]
        case .de: return ["de", "deu", "ger", "germany"]
        case .it: return ["it", "ita", "italy"]
        }
    }
    
    nonisolated var languageIndicators: [String] {
        switch self {
        case .any: return []
        case .us, .uk, .ca: return ["the", "and", "with", "live", "coverage", "from", "tonight", "watch", "is", "on", "at", "for"]
        case .es: return ["el", "la", "en", "y", "con", "los", "las", "del", "por", "vivo", "partido", "de", "es", "un", "una", "al"]
        case .fr: return ["le", "la", "et", "du", "de", "d'", "des", "pour", "une", "dans", "direct", "est", "un", "au", "les", "sur", "match"]
        case .de: return ["der", "die", "das", "und", "mit", "dem", "aus", "von", "live", "ist", "auf", "im", "ein", "eine"]
        case .it: return ["il", "lo", "la", "i", "gli", "le", "di", "e", "con", "diretta", "in", "su", "per", "un", "una"]
        }
    }
}

