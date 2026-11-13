import Core
import SwiftData
import SwiftUI

/// What works for them, so they don't have to figure it out twice. A list
/// and its details, as Goals (a page of every card at once was too
/// much): Today and My sizes first, then each
/// area's entries with what matters at a glance (size, how often, due,
/// restock); the chosen one's full details beside it, or opened from the
/// list in a narrow window. Search filters the list ("suit size", "shampoo").
struct PlaybookView: View {
    @Query(sort: \PlaybookEntryRecord.createdAt) private var records: [PlaybookEntryRecord]
    @Query private var sizeRecords: [PlaybookSizesRecord]
    @Environment(\.modelContext) private var context
    @Environment(Navigator.self) private var navigator
    @State private var query = ""
    @FocusState private var searching: Bool
    @State private var chosen: PlaybookItem?
    @State private var editing: PlaybookEntry?
    @State private var editingSizes = false
    @State private var deleting: PlaybookEntry?
    /// Each pick's purchases at its shop, read off the main thread.
    @State private var purchases: [UUID: PlaybookPurchases.Summary] = [:]

    private var today: Day { Day(.now, in: .current) }

    var body: some View {
        let entries = records.compactMap(\.entry)
        let sizes = sizeRecords.first?.sizes ?? PlaybookSizes()
        let shown = Playbook.search(entries, query)
        let hasToday = !Playbook.today(entries, today: today).isEmpty
        GeometryReader { geometry in
            let wide = geometry.size.width >= 940 * TextSize.current.scale
            // Wide, something is always open: what they chose, else Today, else sizes.
            let open =
                chosen.flatMap { item in item.isValid(in: entries) ? item : nil }
                ?? (wide ? (hasToday ? .today : .sizes) : nil)
            if wide {
                HStack(alignment: .top, spacing: Spacing.l) {
                    ScrollView {
                        list(entries: entries, shown: shown, sizes: sizes, hasToday: hasToday, open: open)
                            .padding(.vertical, Spacing.xl)
                    }
                    .frame(width: 312 * TextSize.current.scale)
                    ScrollView {
                        detail(open, entries: entries, sizes: sizes, back: false)
                            .padding(.vertical, Spacing.xl)
                    }
                    .id(open)
                }
                .screenColumn([])
            } else {
                ScrollView {
                    Group {
                        if open != nil {
                            detail(open, entries: entries, sizes: sizes, back: true)
                        } else {
                            list(entries: entries, shown: shown, sizes: sizes, hasToday: hasToday, open: nil)
                        }
                    }
                    .screenColumn()
                }
                .id(open)
            }
        }
        .background(Palette.canvas)
        .perfMark("screen.playbook")
        .task(id: entries.filter { PlaybookPurchases.shop($0) != nil }.map { "\($0.id)\($0.source)" }) {
            let picks = entries.filter { PlaybookPurchases.shop($0) != nil }
            guard !picks.isEmpty else { purchases = [:]; return }
            let kinds = (try? CompassStore(context: context).kinds()) ?? [:]
            purchases = await Self.readPurchases(from: context.container, picks: picks, kinds: kinds, today: today)
        }
        .onChange(of: navigator.newPlaybookRequest) { _, _ in
            let area = chosen.flatMap { item in entries.first { item == .entry($0.id) }?.area }
            editing = PlaybookEntry(area: area ?? PlaybookAreas.suggested[0], kind: .pick, title: "")
        }
        .sheet(item: $editing) { entry in
            PlaybookEditor(entry: entry, entries: entries, isNew: !entries.contains { $0.id == entry.id })
        }
        .sheet(isPresented: $editingSizes) { SizesEditor(sizes: sizes) }
        .confirmationDialog(
            "Delete \(deleting?.title ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { entry in
            Button("Delete", role: .destructive) {
                try? CompassStore(context: context).deletePlaybookEntry(entry.id)
                if chosen == .entry(entry.id) { chosen = nil }
            }
        } message: { _ in
            Text("It's removed from the Playbook. Backups made before now still have it.")
        }
    }

    // MARK: The list

