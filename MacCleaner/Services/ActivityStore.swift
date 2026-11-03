import Foundation
import Combine

@MainActor
final class ActivityStore: ObservableObject {
    static let maximumEntries = 500

    @Published private(set) var entries: [ActivityEntry] = []

    private let defaults: UserDefaults
    private let storageKey = "MacCleaner.activity.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([ActivityEntry].self, from: data) {
            entries = Array(saved.prefix(Self.maximumEntries))
        }
    }

    func record(title: String, files: Int, bytes: Int64, note: String, kind: ActivityKind = .other) {
        let entry = ActivityEntry(
            id: UUID(),
            date: .now,
            title: title,
            filesReviewed: files,
            bytesAffected: bytes,
            note: note,
            kind: kind
        )
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(Self.maximumEntries))
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
