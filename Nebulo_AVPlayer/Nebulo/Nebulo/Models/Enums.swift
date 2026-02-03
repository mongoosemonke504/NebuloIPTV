import Foundation

enum ViewMode: String, CaseIterable, Sendable { case automatic = "Automatic", sidebar = "Sidebar", standard = "Standard" }
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
}
enum LoginType: String, CaseIterable, Identifiable, Sendable, Codable {
    case xtream = "Xtream Codes API"
    case m3u = "M3U Playlist"
    var id: String { rawValue }
}

enum SportType: String, CaseIterable, Identifiable, Sendable {
    case pinned = "Pinned"
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
        case .pinned: return ""
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
        case .soccerLeagues, .domesticCups, .continental, .international: return "" 
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
    case unknown = "Unknown"
    
    var id: String { rawValue }
    
    var scoreWeight: Int {
        switch self {
        case .best: return 0 
        case .fourK: return 400
        case .fhd: return 300
        case .hd: return 200
        case .sd: return 100
        case .unknown: return 50
        }
    }
}

enum LanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case any = "Any"
    case english = "English"
    case es = "Spanish"
    case fr = "French"
    case de = "German"
    case it = "Italian"
    case pt = "Portuguese"
    case ar = "Arabic"
    case ru = "Russian"
    case nl = "Dutch"
    case tr = "Turkish"
    case pl = "Polish"
    
    var id: String { rawValue }
    
    nonisolated var searchTokens: [String] {
        switch self {
        case .any: return []
        case .english: return ["us", "usa", "america", "uk", "gbr", "britain", "ca", "can", "canada", "en", "eng", "english"]
        case .es: return ["es", "esp", "mx", "mex", "latino"]
        case .fr: return ["fr", "fra", "france"]
        case .de: return ["de", "deu", "ger", "germany"]
        case .it: return ["it", "ita", "italy"]
        case .pt: return ["pt", "por", "bra", "brazil", "portugal", "br"]
        case .ar: return ["ar", "ara", "arabic", "ksa", "arab"]
        case .ru: return ["ru", "rus", "russia"]
        case .nl: return ["nl", "nld", "ned", "dutch", "ziggo"]
        case .tr: return ["tr", "tur", "turkey"]
        case .pl: return ["pl", "pol", "polska", "poland"]
        }
    }
    
    nonisolated var languageIndicators: [String] {
        switch self {
        case .any: return []
        case .english: return ["the", "with", "coverage", "from", "tonight", "watch"]
        case .es: return ["con", "los", "las", "del", "por", "vivo", "partido", "es", "al"]
        case .fr: return ["et", "du", "de", "d'", "des", "pour", "dans", "direct", "est", "au", "les", "sur", "match"]
        case .de: return ["der", "die", "das", "und", "mit", "dem", "aus", "von", "ist", "auf", "im", "ein", "eine"]
        case .it: return ["il", "lo", "gli", "di", "con", "diretta", "in", "su", "per"]
        case .pt: return ["ao", "vivo", "jogo", "da", "do", "na", "no", "futebol"]
        case .ar: return ["al", "bin", "ben", "abu"]
        case .ru: return ["tv"] 
        case .nl: return ["het", "een", "van", "op"]
        case .tr: return ["ve", "bir", "ile", "canli", "mac"]
        case .pl: return ["na", "zywo", "mecz"]
        }
    }
}