    private func list(
        entries: [PlaybookEntry], shown: [PlaybookEntry], sizes: PlaybookSizes, hasToday: Bool,
        open: PlaybookItem?
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SearchField(text: $query, prompt: "Suit size, shampoo", focused: $searching)
            if entries.isEmpty, sizes.rows.isEmpty {
                Text("Keep what works for you here: the tee you rebuy and its size, your suit size, your shower routine, your workout split. Add one to start.")
                    .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !query.isEmpty, shown.isEmpty {
                Text("Nothing in the Playbook mentions “\(query)”.")
                    .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                if query.isEmpty {
                    if hasToday {
                        PlaybookListRow(
                            symbol: "sun.max", title: "Today", trailing: nil, alert: false,
                            selected: open == .today
                        ) { chosen = .today }
                    }
                    PlaybookListRow(
                        symbol: "ruler", title: "My sizes",
                        trailing: sizes.rows.isEmpty ? "Add" : "\(sizes.rows.count)", alert: false,
                        selected: open == .sizes
                    ) { chosen = .sizes }
                }
                ForEach(PlaybookAreas.inUse(shown), id: \.self) { area in
                    Text(area).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                        .padding(.horizontal, Spacing.s).padding(.top, Spacing.m).padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(shown.filter { $0.area == area }) { entry in
                        let status = Self.status(entry, purchase: purchases[entry.id], today: today)
                        PlaybookListRow(
                            symbol: PlaybookAreas.symbol(area), title: entry.title, trailing: status.text,
                            alert: status.alert, selected: open == .entry(entry.id)
                        ) { chosen = .entry(entry.id) }
                        .contextMenu { actions(entry) }
                    }
                }
            }
        }
    }

    /// What a row says at its end: due or overdue first, then a restock
    /// warning, then the size or how often it repeats.
    static func status(_ entry: PlaybookEntry, purchase: PlaybookPurchases.Summary?, today: Day) -> (text: String?, alert: Bool) {
        if let next = Playbook.nextDue(entry, today: today), next <= today {
            return (next < today ? "Overdue" : "Due today", true)
        }
        if purchase?.restockDue == true { return ("Restock", true) }
        if !entry.size.isEmpty { return (entry.size, false) }
        if let every = entry.repeatEveryDays { return (every == 1 ? "Daily" : "\(every) days", false) }
        return (nil, false)
    }

    // MARK: The details

    @ViewBuilder
    private func detail(_ item: PlaybookItem?, entries: [PlaybookEntry], sizes: PlaybookSizes, back: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if back {
                Button {
                    chosen = nil
                } label: {
                    Label("Playbook", systemImage: "chevron.left")
                }
                .linkButton().font(Typeface.body)
            }
            switch item {
            case .today:
                PlaybookTodayCard(entries: entries, today: today)
            case .sizes:
                SizesCard(sizes: sizes) { editingSizes = true }
            case .entry(let id):
                if let entry = entries.first(where: { $0.id == id }) {
                    EntryDetail(
                        entry: entry, today: today,
                        edit: { editing = entry }, done: { markDone(entry) }, putBack: { putBack(entry) },
                        delete: { deleting = entry })
                }
            case nil:
                EmptyView()
            }
        }
    }

    @ViewBuilder private func actions(_ entry: PlaybookEntry) -> some View {
        Button("Edit…") { editing = entry }
        if entry.repeatEveryDays != nil { Button("Done Today") { markDone(entry) } }
        if entry.repeatEveryDays != nil, entry.reminder == .off { Button("Put Back in Reminders") { putBack(entry) } }
        Divider()
        Button("Delete…", role: .destructive) { deleting = entry }
    }

    /// Every money-out transaction, on a context of its own, then each
    /// pick's purchases among them. Unfiled pairs matched as transfers aren't
    /// looked for: pairing all history is slow, and a shop's charge is
    /// almost never one.
    @concurrent
    nonisolated private static func readPurchases(
        from container: ModelContainer, picks: [PlaybookEntry], kinds: [String: CategoryKind],
        today: Day
    ) async -> [UUID: PlaybookPurchases.Summary] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<TransactionRecord>()
        descriptor.propertiesToFetch = [\.id, \.accountID, \.dayOrdinal, \.amount, \.merchant, \.statement, \.category]
        guard let records = try? context.fetch(descriptor), !Task.isCancelled else { return [:] }
        let spent = records.filter { $0.amount < 0 }.map { record in
            Core.Transaction(
                id: record.id, accountID: record.accountID, day: Day(ordinal: record.dayOrdinal), amount: record.amount,
                merchant: record.merchant, statement: record.statement, category: record.category, externalID: "")
        }
        // Keyed once, so each pick's shop is one pass, not a re-keying of all history.
        let index = TransactionIndex(spent)
        var found: [UUID: PlaybookPurchases.Summary] = [:]
        for pick in picks {
            guard let shop = PlaybookPurchases.shop(pick) else { continue }
            found[pick.id] = PlaybookPurchases.summary(pick, transactions: index.filter(TransactionQuery(text: shop)), kinds: kinds, today: today)
        }
        return found
    }

    private func markDone(_ entry: PlaybookEntry) {
        try? CompassStore(context: context).save(Playbook.markDone(entry, on: today))
    }

    /// Puts a repeat they'd deleted from Reminders back there; the sync makes it.
    private func putBack(_ entry: PlaybookEntry) {
        var back = entry
        back.reminder = nil
        try? CompassStore(context: context).save(back)
    }
}

