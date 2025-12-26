import Foundation

// MARK: - MODELS
enum ViewMode: String, CaseIterable, Sendable { case automatic = "Automatic", sidebar = "Sidebar", standard = "Standard" }
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
}
enum LoginType: String, CaseIterable, Identifiable, Sendable {
    case xtream = "Xtream Codes API"
    case m3u = "M3U Playlist / Stalker"
    case mac = "Mac Address / Portal"
    var id: String { rawValue }
}

enum SportType: String, CaseIterable, Identifiable, Sendable {
    case soccer = "Soccer", ucl = "Champions League", europa = "Europa League"
    case cbb = "NCAAB", cfb = "NCAAF", nfl = "NFL", nba = "NBA", wnba = "WNBA", nhl = "NHL", mlb = "MLB"
    case f1 = "Formula 1", ufc = "UFC", pga = "PGA Tour", tennis = "ATP Tennis", nascar = "NASCAR"
    var id: String { rawValue }
    var endpoint: String {
        switch self {
        case .nfl: return "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard"
        case .mlb: return "https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/scoreboard"
        case .nhl: return "https://site.api.espn.com/apis/site/v2/sports/hockey/nhl/scoreboard"
        case .nba: return "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard"
        case .wnba: return "https://site.api.espn.com/apis/site/v2/sports/basketball/wnba/scoreboard"
        case .cbb: return "https://site.api.espn.com/apis/site/v2/sports/basketball/mens-college-basketball/scoreboard"
        case .cfb: return "https://site.api.espn.com/apis/site/v2/sports/football/college-football/scoreboard"
        case .ucl: return "https://site.api.espn.com/apis/site/v2/sports/soccer/uefa.champions/scoreboard"
        case .europa: return "https://site.api.espn.com/apis/site/v2/sports/soccer/uefa.europa/scoreboard"
        case .soccer: return ""
        case .f1: return "https://site.api.espn.com/apis/site/v2/sports/racing/f1/scoreboard"
        case .ufc: return "https://site.api.espn.com/apis/site/v2/sports/mma/ufc/scoreboard"
        case .pga: return "https://site.api.espn.com/apis/site/v2/sports/golf/pga/scoreboard"
        case .tennis: return "https://site.api.espn.com/apis/site/v2/sports/tennis/atp/scoreboard"
        case .nascar: return "https://site.api.espn.com/apis/site/v2/sports/racing/nascar-premier/scoreboard"
        }
    }
}
