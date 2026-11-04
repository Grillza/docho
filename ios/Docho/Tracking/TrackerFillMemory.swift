import Foundation

/// What the tracker fill remembers about each series: the status it last gave, and what the user
/// decided against. Shared with other devices and Dōchō Server as Dōchō Sync's "fill" records, so a
/// decision made anywhere holds everywhere; the newest one wins. Android's `TrackerFillMemory`.
@MainActor
final class TrackerFillMemory {
    struct Memory: Codable, Equatable, Sendable {
        var status: Int?
        var ignored: [String: [String]] = [:]

        var json: SyncJSON {
            var fields: [String: SyncJSON] = [
                "ignored": .object(ignored.filter { !$0.value.isEmpty }.mapValues { .array($0.sorted().map(SyncJSON.string)) }),
            ]
            if let status { fields["status"] = .int(Int64(status)) }
            return .object(fields)
        }

        init(status: Int? = nil, ignored: [String: [String]] = [:]) {
            self.status = status
            self.ignored = ignored
        }

        init(json: SyncJSON) {
            status = json["status"]?.int.map { Int($0) }
            if case .object(let fields) = json["ignored"] {
                ignored = fields.mapValues { $0.strings }
            }
        }
    }

    private let defaults: UserDefaults
    /// By "source|url", as Dōchō Sync keys series.
    private(set) var all: [String: Memory]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        all = defaults.data(forKey: "tracker_fill_memory").flatMap { try? JSONDecoder().decode([String: Memory].self, from: $0) } ?? [:]
    }

    func get(_ key: String) -> Memory? { all[key] }

    func put(_ key: String, _ memory: Memory?) {
        all[key] = memory
        save()
    }

    func remember(_ key: String, filledStatus: Int?, ignore: [String: [String]]) {
        var memory = all[key] ?? Memory()
        if let filledStatus { memory.status = filledStatus }
        for (field, values) in ignore {
            var merged = memory.ignored[field] ?? []
            for value in values where !merged.contains(value) { merged.append(value) }
            memory.ignored[field] = merged
        }
        put(key, memory)
    }

    /// Asks again about everything that was kept or skipped.
    func forgetChoices() {
        all = all.mapValues { Memory(status: $0.status) }
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(all), forKey: "tracker_fill_memory")
    }
}
