import Foundation

/// The season calendar for a series that runs one event at a time.
///
/// Formula 1 and golf have no table and no fixture list, so the league page has
/// nothing to fill its usual tabs with. What they do have is a calendar — 24
/// Grands Prix, 48 tour stops — and ESPN ships it inside the scoreboard
/// response, alongside the single event that happens to be current.
nonisolated enum SeriesCalendarService {

    struct Entry: Identifiable, Sendable {
        /// ESPN event id, so a row can open that event's game card.
        let id: String
        /// "Qatar Airways Australian Grand Prix", "The Sentry".
        let label: String
        let start: Date?
        let end: Date?

        /// Finished once the closing day has passed.
        func isPast(now: Date = Date()) -> Bool {
            guard let end else { return false }
            return end < now
        }

        /// Running right now.
        func isCurrent(now: Date = Date()) -> Bool {
            guard let start, let end else { return false }
            return start <= now && now <= end
        }
    }

    static func fetch(sport: SportType) async -> [Entry] {
        guard let url = URL(string: sport.endpoint),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let res = try? JSONDecoder().decode(Response.self, from: data),
              let calendar = res.leagues?.first?.calendar
        else { return [] }

        return calendar.compactMap { item in
            guard let label = item.label, !label.isEmpty else { return nil }
            // Golf's entries carry an id outright; racing's only reference the
            // event, so it comes off the tail of the `$ref` URL.
            let id = item.id ?? item.event?.ref.flatMap(eventID(fromRef:))
            guard let id else { return nil }
            return Entry(
                id: id,
                label: label,
                start: item.startDate.flatMap(ESPNEvent.parseDate),
                end: item.endDate.flatMap(ESPNEvent.parseDate)
            )
        }
    }

    /// ".../events/600057427?lang=en&region=us" → "600057427"
    private static func eventID(fromRef ref: String) -> String? {
        guard let range = ref.range(of: "/events/") else { return nil }
        let tail = ref[range.upperBound...]
        let id = tail.prefix { $0.isNumber }
        return id.isEmpty ? nil : String(id)
    }

    private struct Response: Decodable {
        struct League: Decodable { let calendar: [Item]? }
        struct Item: Decodable {
            let id: String?
            let label: String?
            let startDate: String?
            let endDate: String?
            let event: Ref?
        }
        struct Ref: Decodable {
            let ref: String?
            enum CodingKeys: String, CodingKey { case ref = "$ref" }
        }
        let leagues: [League]?
    }
}
