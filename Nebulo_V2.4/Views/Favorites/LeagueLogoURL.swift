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
    /// Every URL below was taken verbatim from the `leagues[].logos[].href`
    /// field of the corresponding ESPN scoreboard response (2026-07) — the
    /// previous hand-guessed ids returned 404s, which rendered blank tiles.
    private static let map: [String: String] = [
        // Top-level US sports leagues
        "NFL": "https://a.espncdn.com/i/teamlogos/leagues/500/nfl.png",
        "NBA": "https://a.espncdn.com/i/teamlogos/leagues/500/nba.png",
        "WNBA": "https://a.espncdn.com/i/teamlogos/leagues/500/wnba.png",
        "MLB": "https://a.espncdn.com/i/teamlogos/leagues/500/mlb.png",
        "NHL": "https://a.espncdn.com/i/teamlogos/leagues/500/nhl.png",
        "NCAAF": "https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-football-college.png",
        "NCAAB": "https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-basketball.png",
        "NCAA Hockey": "https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-hockey.png",
        "NCAA Softball": "https://a.espncdn.com/i/espn/misc_logos/500/ncaa_womens_softball.png",
        "NCAA M-Lacrosse": "https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-lacrosse.png",
        "NCAA W-Lacrosse": "https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-lacrosse.png",
        "NCAA M-Volleyball": "https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/sports-volleyball-solid.png",
        "NCAA W-Volleyball": "https://a.espncdn.com/combiner/i?img=/redesign/assets/img/icons/sports-volleyball-solid.png",
        "Formula 1": "https://a.espncdn.com/combiner/i?img=/i/teamlogos/leagues/500/f1.png",
        // Slug is "pgatour" — "pga" 404s.
        "Golf": "https://a.espncdn.com/combiner/i?img=/i/teamlogos/leagues/500/pgatour.png",
        "MMA": "https://a.espncdn.com/i/teamlogos/leagues/500/ufc.png",

        // Domestic soccer leagues
        "Premier League": "https://a.espncdn.com/i/leaguelogos/soccer/500/23.png",
        "La Liga": "https://a.espncdn.com/i/leaguelogos/soccer/500/15.png",
        "Bundesliga": "https://a.espncdn.com/i/leaguelogos/soccer/500/10.png",
        "Serie A": "https://a.espncdn.com/i/leaguelogos/soccer/500/12.png",
        "Ligue 1": "https://a.espncdn.com/i/leaguelogos/soccer/500/9.png",
        "MLS": "https://a.espncdn.com/i/leaguelogos/soccer/500/19.png",
        "EFL Championship": "https://a.espncdn.com/i/leaguelogos/soccer/500/24.png",
        "Liga MX": "https://a.espncdn.com/i/leaguelogos/soccer/500/22.png",
        "Eredivisie": "https://a.espncdn.com/i/leaguelogos/soccer/500/11.png",
        "Primeira Liga": "https://a.espncdn.com/i/leaguelogos/soccer/500/14.png",
        "Scottish Premiership": "https://a.espncdn.com/i/leaguelogos/soccer/500/45.png",
        "Brasileirão": "https://a.espncdn.com/i/leaguelogos/soccer/500/85.png",
        "Argentine Primera": "https://a.espncdn.com/i/leaguelogos/soccer/500/1.png",

        // Domestic cups
        "FA Cup": "https://a.espncdn.com/i/leaguelogos/soccer/500/40.png",
        "Carabao Cup": "https://a.espncdn.com/i/leaguelogos/soccer/500/41.png",
        "Copa del Rey": "https://a.espncdn.com/i/leaguelogos/soccer/500/80.png",
        "DFB-Pokal": "https://a.espncdn.com/i/leaguelogos/soccer/500/2061.png",
        "Coppa Italia": "https://a.espncdn.com/i/leaguelogos/soccer/500/2192.png",
        "Coupe de France": "https://a.espncdn.com/i/leaguelogos/soccer/500/182.png",
        "US Open Cup": "https://a.espncdn.com/i/leaguelogos/soccer/500/69.png",

        // Continental
        "Champions League": "https://a.espncdn.com/i/leaguelogos/soccer/500/2.png",
        "Europa League": "https://a.espncdn.com/i/leaguelogos/soccer/500/2310.png",
        "Conference League": "https://a.espncdn.com/i/leaguelogos/soccer/500/20296.png",
        "Libertadores": "https://a.espncdn.com/i/leaguelogos/soccer/500/58.png",
        "Concacaf Champions": "https://a.espncdn.com/i/leaguelogos/soccer/500/2298.png",
        "AFC Champions": "https://a.espncdn.com/i/leaguelogos/soccer/500/2200.png",

        // International
        "World Cup": "https://a.espncdn.com/i/leaguelogos/soccer/500/4.png",
        "Euro": "https://a.espncdn.com/i/leaguelogos/soccer/500/74.png",
        "Copa América": "https://a.espncdn.com/i/leaguelogos/soccer/500/83.png",
        "Gold Cup": "https://a.espncdn.com/i/leaguelogos/soccer/500/59.png",
        "Nations League": "https://a.espncdn.com/i/leaguelogos/soccer/500/2395.png",
        "Friendlies": "https://a.espncdn.com/i/leaguelogos/soccer/500/53.png",
        "Club World Cup": "https://a.espncdn.com/i/leaguelogos/soccer/500/1932.png",

        // Bucket labels (when a league favorite is keyed by just the SportType)
        "Soccer Leagues": "https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-soccer.png",
        "Domestic Soccer Cups": "https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-soccer.png",
        "Continental Soccer": "https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-soccer.png",
        "International Soccer": "https://a.espncdn.com/redesign/assets/img/icons/ESPN-icon-soccer.png"
    ]

    /// Returns the best ESPN CDN logo URL for a league, preferring the
    /// `leagueLabel` (e.g. "Premier League") over the broader sport bucket.
    static func url(sport: SportType, leagueLabel: String?) -> String? {
        if let label = leagueLabel, let hit = map[label] { return hit }
        return map[sport.rawValue]
    }
}
