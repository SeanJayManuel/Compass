import Core
import SwiftData
import SwiftUI

/// Their standing rules and the reasons behind them, kept for Claude, which
/// reads them at the start of planning chats and adds to them as they decide
/// things. Grouped by topic, newest first; they can add, edit or delete any.
struct NotesView: View {
    @Query private var records: [NoteRecord]
    @Environment(\.modelContext) private var context
    @Environment(Navigator.self) private var navigator
    @State private var topic: String?
    @State private var editing: Note?
    @State private var deleting: Note?

    var body: some View {
        let notes = records.compactMap(\.note)
        let groups = Notes.grouped(notes)
        // A filter on a topic that's gone (its last note deleted) is All.
        let topic = topic.flatMap { wanted in groups.contains { $0.topic == wanted } ? wanted : nil }
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if notes.isEmpty {
                    Text(
                        "Rules you've settled and the reasons behind them, kept for Claude: why you keep a cash buffer, what your career is aiming at. Claude reads these before planning with you and adds to them as you decide things. Figures stay in their own screens."
                    )
                    .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if groups.count > 1 {
                    // A menu once their topics no longer fit in a row.
                    ViewThatFits(in: .horizontal) {
                        topicPicker(groups.map(\.topic)).pickerStyle(.segmented).fixedSize()
                        topicPicker(groups.map(\.topic)).pickerStyle(.menu).fixedSize()
                    }
                }
                MasonryColumns(minimum: 360 * TextSize.current.scale, spacing: Spacing.m) {
                    ForEach(groups.filter { topic == nil || $0.topic == topic }, id: \.topic) { group in
                        TopicCard(topic: group.topic, notes: group.notes, edit: { editing = $0 }, delete: { deleting = $0 })
                    }
                }
            }
            .screenColumn()
        }
        .background(Palette.canvas)
        .perfMark("screen.notes")
        .onChange(of: navigator.newNoteRequest) { _, _ in
            editing = Note(topic: topic ?? Notes.topics[0], title: "", body: "", updatedAt: .now)
        }
        .sheet(item: $editing) { note in
            NoteEditor(note: note, notes: notes, isNew: !notes.contains { $0.id == note.id })
        }
        .confirmationDialog(
            "Delete \(deleting?.title ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { note in
            Button("Delete", role: .destructive) { try? CompassStore(context: context).deleteNote(note.id) }
        } message: { _ in
            Text("Claude won't see it any more. Backups made before now still have it.")
        }
    }

    private func topicPicker(_ topics: [String]) -> some View {
        Picker("Topic", selection: $topic) {
            Text("All").tag(String?.none)
            ForEach(topics, id: \.self) { Text($0).tag(String?.some($0)) }
        }
        .labelsHidden()
    }
}

private struct TopicCard: View {
    let topic: String
    let notes: [Note]
    let edit: (Note) -> Void
    let delete: (Note) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(topic).font(Typeface.section).foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, Spacing.xs)
            ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Button {
                        edit(note)
                    } label: {
                        HStack(alignment: .top, spacing: Spacing.s) {
                            RowMark(text: note.title)
                            NoteRow(note: note)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the editor")
                    RowActionsMenu(label: "Actions for \(note.title)") { actions(note) }
                }
                .padding(.vertical, Spacing.s)
                .overlay(alignment: .bottom) {
                    if index < notes.count - 1 { Rule() }
                }
                .contextMenu { actions(note) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Spacing.l)
    }

    @ViewBuilder private func actions(_ note: Note) -> some View {
        Button("Edit…") { edit(note) }
        Divider()
        Button("Delete…", role: .destructive) { delete(note) }
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    title.fixedSize()
                    Spacer(minLength: Spacing.s)
                    date.fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    title.fixedSize(horizontal: false, vertical: true)
                    date
                }
            }
            .font(Typeface.body)
            Text(note.body).font(Typeface.body).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var title: some View {
        Text(note.title).fontWeight(.semibold).foregroundStyle(Palette.ink)
    }

    private var date: some View {
        Text(note.updatedAt.formatted(.dateTime.month(.abbreviated).day().year()))
            .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
    }
}

/// Adds or edits a note, with the checks Claude's changes get.
private struct NoteEditor: View {
    let original: Note
    let notes: [Note]
    let isNew: Bool
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var note: Note
    @State private var addingTopic = false
    @State private var confirmingDelete = false

    init(note: Note, notes: [Note], isNew: Bool) {
        original = note
        self.notes = notes
        self.isNew = isNew
        _note = State(initialValue: note)
    }

    var body: some View {
        Form {
            TextField("Title", text: $note.title, prompt: Text("Cash buffer"))
            topicPicker
            TextField("Note", text: $note.body, prompt: Text("The rule, and why"), axis: .vertical)
                .lineLimit(4...12)
            HStack {
                // Why Save is off, once there's a title to judge.
                if !canSave, case .failure(let refusal) = result, !note.title.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(refusal.message).font(Typeface.detail).foregroundStyle(Palette.attention)
                }
                Spacer()
                Text("\(note.body.trimmingCharacters(in: .whitespacesAndNewlines).count) / \(ClaudeRules.longestNote)")
                    .font(Typeface.detail).monospacedDigit().foregroundStyle(Palette.inkSecondary)
            }
            if !isNew {
                Section {
                    Button("Delete \(original.title)", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .confirmationDialog("Delete \(original.title)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                try? CompassStore(context: context).deleteNote(original.id)
                dismiss()
            }
        } message: {
            Text("Claude won't see it any more. Backups made before now still have it.")
        }
        .formStyle(.grouped)
        .frame(width: 520 * TextSize.current.scale)
        .frame(minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") {
                    // Saving an untouched note leaves it, and its date, alone.
                    if case .success(let saved) = result, saved != original { try? CompassStore(context: context).save(saved) }
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }

    /// The note as it would be saved, through the rules Claude's changes use.
    private var result: Result<Note, ClaudeRefusal> {
        Result {
            if isNew {
                var created = try ClaudeRules.newNote(topic: note.topic, title: note.title, body: note.body, among: notes, now: .now)
                created.id = original.id
                return created
            }
            return try ClaudeRules.editNote(original, topic: note.topic, title: note.title, body: note.body, among: notes, now: .now)
        }.mapError { $0 as? ClaudeRefusal ?? ClaudeRefusal($0.localizedDescription) }
    }

    /// An edit that changes nothing is refused by the rules; here it's just a Save that does nothing.
    private var canSave: Bool {
        switch result {
        case .success: true
        case .failure: !isNew && (note.topic, note.title, note.body) == (original.topic, original.title, original.body)
        }
    }

    @ViewBuilder private var topicPicker: some View {
        if addingTopic {
            HStack {
                TextField("New topic", text: $note.topic, prompt: Text("Health"))
                Button("Choose from List") {
                    addingTopic = false
                    note.topic = Notes.topics[0]
                }
                .buttonStyle(.borderless)
            }
        } else {
            Picker(
                "Topic",
                selection: Binding(
                    get: { note.topic },
                    set: { if $0 == Self.newTopicTag { addingTopic = true; note.topic = "" } else { note.topic = $0 } }
                )
            ) {
                ForEach(topics, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("New Topic…").tag(Self.newTopicTag)
            }
        }
    }

    /// The known topics, then the others their notes use.
    private var topics: [String] {
        let inUse = Notes.grouped(notes + [note]).map(\.topic).filter { !$0.isEmpty }
        return Notes.topics + inUse.filter { !Notes.topics.contains($0) }
    }

    private static let newTopicTag = "\u{0}new"
}
