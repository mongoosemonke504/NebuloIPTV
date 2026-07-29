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
    case tennis = "Tennis"
    case golf = "Golf"
    case collegeHockey = "NCAA Hockey"
    case softball = "NCAA Softball"
    case mLacrosse = "NCAA M-Lacrosse"
    case wLacrosse = "NCAA W-Lacrosse"
    case mVolleyball = "NCAA M-Volleyball"
    case wVolleyball = "NCAA W-Volleyball"
    case mma = "MMA"

    /// Sports pulled from the hub's chip row. The cases stay (saved
    /// preferences, recordings and old orders still decode), they just
    /// never surface as tabs.
    nonisolated static let retired: Set<SportType> = [
        .collegeHockey, .softball, .mLacrosse, .wLacrosse, .mVolleyball, .wVolleyball
    ]

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
        // Tennis aggregates the ATP + WTA scoreboards with a custom fetch
        // (see ScoreViewModel.fetchTennisInternal), so no single endpoint.
        case .tennis: return ""
        case .f1: return "https://site.api.espn.com/apis/site/v2/sports/racing/f1/scoreboard"
        // One event with the whole field inside it, same shape as a race
        // weekend rather than a fixture.
        case .golf: return "https://site.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard"
        case .mma: return "https://site.api.espn.com/apis/site/v2/sports/mma/ufc/scoreboard"
        }
    }

    /// True for the four aggregate soccer tabs. They share one team-id pool
    /// (the same club plays in its league, a domestic cup, and a continental
    /// competition), so favorites and matching treat them as one sport.
    nonisolated var isSoccer: Bool {
        self == .soccerLeagues || self == .domesticCups || self == .continental || self == .international
    }

    /// The `<sport>/<league>` path segment of this sport's ESPN site API
    /// (e.g. "football/nfl"), derived from the scoreboard endpoint so any
    /// sport added with an endpoint automatically gets team-list support.
    /// Nil for aggregate tabs (Pinned, the soccer buckets).
    nonisolated var apiPath: String? {
        guard let start = endpoint.range(of: "/sports/"),
              let end = endpoint.range(of: "/scoreboard") else { return nil }
        return String(endpoint[start.upperBound..<end.lowerBound])
    }
}

/// A single soccer competition ESPN exposes: the API league code plus the
/// human-readable name shown throughout the app.
nonisolated struct SoccerCompetition: Hashable, Sendable {
    let code: String
    let name: String
}

extension SportType {
    /// Single source of truth for every soccer competition the app covers.
    /// The scoreboard fetch, the team catalog, and the favorites pickers all
    /// read from this list — add a competition here and every feature picks
    /// it up automatically. Group order matters: when a team appears in
    /// several competitions (a club in its league AND a domestic cup, a
    /// national side in the World Cup AND friendlies), the catalog labels it
    /// with the first competition that lists it.
    nonisolated static let soccerCompetitionGroups: [(sport: SportType, competitions: [SoccerCompetition])] = [
        (.soccerLeagues, [
            SoccerCompetition(code: "eng.1", name: "Premier League"),
            SoccerCompetition(code: "esp.1", name: "La Liga"),
            SoccerCompetition(code: "ger.1", name: "Bundesliga"),
            SoccerCompetition(code: "ita.1", name: "Serie A"),
            SoccerCompetition(code: "fra.1", name: "Ligue 1"),
            SoccerCompetition(code: "usa.1", name: "MLS"),
            SoccerCompetition(code: "eng.2", name: "EFL Championship"),
            SoccerCompetition(code: "mex.1", name: "Liga MX"),
            SoccerCompetition(code: "ned.1", name: "Eredivisie"),
            SoccerCompetition(code: "por.1", name: "Primeira Liga"),
            SoccerCompetition(code: "sco.1", name: "Scottish Premiership"),
            SoccerCompetition(code: "bra.1", name: "Brasileirão"),
            SoccerCompetition(code: "arg.1", name: "Argentine Primera")
        ]),
        (.domesticCups, [
            SoccerCompetition(code: "eng.fa", name: "FA Cup"),
            SoccerCompetition(code: "eng.league_cup", name: "Carabao Cup"),
            SoccerCompetition(code: "esp.copa_del_rey", name: "Copa del Rey"),
            SoccerCompetition(code: "ger.dfb_pokal", name: "DFB-Pokal"),
            SoccerCompetition(code: "ita.coppa_italia", name: "Coppa Italia"),
            SoccerCompetition(code: "fra.coupe_de_france", name: "Coupe de France"),
            SoccerCompetition(code: "usa.open", name: "US Open Cup")
        ]),
        (.continental, [
            SoccerCompetition(code: "uefa.champions", name: "Champions League"),
            SoccerCompetition(code: "uefa.europa", name: "Europa League"),
            SoccerCompetition(code: "uefa.europa.conf", name: "Conference League"),
            SoccerCompetition(code: "conmebol.libertadores", name: "Libertadores"),
            SoccerCompetition(code: "concacaf.champions", name: "Concacaf Champions"),
            SoccerCompetition(code: "afc.champions", name: "AFC Champions")
        ]),
        (.international, [
            SoccerCompetition(code: "fifa.world", name: "World Cup"),
            SoccerCompetition(code: "uefa.euro", name: "Euro"),
            SoccerCompetition(code: "conmebol.america", name: "Copa América"),
            SoccerCompetition(code: "concacaf.gold", name: "Gold Cup"),
            SoccerCompetition(code: "uefa.nations", name: "Nations League"),
            SoccerCompetition(code: "fifa.friendly", name: "Friendlies"),
            SoccerCompetition(code: "fifa.cwc", name: "Club World Cup")
        ])
    ]

    /// The competitions bundled under one soccer tab (empty for non-soccer).
    nonisolated static func competitions(for sport: SportType) -> [SoccerCompetition] {
        soccerCompetitionGroups.first(where: { $0.sport == sport })?.competitions ?? []
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

