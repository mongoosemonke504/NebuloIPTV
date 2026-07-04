import Foundation

/// Resolves a league display name to an ESPN-hosted logo URL. ESPN serves all
/// of these as PNGs on its global CDN — no API key required — so we can use
/// them as a free upgrade over the abbreviation-tile fallback.
///
/// Returns `nil` for unknown leagues so the UI falls back to the generated
/// abbreviation tile.
enum LeagueLogoURL {
    /// Mapping of league label / sport raw value → ESPN logo URL. The keys are
    /// the same strings produced by `ScoreViewModel.allKnownLeagues()`.
    private static let map: [String: String] = [
        // Top-level US sports leagues
        "NFL": "https://a.espncdn.com/i/leaguelogos/sports/500/nfl.png",
        "NBA": "https://a.espncdn.com/i/leaguelogos/sports/500/nba.png",
        "WNBA": "https://a.espncdn.com/i/leaguelogos/sports/500/wnba.png",
        "MLB": "https://a.espncdn.com/i/leaguelogos/sports/500/mlb.png",
        "NHL": "https://a.espncdn.com/i/leaguelogos/sports/500/nhl.png",
        "NCAAF": "https://a.espncdn.com/i/leaguelogos/sports/500/ncaa.png",
        "NCAAB": "https://a.espncdn.com/i/leaguelogos/sports/500/ncaa.png",
        "NCAA Hockey": "https://a.espncdn.com/i/leaguelogos/sports/500/ncaa.png",
        "NCAA Softball": "https://a.espncdn.com/i/leaguelogos/sports/500/ncaa.png",
        "NCAA M-Lacrosse": "https://a.espncdn.com/i/leaguelogos/sports/500/ncaa.png",
        "NCAA W-Lacrosse": "https://a.espncdn.com/i/leaguelogos/sports/500/ncaa.png",
        "NCAA M-Volleyball": "https://a.espncdn.com/i/leaguelogos/sports/500/ncaa.png",
        "NCAA W-Volleyball": "https://a.espncdn.com/i/leaguelogos/sports/500/ncaa.png",
        "Formula 1": "https://a.espncdn.com/i/leaguelogos/racing/500/f1.png",
        "MMA": "https://a.espncdn.com/i/leaguelogos/mma/500/ufc.png",

        // Domestic soccer leagues
        "Premier League": "https://a.espncdn.com/i/leaguelogos/soccer/500/23.png",
        "La Liga": "https://a.espncdn.com/i/leaguelogos/soccer/500/15.png",
        "Bundesliga": "https://a.espncdn.com/i/leaguelogos/soccer/500/10.png",
        "Serie A": "https://a.espncdn.com/i/leaguelogos/soccer/500/12.png",
        "Ligue 1": "https://a.espncdn.com/i/leaguelogos/soccer/500/9.png",
        "MLS": "https://a.espncdn.com/i/leaguelogos/soccer/500/19.png",
        "EFL Championship": "https://a.espncdn.com/i/leaguelogos/soccer/500/24.png",
        "Liga MX": "https://a.espncdn.com/i/leaguelogos/soccer/500/11.png",
        "Eredivisie": "https://a.espncdn.com/i/leaguelogos/soccer/500/14.png",
        "Primeira Liga": "https://a.espncdn.com/i/leaguelogos/soccer/500/13.png",
        "Scottish Premiership": "https://a.espncdn.com/i/leaguelogos/soccer/500/45.png",
        "Brasileirão": "https://a.espncdn.com/i/leaguelogos/soccer/500/35.png",
        "Argentine Primera": "https://a.espncdn.com/i/leaguelogos/soccer/500/16.png",

        // Domestic cups
        "FA Cup": "https://a.espncdn.com/i/leaguelogos/soccer/500/40.png",
        "Carabao Cup": "https://a.espncdn.com/i/leaguelogos/soccer/500/41.png",
        "Copa del Rey": "https://a.espncdn.com/i/leaguelogos/soccer/500/80.png",
        "DFB-Pokal": "https://a.espncdn.com/i/leaguelogos/soccer/500/2061.png",
        "Coppa Italia": "https://a.espncdn.com/i/leaguelogos/soccer/500/2192.png",
        "Coupe de France": "https://a.espncdn.com/i/leaguelogos/soccer/500/182.png",
        "US Open Cup": "https://a.espncdn.com/i/leaguelogos/soccer/500/183.png",

        // Continental
        "Champions League": "https://a.espncdn.com/i/leaguelogos/soccer/500/2.png",
        "Europa League": "https://a.espncdn.com/i/leaguelogos/soccer/500/2310.png",
        "Conference League": "https://a.espncdn.com/i/leaguelogos/soccer/500/2916.png",
        "Libertadores": "https://a.espncdn.com/i/leaguelogos/soccer/500/2900.png",
        "Concacaf Champions": "https://a.espncdn.com/i/leaguelogos/soccer/500/2904.png",
        "AFC Champions": "https://a.espncdn.com/i/leaguelogos/soccer/500/2903.png",

        // International
        "World Cup": "https://a.espncdn.com/i/leaguelogos/soccer/500/164.png",
        "Euro": "https://a.espncdn.com/i/leaguelogos/soccer/500/2189.png",
        "Copa América": "https://a.espncdn.com/i/leaguelogos/soccer/500/2105.png",
        "Gold Cup": "https://a.espncdn.com/i/leaguelogos/soccer/500/2151.png",
        "Nations League": "https://a.espncdn.com/i/leaguelogos/soccer/500/2522.png",
        "Friendlies": "https://a.espncdn.com/i/leaguelogos/soccer/500/4400.png",
        "Club World Cup": "https://a.espncdn.com/i/leaguelogos/soccer/500/2114.png",

        // Bucket labels (when a league favorite is keyed by just the SportType)
        "Soccer Leagues": "https://a.espncdn.com/i/leaguelogos/sports/500/soccer.png",
        "Domestic Soccer Cups": "https://a.espncdn.com/i/leaguelogos/sports/500/soccer.png",
        "Continental Soccer": "https://a.espncdn.com/i/leaguelogos/sports/500/soccer.png",
        "International Soccer": "https://a.espncdn.com/i/leaguelogos/sports/500/soccer.png"
    ]

    /// Returns the best ESPN CDN logo URL for a league, preferring the
    /// `leagueLabel` (e.g. "Premier League") over the broader sport bucket.
    static func url(sport: SportType, leagueLabel: String?) -> String? {
        if let label = leagueLabel, let hit = map[label] { return hit }
        return map[sport.rawValue]
    }
}