/// The areas an entry can sit in: the ones they've used, in the order of the
/// suggestions, then their own.
enum PlaybookAreas {
    static let suggested = ["Clothes", "Hair", "Grooming", "Skin", "Teeth", "Fitness"]

    static func inUse(_ entries: [PlaybookEntry]) -> [String] {
        let used = Set(entries.map(\.area))
        return suggested.filter(used.contains) + used.subtracting(suggested).sorted()
    }

    static func choices(_ entries: [PlaybookEntry]) -> [String] {
        suggested + Set(entries.map(\.area)).subtracting(suggested).sorted()
    }

    /// The list's icon for an area; their own areas get a bookmark.
    static func symbol(_ area: String) -> String {
        switch area {
        case "Clothes": "tshirt"
        case "Hair": "scissors"
        case "Grooming": "sparkles"
        case "Skin": "drop"
        case "Teeth": "mouth"
        case "Fitness": "dumbbell"
        default: "bookmark"
        }
    }
}

/// How Playbook dates and weekdays read.
enum PlaybookWords {
    static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    /// "today", "tomorrow", "Monday" within the week, else "Nov 12".
    static func day(_ day: Day, today: Day) -> String {
        switch day.ordinal - today.ordinal {
        case 0: "today"
        case 1: "tomorrow"
        case 2...6: weekdays[Playbook.weekday(day)]
        default: day.startDate(in: .current).formatted(.dateTime.month(.abbreviated).day())
        }
    }

    /// "Legs next Monday", or just "Legs tomorrow".
    static func upNext(_ what: String, on day: Day, today: Day) -> String {
        let when = Self.day(day, today: today)
        return day.ordinal - today.ordinal == 1 ? "\(what) \(when)" : "\(what) next \(when)"
    }

    /// "Mon and Thu", or "Every day".
    static func weekdays(_ days: Set<Int>) -> String {
        guard !days.isEmpty, days.count < 7 else { return "Every day" }
        let names = Week.sorted(days).map { String(weekdays[$0].prefix(3)) }
        return names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// A step's first words, up to a colon or comma: "Shampoo", "Push".
    static func short(_ step: PlaybookStep) -> String {
        String(step.text.prefix { $0 != ":" && $0 != "," }).trimmingCharacters(in: .whitespaces)
    }

    /// "Next due Nov 12 · last done Oct 15", or "Overdue since Oct 15".
    static func due(_ entry: PlaybookEntry, today: Day) -> (text: String, overdue: Bool)? {
        guard let next = Playbook.nextDue(entry, today: today) else { return nil }
        guard let last = entry.lastDone else { return ("Not done yet", false) }
        let lastText = "last done " + day(last, today: today)
        if next < today { return ("Overdue since \(day(next, today: today)) · \(lastText)", true) }
        return ("Next due \(day(next, today: today)) · \(lastText)", false)
    }
}

/// Routines that change by weekday, and what's coming due in the next two
/// days, with Done (and Undo for a mistaken one). On the Playbook screen, and
/// on the Life overview with a link to it. Nothing when there's nothing today.
struct PlaybookTodayCard: View {
    let entries: [PlaybookEntry]
    let today: Day
    /// Opens the Playbook, from the Life overview.
    var open: (() -> Void)?
    @Environment(\.modelContext) private var context
    /// The entry as it was before its last Done.
    @State private var undone: PlaybookEntry?

