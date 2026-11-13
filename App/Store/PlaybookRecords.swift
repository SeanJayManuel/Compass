import Core
import Foundation
import SwiftData

/// A Playbook entry, stored as JSON beside its id like habits.
@Model
final class PlaybookEntryRecord {
    @Attribute(.unique) var id: UUID
    var entryData: Data
    var createdAt: Date

    init(_ entry: PlaybookEntry) {
        id = entry.id
        entryData = (try? JSONEncoder().encode(entry)) ?? Data()
        createdAt = .now
    }

    var entry: PlaybookEntry? { try? JSONDecoder().decode(PlaybookEntry.self, from: entryData) }
}

/// The sizes card. One row.
@Model
final class PlaybookSizesRecord {
    var sizesData: Data

    init(_ sizes: PlaybookSizes) {
        sizesData = (try? JSONEncoder().encode(sizes)) ?? Data()
    }

    var sizes: PlaybookSizes? { try? JSONDecoder().decode(PlaybookSizes.self, from: sizesData) }
}

extension CompassStore {
    func playbook() throws -> [PlaybookEntry] {
        try context.fetch(FetchDescriptor<PlaybookEntryRecord>(sortBy: [SortDescriptor(\.createdAt)])).compactMap(\.entry)
    }

    func save(_ entry: PlaybookEntry) throws {
        let id = entry.id
        var descriptor = FetchDescriptor<PlaybookEntryRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.entryData = (try? JSONEncoder().encode(entry)) ?? record.entryData
        } else {
            context.insert(PlaybookEntryRecord(entry))
        }
        try context.save()
    }

    func deletePlaybookEntry(_ id: UUID) throws {
        try context.delete(model: PlaybookEntryRecord.self, where: #Predicate { $0.id == id })
        try context.save()
    }

    func playbookSizes() throws -> PlaybookSizes {
        try context.fetch(FetchDescriptor<PlaybookSizesRecord>()).first?.sizes ?? PlaybookSizes()
    }

    func save(_ sizes: PlaybookSizes) throws {
        if let record = try context.fetch(FetchDescriptor<PlaybookSizesRecord>()).first {
            record.sizesData = (try? JSONEncoder().encode(sizes)) ?? record.sizesData
        } else {
            context.insert(PlaybookSizesRecord(sizes))
        }
        try context.save()
    }
}
