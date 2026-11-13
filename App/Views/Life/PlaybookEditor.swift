import Core
import SwiftData
import SwiftUI

/// Adds or edits a Playbook entry: a pick (what, where from, size), a
/// routine (steps, each on chosen weekdays or every day) or a note, any of
/// them repeating every so many days.
struct PlaybookEditor: View {
    let entries: [PlaybookEntry]
    let isNew: Bool
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var entry: PlaybookEntry
    /// As it was opened, to tell their changes from the reminder sync's.
    private let opened: PlaybookEntry
    @State private var newArea = ""
    @State private var addingArea = false
    @State private var confirmingDelete = false

    init(entry: PlaybookEntry, entries: [PlaybookEntry], isNew: Bool) {
        self.entries = entries
        self.isNew = isNew
        _entry = State(initialValue: entry)
        opened = entry
    }

    var body: some View {
        Form {
            Picker("Kind", selection: $entry.kind) {
                Text("Pick").tag(PlaybookKind.pick)
                Text("Routine").tag(PlaybookKind.routine)
                Text("Note").tag(PlaybookKind.note)
            }
            .pickerStyle(.segmented)
            TextField("Name", text: $entry.title, prompt: Text(prompt))
            areaPicker
            if entry.kind == .pick {
                TextField("What exactly", text: $entry.detail, prompt: Text("Uniqlo Supima Cotton crew, white"))
                TextField("Where from", text: $entry.source, prompt: Text("uniqlo.com"))
                TextField("Size", text: $entry.size, prompt: Text("M"))
            }
            if entry.kind == .routine { steps }
            TextField("Notes", text: $entry.notes, prompt: Text("Wash cold, hang dry"), axis: .vertical)
                .lineLimit(2...6)
            repeatSection
            // Why Add is off, once there's a name to judge.
            if let problem, !entry.title.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(problem).font(Typeface.detail).foregroundStyle(Palette.attention)
            }
            if !isNew {
                Section {
                    Button("Delete \(entry.title.isEmpty ? "Entry" : entry.title)", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .confirmationDialog("Delete \(entry.title)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                try? CompassStore(context: context).deletePlaybookEntry(entry.id)
                dismiss()
            }
        } message: {
            Text("It's removed from the Playbook. Backups made before now still have it.")
        }
        .formStyle(.grouped)
        .frame(width: 520 * TextSize.current.scale)
        .frame(minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") {
                    try? CompassStore(context: context).save(keepingSync(cleaned))
                    dismiss()
                }
                .disabled(problem != nil)
            }
        }
    }

    private var prompt: String {
        switch entry.kind {
        case .pick: "Plain tee"
        case .routine: "Shower, or Workout split"
        case .note: "What to tell the barber"
        }
    }

    @ViewBuilder private var areaPicker: some View {
        if addingArea {
            HStack {
                TextField("New area", text: $newArea, prompt: Text("Kitchen"))
                    .onChange(of: newArea) { entry.area = newArea.trimmingCharacters(in: .whitespaces) }
                Button("Choose from List") {
                    addingArea = false
                    newArea = ""
                    entry.area = PlaybookAreas.suggested[0]
                }
                .buttonStyle(.borderless)
            }
        } else {
            Picker(
                "Area",
                selection: Binding(
                    get: { entry.area },
                    set: { if $0 == Self.newAreaTag { addingArea = true; entry.area = "" } else { entry.area = $0 } }
                )
            ) {
                ForEach(PlaybookAreas.choices(entries + [entry]), id: \.self) { Text($0).tag($0) }
                Divider()
                Text("New Area…").tag(Self.newAreaTag)
            }
        }
    }

    private static let newAreaTag = "\u{0}new"

