import Core
import Foundation

/// Notes for Claude (seam 31+): their standing rules and the reasons behind
/// them, read at the start of planning chats since chats through Compass
/// can't keep memories. Added, edited or deleted with the screen's checks
/// (`ClaudeRules`), every change logged with undo.
extension ClaudeTools {
    var notesReadTool: ClaudeTool {
        tool(
            "notes",
            "Their notes for Claude: standing rules and the reasons behind them (why they keep a cash buffer, what their career is aiming at), grouped by topic (Money, Goals, Career, Life, then their own), newest first. Read them at the start of any planning or advice chat. They hold reasons, not figures: get balances, pay and budget amounts from their own tools.",
            ["topic": ["type": "string", "description": "Only this topic, like Money. Default all."]], run: { args in try self.notes(args) })
    }

    var noteChangeTools: [ClaudeTool] {
        func text(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
        let body = text(
            "The rule and its reason, in plain words, at most \(ClaudeRules.longestNote) characters. Never figures other tools give (balances, pay, budget amounts, goal targets): say where they live instead."
        )
        return [
            tool(
                "add_note",
                "Keep a rule or reason they've settled on, so later chats know it. One idea a note; edit a note on the same thing rather than adding another.",
                ["topic": text("Money, Goals, Career, Life, or another."), "title": text("A short name, like \"Cash buffer\"."), "body": body],
                required: ["topic", "title", "body"], changes: true, destructive: false, run: { args in try self.addNote(args) }),
            tool(
                "edit_note", "Change a note. Only the fields given change.",
                [
                    "note": text("The note's id or title (from notes)."), "topic": text("Move it to this topic."),
                    "title": text("A new title."), "body": body
                ],
                required: ["note"], changes: true, run: { args in try self.editNote(args) }),
            tool(
                "delete_note", "Delete a note that no longer holds. Undo brings it back.",
                ["note": text("The note's id (from notes).")], required: ["note"], changes: true, run: { args in try self.deleteNote(args) })
        ]
    }

    func notes(_ args: Arguments) throws -> [String: Any] {
        let groups = Notes.grouped(try store.notes(), topic: args.string("topic"))
        return [
            "topics": groups.map { group -> [String: Any] in
                [
                    "topic": group.topic,
                    "notes": group.notes.map { note -> [String: Any] in
                        ["id": note.id.uuidString, "title": note.title, "body": note.body, "updatedAt": isoTime(note.updatedAt)]
                    }
                ]
            }
        ]
    }

    /// Takes back a note change, for `undo`; other changes are left to it.
    func undoNote(_ change: ClaudeChange) throws {
        let notes = try store.notes()
        switch change {
        case .noteAdded(let created):
            guard let current = notes.first(where: { $0.id == created.id }) else { throw Problem("That note is gone already.") }
            guard ClaudeRules.canUndoNewEntry(current: current, created: created) else { throw Self.changedSince }
            try store.deleteNote(created.id)
        case .noteEdited(let before, let after):
            guard let current = notes.first(where: { $0.id == after.id }) else { throw Problem("That note is gone.") }
            guard let restored = ClaudeRules.restore(current: current, before: before, after: after) else { throw Self.changedSince }
            try store.save(restored)
        case .noteDeleted(let deleted):
            guard ClaudeRules.canRestoreDeleted(deleted, among: notes) else {
                throw Problem("There's a note called \(deleted.title) again, so undo would make two. Edit that one instead.")
            }
            try store.save(deleted)
        default:
            return
        }
    }

    // MARK: - Changes

    private func addNote(_ args: Arguments) throws -> [String: Any] {
        let note = try ClaudeRules.newNote(
            topic: try args.required("topic"), title: try args.required("title"),
            body: try args.required("body"), among: try store.notes(), now: .now)
        try store.save(note)
        let summary = "Added the note “\(note.title)” to \(note.topic)"
        try log("add_note", summary, .noteAdded(note))
        return ["added": summary, "note": note.id.uuidString]
    }

    private func editNote(_ args: Arguments) throws -> [String: Any] {
        let notes = try store.notes()
        let before = try ClaudeRules.note(try args.required("note"), in: notes)
        let after = try ClaudeRules.editNote(
            before, topic: args.string("topic"), title: args.string("title"), body: args.string("body"),
            among: notes, now: .now)
        try store.save(after)
        let summary = "Edited the note “\(before.title)”"
        try log("edit_note", summary, .noteEdited(before: before, after: after))
        return ["changed": summary, "note": after.id.uuidString]
    }

    private func deleteNote(_ args: Arguments) throws -> [String: Any] {
        let wanted = try args.required("note")
        guard let note = try store.notes().first(where: { $0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame }) else {
            throw Problem("No note with id \(wanted); the notes tool lists them with ids.")
        }
        try store.deleteNote(note.id)
        let summary = "Deleted the note “\(note.title)”"
        try log("delete_note", summary, .noteDeleted(note))
        return ["deleted": summary, "note": note.id.uuidString]
    }
}