    var body: some View {
        let line = Playbook.today(entries, today: today)
        if !line.isEmpty || undone != nil { card(line) }
    }

    private func card(_ line: Playbook.Today) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let open {
                GlanceHeader(title: "Today in the Playbook", link: "Playbook", action: open)
            } else {
                Text("Today").font(Typeface.section).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(line.routines, id: \.entry.id) { routine in
                routineLine(routine)
            }
            ForEach(line.due, id: \.entry.id) { due in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(due.entry.title).fontWeight(.semibold)
                    Text(due.day < today ? "overdue since \(PlaybookWords.day(due.day, today: today))" : "due \(PlaybookWords.day(due.day, today: today))")
                        .foregroundStyle(due.day < today ? Palette.attention : Palette.inkSecondary)
                    Spacer(minLength: Spacing.s)
                    Button("Done") { done(due.entry) }
                        .accessibilityLabel("Done today: \(due.entry.title)")
                }
                .font(Typeface.body).foregroundStyle(Palette.ink)
            }
            if let undone {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text("\(undone.title) marked done today.").foregroundStyle(Palette.inkSecondary)
                    Button("Undo", action: undo).linkButton()
                        .accessibilityLabel("Undo done: \(undone.title)")
                }
                .font(Typeface.detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Spacing.l)
    }

    private func done(_ entry: PlaybookEntry) {
        try? CompassStore(context: context).save(Playbook.markDone(entry, on: today))
        undone = entry
    }

    /// Puts back the last done day an accidental Done replaced; edits made since stay.
    private func undo() {
        defer { undone = nil }
        guard let before = undone, var current = entries.first(where: { $0.id == before.id }) else { return }
        current.lastDone = before.lastDone
        try? CompassStore(context: context).save(current)
    }

    private func routineLine(_ routine: Playbook.Today.Routine) -> some View {
        let steps = routine.day.steps.map(\.text).joined(separator: " · ")
        // Off today: the next session by name, else its step count ("7 steps tomorrow").
        let next =
            Playbook.nextSession(routine.entry, today: today).map { session in
                let when = PlaybookWords.day(session.day, today: today)
                return session.name.map { PlaybookWords.upNext($0, on: session.day, today: today) }
                    ?? "\(session.steps) \(session.steps == 1 ? "step" : "steps") \(when)"
            } ?? routine.day.next.first.map { PlaybookWords.upNext(PlaybookWords.short($0.step), on: $0.day, today: today) }
        return
            (Text("\(routine.entry.title): ").fontWeight(.semibold)
            + Text(steps.isEmpty ? "nothing today." : steps + ".")
            + Text(next.map { "  \($0)." } ?? "").foregroundStyle(Palette.inkSecondary))
            .font(Typeface.body).foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Every size they wear, three columns when there's room.
private struct SizesCard: View {
    let sizes: PlaybookSizes
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("My sizes").font(Typeface.section).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.s)
                Button(sizes.rows.isEmpty ? "Add sizes" : "Edit", action: edit).linkButton()
            }
            if sizes.rows.isEmpty {
                Text("Your shirt, jeans, suit and shoe sizes in one place.")
                    .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220 * TextSize.current.scale), spacing: Spacing.l)],
                    alignment: .leading, spacing: 0
                ) {
                    ForEach(sizes.rows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label).foregroundStyle(Palette.inkSecondary)
                            Spacer(minLength: Spacing.s)
                            Text(row.value).fontWeight(.semibold).foregroundStyle(Palette.ink).multilineTextAlignment(.trailing)
                        }
                        .font(Typeface.body)
                        .padding(.vertical, Spacing.s)
                        .overlay(alignment: .bottom) { Rule() }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if !sizes.note.isEmpty {
                Text(sizes.note).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Spacing.l)
    }
}

/// What the Playbook has open.
enum PlaybookItem: Hashable {
    case today, sizes, entry(UUID)

    func isValid(in entries: [PlaybookEntry]) -> Bool {
        if case .entry(let id) = self { return entries.contains { $0.id == id } }
        return true
    }
}

