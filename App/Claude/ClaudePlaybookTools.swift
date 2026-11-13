import Core
import Foundation

/// The Playbook for Claude (seam 31+): reading it, and adding to, editing
/// or deleting entries and sizes. The rules are `ClaudeRules`, in Core,
/// the same checks the editor makes, and every change is logged with undo.
extension ClaudeTools {
    var playbookReadTool: ClaudeTool {
        tool(
            "playbook",
            "Their Playbook: what works for them. Sizes they wear, and entries by area (Clothes, Hair, Grooming, Skin, Teeth, Fitness or their own): picks (what exactly, where from, size), routines (steps, each on weekdays or every day) and notes, some repeating every so many days. Plus today: routines' steps for today and repeats due within two days.",
            run: { _ in try self.playbook() })
    }

    var playbookChangeTools: [ClaudeTool] {
        func text(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
        let steps: [String: Any] = [
            "type": "array", "description": "For a routine, in order. Replaces all its steps.",
            "items": [
                "type": "object",
                "properties": [
                    "text": text("The step, like \"Push: bench, overhead press, dips\"."),
                    "days": [
                        "type": "array", "items": ["type": "string", "enum": Self.weekdayNames],
                        "description": "The weekdays it's on; leave out for every day."
                    ]
                ], "required": ["text"]
            ]
        ]
        let fields: [String: Any] = [
            "area": text("Clothes, Hair, Grooming, Skin, Teeth, Fitness, or a new one."),
            "kind": ["type": "string", "enum": ["pick", "routine", "note"], "description": "A thing they buy, steps they follow, or something to remember."],
            "title": text("Its name, like \"Plain tee\" or \"Workout split\"."),
            "detail": text("For a pick: what exactly, like \"Uniqlo Supima Cotton crew, white\"."),
            "source": text("For a pick: where it's from."), "size": text("For a pick: their size in it."),
            "notes": text("What works, what to avoid."), "steps": steps,
            "repeat_every_days": ["type": "integer", "description": "1 to 365, for something done every so often, like cutting nails. 0 to stop repeating."]
        ]
        return [
            tool(
                "add_playbook_entry", "Add to their Playbook: a pick, routine or note in an area.",
                fields, required: ["area", "title"], changes: true, destructive: false, run: { args in try self.addEntry(args) }),
            tool(
                "edit_playbook_entry", "Change a Playbook entry. Only the fields given change; steps replace all of a routine's steps.",
                fields.merging(["entry": text("The entry's title or id (from playbook).")]) { first, _ in first },
                required: ["entry"], changes: true, run: { args in try self.editEntry(args) }),
            tool(
                "done_playbook_entry", "Record that they did a repeating Playbook entry (cut their nails, got a haircut), so its next due day moves on.",
                ["entry": text("The entry's title or id (from playbook)."), "date": text("YYYY-MM-DD. Default today.")],
                required: ["entry"], changes: true, destructive: false, run: { args in try self.doneEntry(args) }),
            tool(
                "set_size", "Set one of their sizes, like Suit 38S, on the line with that label, or add a line.",
                ["label": text("What it's for, like \"Suit\" or \"Jeans\"."), "value": text("The size, like \"38S\" or \"31 × 32\".")],
                required: ["label", "value"], changes: true, run: { args in try self.setSize(args) }),
            tool(
                "delete_playbook_entry", "Delete a Playbook entry. Undo brings it back whole.",
                ["entry": text("The entry's title or id (from playbook).")], required: ["entry"], changes: true, run: { args in try self.deleteEntry(args) }),
            tool(
                "remove_size", "Remove the line with this label from their sizes.",
                ["label": text("What it's for, like \"Suit\".")], required: ["label"], changes: true, run: { args in try self.removeSize(args) })
        ]
    }

    func playbook() throws -> [String: Any] {
        let entries = try store.playbook()
        let line = Playbook.today(entries, today: today)
        let sizes = try store.playbookSizes()
        var answer: [String: Any] = [
            "today": iso(today),
            "sizes": sizes.rows.map { ["label": $0.label, "value": $0.value] },
            "entries": entries.map(entryRow),
            "todayLine": [
                "routines": line.routines.map { routine -> [String: Any] in
                    [
                        "entry": routine.entry.title, "stepsToday": routine.day.steps.map(\.text),
                        "next": routine.day.next.map { ["step": $0.step.text, "on": iso($0.day)] }
                    ]
                },
                "due": line.due.map { ["entry": $0.entry.title, "on": iso($0.day), "overdue": $0.day < today] }
            ]
        ]
        if !sizes.note.isEmpty { answer["sizesNote"] = sizes.note }
        return answer
    }

    /// Takes back a Playbook change, for `undo`; other changes are left to it.
    func undoPlaybook(_ change: ClaudeChange) throws {
        switch change {
        case .playbookAdded(let created):
            guard let current = try store.playbook().first(where: { $0.id == created.id }) else { throw Problem("That entry is gone already.") }
            guard ClaudeRules.canUndoNewEntry(current: current, created: created) else { throw Self.changedSince }
            try store.deletePlaybookEntry(created.id)
        case .playbookEdited(let before, let after):
            guard let current = try store.playbook().first(where: { $0.id == after.id }) else { throw Problem("That entry is gone.") }
            guard let restored = ClaudeRules.restoreEntry(current: current, before: before, after: after) else { throw Self.changedSince }
            try store.save(restored)
        case .sizesEdited(let before, let after):
            guard let restored = ClaudeRules.restore(current: try store.playbookSizes(), before: before, after: after) else { throw Self.changedSince }
            try store.save(restored)
        case .playbookDeleted(let deleted):
            guard ClaudeRules.canRestoreDeleted(deleted, among: try store.playbook()) else {
                throw Problem("\(deleted.area) has an entry called \(deleted.title) now, so it can't come back beside it.")
            }
            try store.save(ClaudeRules.restoringDeleted(deleted))
        default:
            return
        }
    }

    // MARK: - Changes

    private func addEntry(_ args: Arguments) throws -> [String: Any] {
        var entry = PlaybookEntry(area: try args.required("area"), kind: .pick, title: try args.required("title"))
        try apply(args, to: &entry)
        let entries = try store.playbook()
        try ClaudeRules.checkPlaybookEntry(entry, among: entries)
        try store.save(entry)
        let summary = "Added “\(entry.title)” to \(entry.area) in the Playbook"
        try log("add_playbook_entry", summary, .playbookAdded(entry))
        return ["added": summary, "entry": entry.id.uuidString]
    }

    private func editEntry(_ args: Arguments) throws -> [String: Any] {
        let entries = try store.playbook()
        let before = try findEntry(try args.required("entry"), in: entries)
        var after = before
        if let area = args.string("area") { after.area = area }
        if let title = args.string("title") { after.title = title }
        try apply(args, to: &after)
        guard after != before else { throw Problem("That's what \(before.title) already says; nothing to change.") }
        try ClaudeRules.checkPlaybookEntry(after, among: entries)
        try store.save(after)
        let summary = "Edited “\(before.title)” in the Playbook"
        try log("edit_playbook_entry", summary, .playbookEdited(before: before, after: after))
        return ["changed": summary, "entry": after.id.uuidString]
    }

    private func doneEntry(_ args: Arguments) throws -> [String: Any] {
        let entry = try findEntry(try args.required("entry"), in: try store.playbook())
        let day = try args.day("date") ?? today
        guard let done = try ClaudeRules.markDone(entry, on: day, today: today) else {
            return ["note": "\(entry.title) is already done on \(iso(day)); nothing changed."]
        }
        try store.save(done)
        let summary = "Marked “\(entry.title)” done on \(Self.longDay(day))"
        try log("done_playbook_entry", summary, .playbookEdited(before: entry, after: done))
        var answer: [String: Any] = ["done": summary, "entry": entry.id.uuidString]
        if let next = Playbook.nextDue(done, today: today) { answer["nextDue"] = iso(next) }
        return answer
    }

    private func setSize(_ args: Arguments) throws -> [String: Any] {
        let before = try store.playbookSizes()
        let after = try ClaudeRules.setSize(before, label: try args.required("label"), value: try args.required("value"))
        try store.save(after)
        let changed = after.rows.first { row in !before.rows.contains(row) }
        let summary = "Set the \(changed?.label ?? "size") size to \(changed?.value ?? "")"
        try log("set_size", summary, .sizesEdited(before: before, after: after))
        return ["changed": summary]
    }

    private func deleteEntry(_ args: Arguments) throws -> [String: Any] {
        let entry = try findEntry(try args.required("entry"), in: try store.playbook())
        try store.deletePlaybookEntry(entry.id)
        let summary = "Deleted “\(entry.title)” from \(entry.area) in the Playbook"
        try log("delete_playbook_entry", summary, .playbookDeleted(entry))
        return ["deleted": summary]
    }

    private func removeSize(_ args: Arguments) throws -> [String: Any] {
        let before = try store.playbookSizes()
        let label = try args.required("label")
        let after = try ClaudeRules.removeSize(before, label: label)
        try store.save(after)
        let removed = before.rows.first { !after.rows.contains($0) }
        let summary = "Removed the \(removed?.label ?? label) size"
        try log("remove_size", summary, .sizesEdited(before: before, after: after))
        return ["changed": summary]
    }

    // MARK: - Helpers

    private func entryRow(_ entry: PlaybookEntry) -> [String: Any] {
        var row: [String: Any] = ["id": entry.id.uuidString, "area": entry.area, "kind": entry.kind.rawValue, "title": entry.title]
        for (key, value) in [("detail", entry.detail), ("source", entry.source), ("size", entry.size), ("notes", entry.notes)] where !value.isEmpty {
            row[key] = value
        }
        if !entry.steps.isEmpty {
            row["steps"] = entry.steps.map { step -> [String: Any] in
                var line: [String: Any] = ["text": step.text]
                if !step.weekdays.isEmpty { line["days"] = Week.sorted(step.weekdays).map { Self.weekdayNames[$0] } }
                return line
            }
        }
        if let every = entry.repeatEveryDays {
            row["repeatEveryDays"] = every
            if let last = entry.lastDone { row["lastDone"] = iso(last) }
            if let next = Playbook.nextDue(entry, today: today) { row["nextDue"] = iso(next) }
            // They deleted its reminder; they can put it back from the Playbook screen.
            if entry.reminder == .off { row["onPhone"] = false }
        }
        return row
    }

    private static let weekdayNames = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    /// The fields every tool shares, onto `entry`; the rules check the result.
    private func apply(_ args: Arguments, to entry: inout PlaybookEntry) throws {
        if let kind = try args.choice("kind", in: PlaybookKind.allCases.map(\.rawValue)) {
            entry.kind = PlaybookKind(rawValue: kind)!
        } else if args.values["steps"] != nil {
            // Steps with no kind can only mean a routine.
            entry.kind = .routine
        }
        if let detail = args.string("detail") { entry.detail = detail }
        if let source = args.string("source") { entry.source = source }
        if let size = args.string("size") { entry.size = size }
        if let notes = args.string("notes") { entry.notes = notes }
        if let every = try args.int("repeat_every_days") { entry.repeatEveryDays = every == 0 ? nil : every }
        if let value = args.values["steps"] {
            guard let list = value as? [Any] else { throw Problem("steps must be a list of {text, days}.") }
            entry.steps = try list.map { item in
                guard let object = item as? [String: Any], let text = object["text"] as? String else {
                    throw Problem("Each step needs text, like {\"text\": \"Shampoo\", \"days\": [\"mon\", \"thu\"]}.")
                }
                let names = (object["days"] as? [String]) ?? []
                let days = try names.map { name -> Int in
                    guard let index = Self.weekdayNames.firstIndex(of: name.lowercased().prefix(3).description) else {
                        throw Problem("days are mon, tue, wed, thu, fri, sat or sun, not \(name).")
                    }
                    return index
                }
                return PlaybookStep(text: text, weekdays: Set(days))
            }
        }
    }

    private func findEntry(_ wanted: String, in entries: [PlaybookEntry]) throws -> PlaybookEntry {
        if let entry = entries.first(where: { $0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame }) { return entry }
        let named = entries.filter { $0.title.localizedCaseInsensitiveCompare(wanted) == .orderedSame }
        if named.count == 1 { return named[0] }
        throw Problem(
            named.count > 1
                ? "More than one entry is called \(wanted); use its id from playbook."
                : "No Playbook entry called \(wanted). Entries: \(entries.map(\.title).joined(separator: ", ")).")
    }
}
