import Core
import Foundation
import SwiftData

/// A note for Claude, stored as JSON beside its id like Playbook entries.
@Model
final class NoteRecord {
    @Attribute(.unique) var id: UUID
    var noteData: Data

    init(_ note: Note) {
        id = note.id
        noteData = (try? JSONEncoder().encode(note)) ?? Data()
    }

    var note: Note? { try? JSONDecoder().decode(Note.self, from: noteData) }
}

extension CompassStore {
    func notes() throws -> [Note] {
        try context.fetch(FetchDescriptor<NoteRecord>()).compactMap(\.note)
    }

    func save(_ note: Note) throws {
        let id = note.id
        var descriptor = FetchDescriptor<NoteRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.noteData = (try? JSONEncoder().encode(note)) ?? record.noteData
        } else {
            context.insert(NoteRecord(note))
        }
        try context.save()
    }

    func deleteNote(_ id: UUID) throws {
        try context.delete(model: NoteRecord.self, where: #Predicate { $0.id == id })
        try context.save()
    }
}