/// One line of the list: the area's icon, the name, and its status at the end.
private struct PlaybookListRow: View {
    let symbol: String
    let title: String
    let trailing: String?
    /// Due, overdue or time to restock: amber.
    let alert: Bool
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        let scale = TextSize.current.scale
        Button(action: choose) {
            HStack(spacing: Spacing.s) {
                Image(systemName: symbol)
                    .foregroundStyle(selected ? Palette.needle : Palette.inkSecondary)
                    .frame(width: 20 * scale)
                    .accessibilityHidden(true)
                Text(title).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer(minLength: Spacing.s)
                if let trailing {
                    Text(trailing).font(Typeface.detail).monospacedDigit()
                        .foregroundStyle(alert ? Palette.attention : Palette.inkSecondary)
                        .lineLimit(1)
                }
            }
            .font(Typeface.body)
            .padding(.horizontal, Spacing.s)
            .frame(minHeight: 34 * scale)
            .background(
                selected ? Palette.selection : hovering ? Palette.hover : .clear,
                in: .rect(cornerRadius: Radius.control)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(trailing.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One entry in full: everything its row in the old cards showed, with
/// Edit, Done for a repeat, and the rest in the ⋯ menu.
private struct EntryDetail: View {
    let entry: PlaybookEntry
    let today: Day
    let edit: () -> Void
    let done: () -> Void
    let putBack: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(entry.title).font(Typeface.heading).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                }
                Spacer(minLength: Spacing.s)
                RowActionsMenu(label: "Actions for \(entry.title)") {
                    Button("Edit…", action: edit)
                    if entry.repeatEveryDays != nil, entry.reminder == .off { Button("Put Back in Reminders", action: putBack) }
                    Divider()
                    Button("Delete…", role: .destructive, action: delete)
                }
            }
            EntryRow(entry: entry, today: today, showsTitle: false)
            HStack(spacing: Spacing.s) {
                Button("Edit", action: edit)
                if entry.repeatEveryDays != nil { Button("Done Today", action: done) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Spacing.l)
        .contextMenu {
            Button("Edit…", action: edit)
            if entry.repeatEveryDays != nil { Button("Done Today", action: done) }
            Divider()
            Button("Delete…", role: .destructive, action: delete)
        }
    }

    /// "Clothes · M", "Hair · every 28 days".
    private var subtitle: String {
        var parts = [entry.area]
        if !entry.size.isEmpty { parts.append(entry.size) }
        if let every = entry.repeatEveryDays { parts.append(every == 1 ? "every day" : "every \(every) days") }
        return parts.joined(separator: " · ")
    }
}

private struct EntryRow: View {
    let entry: PlaybookEntry
    let today: Day
    /// Off in the details, whose heading already names it.
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsTitle {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(entry.title).fontWeight(.semibold).foregroundStyle(Palette.ink)
                    Spacer(minLength: Spacing.s)
                    if let tag { Text(tag).foregroundStyle(Palette.inkSecondary) }
                }
                .font(Typeface.body)
            }
            let what = [entry.detail, entry.source].filter { !$0.isEmpty }.joined(separator: " · ")
            if !what.isEmpty { Text(what).font(Typeface.body).foregroundStyle(Palette.ink) }
            if !entry.steps.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(entry.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(Palette.inkSecondary)
                            (step.weekdays.isEmpty
                                ? Text(step.text)
                                : Text("\(PlaybookWords.weekdays(step.weekdays)): ").fontWeight(.semibold) + Text(step.text))
                                .foregroundStyle(Palette.ink)
                        }
                    }
                }
                .font(Typeface.body)
                .padding(.top, 2)
            }
            if let due = PlaybookWords.due(entry, today: today) {
                Text(due.text).font(Typeface.detail).foregroundStyle(due.overdue ? Palette.attention : Palette.inkSecondary)
            }
            if entry.repeatEveryDays != nil, entry.reminder == .off {
                Text("Not on your phone: deleted from Reminders").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
            if !entry.notes.isEmpty {
                Text(entry.notes).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The size, else how often it repeats.
    private var tag: String? {
        if !entry.size.isEmpty { return entry.size }
        if let every = entry.repeatEveryDays { return every == 1 ? "Every day" : "Every \(every) days" }
        return nil
    }
}