    @ViewBuilder private var steps: some View {
        Section {
            ForEach($entry.steps) { $step in
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack {
                        TextField("Step", text: $step.text, prompt: Text("Shampoo, scalp only"))
                            .labelsHidden()
                        Button {
                            move(step.id, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(entry.steps.first?.id == step.id)
                        .accessibilityLabel("Move step up")
                        Button {
                            move(step.id, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(entry.steps.last?.id == step.id)
                        .accessibilityLabel("Move step down")
                        Button {
                            entry.steps.removeAll { $0.id == step.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove step")
                    }
                    HStack(spacing: Spacing.xs) {
                        ForEach(Week.weekdays, id: \.self) { day in
                            Toggle(
                                String(PlaybookWords.weekdays[day].prefix(3)),
                                isOn: Binding(
                                    get: { step.weekdays.contains(day) },
                                    set: { on in if on { step.weekdays.insert(day) } else { step.weekdays.remove(day) } }
                                )
                            )
                            .toggleStyle(.button)
                            .accessibilityLabel(PlaybookWords.weekdays[day])
                        }
                        Text(step.weekdays.isEmpty ? "Every day" : "")
                            .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
            Button("Add Step") { entry.steps.append(PlaybookStep(text: "")) }
        } header: {
            Text("Steps")
        } footer: {
            Text("Leave the days off for a step done every time. Steps on chosen days show in Today.")
                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = entry.steps.firstIndex(where: { $0.id == id }), entry.steps.indices.contains(index + offset) else { return }
        entry.steps.swapAt(index, index + offset)
    }

    @ViewBuilder private var repeatSection: some View {
        Section {
            Toggle(
                "Repeats",
                isOn: Binding(
                    get: { entry.repeatEveryDays != nil },
                    set: { entry.repeatEveryDays = $0 ? (entry.repeatEveryDays ?? 14) : nil }
                ))
            if let every = entry.repeatEveryDays {
                Stepper(
                    "Every \(every) \(every == 1 ? "day" : "days")",
                    value: Binding(
                        get: { every }, set: { entry.repeatEveryDays = $0 }
                    ), in: 1...365)
                Toggle(
                    "Done before",
                    isOn: Binding(
                        get: { entry.lastDone != nil },
                        set: { entry.lastDone = $0 ? Day(.now, in: .current) : nil }
                    ))
                if let last = entry.lastDone {
                    DatePicker(
                        "Last done",
                        selection: Binding(
                            get: { last.startDate(in: .current) },
                            set: { entry.lastDone = min(Day($0, in: .current), Day(.now, in: .current)) }
                        ), in: ...Date.now, displayedComponents: .date)
                }
            }
        } footer: {
            Text("For things like nails or a haircut: it shows in Today when it's due.")
                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
        }
    }

    /// Trimmed, with empty steps dropped and fields a kind doesn't show cleared.
    private var cleaned: PlaybookEntry {
        var saved = entry
        saved.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.area = entry.area.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.notes = entry.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if saved.kind == .pick {
            saved.detail = entry.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            saved.source = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
            saved.size = entry.size.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            saved.detail = ""
            saved.source = ""
            saved.size = ""
        }
        saved.steps =
            saved.kind == .routine
            ? entry.steps.map {
                var step = $0; step.text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines); return step
            }
            .filter { !$0.text.isEmpty }
            : []
        return saved
    }

    /// A tick on their phone may have landed while it was open (seam 46): the
    /// saved entry keeps that done day, unless they changed it here, and
    /// whatever reminder it's linked to now.
    private func keepingSync(_ saved: PlaybookEntry) -> PlaybookEntry {
        guard let current = try? CompassStore(context: context).playbook().first(where: { $0.id == saved.id }) else { return saved }
        var kept = saved
        if saved.lastDone == opened.lastDone { kept.lastDone = current.lastDone }
        kept.reminder = current.reminder
        return kept
    }

    /// The same checks Claude's changes go through.
    private var problem: String? {
        do {
            try ClaudeRules.checkPlaybookEntry(cleaned, among: entries)
            return nil
        } catch let refusal as ClaudeRefusal {
            return refusal.message
        } catch {
            return error.localizedDescription
        }
    }
}

/// The sizes card's lines, and its note for brand exceptions.
struct SizesEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var sizes: PlaybookSizes

    init(sizes: PlaybookSizes) {
        var start = sizes
        if start.rows.isEmpty {
            start.rows = ["T-shirt", "Button-up", "Jeans", "Suit", "Shoes", "Socks"].map { PlaybookSize(label: $0, value: "") }
        }
        _sizes = State(initialValue: start)
    }

    var body: some View {
        Form {
            Section {
                ForEach($sizes.rows) { $row in
                    HStack {
                        TextField("What", text: $row.label, prompt: Text("Suit")).labelsHidden()
                        TextField("Size", text: $row.value, prompt: Text("38S")).labelsHidden()
                        Button {
                            sizes.rows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(row.label)")
                    }
                }
                .onMove { sizes.rows.move(fromOffsets: $0, toOffset: $1) }
                Button("Add Size") { sizes.rows.append(PlaybookSize(label: "", value: "")) }
            } header: {
                Text("My sizes")
            } footer: {
                Text("Lines with no size aren't kept.").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            TextField("Note", text: $sizes.note, prompt: Text("Everlane tees run small, take L"), axis: .vertical)
                .lineLimit(1...4)
        }
        .formStyle(.grouped)
        .frame(width: 460 * TextSize.current.scale)
        .frame(minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var saved = sizes
                    saved.rows = sizes.rows
                        .map {
                            PlaybookSize(id: $0.id, label: $0.label.trimmingCharacters(in: .whitespaces), value: $0.value.trimmingCharacters(in: .whitespaces))
                        }
                        .filter { !$0.label.isEmpty && !$0.value.isEmpty }
                    saved.note = sizes.note.trimmingCharacters(in: .whitespacesAndNewlines)
                    try? CompassStore(context: context).save(saved)
                    dismiss()
                }
            }
        }
    }
}
