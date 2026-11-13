import AppKit
import Core
import SwiftData
import SwiftUI

/// Am I on pace? A compact list of the goals still being worked on, and a page
/// for each one's story.
struct GoalsView: View {
    @Environment(\.modelContext) private var context
    @Environment(NetWorthCache.self) private var cache
    @Environment(Navigator.self) private var navigator
    @Query(sort: \GoalRecord.createdAt) private var goalRecords: [GoalRecord]
    @Query(sort: \AccountRecord.createdAt) private var accountRecords: [AccountRecord]
    @State private var editing: Goal?
    @State private var retiring: Goal?
    @State private var photoFor: UUID?
    @State private var error: String?
    /// The goal whose page is open, or nil for the list.
    @State private var selected: UUID?
    /// Goals reached since the last visit stay in the list for this visit, so
    /// the moment isn't lost. Only ever added to: the goals reached and not yet
    /// celebrated when the screen appears, and any goal reached while it is
    /// open (`pendingCelebrations`). The list shows these rows and nothing
    /// else, never `celebrated` read live: the celebration saves that flag the
    /// moment it starts, and a live filter would drop the row mid-animation.
    /// Because the set is built with `formUnion`, it doesn't matter whether
    /// this screen's `onAppear` or a row's runs first; a row's own insert
    /// (see `celebrated`) is never overwritten.
    @State private var keptForVisit: Set<UUID> = []
    @State private var retiredOpen = false
    #if DEBUG
        @State private var openedDebugGoal = false
    #endif

    var body: some View {
        let goals = goalRecords.map(\.goal)
        GeometryReader { geometry in
            let wide = geometry.size.width >= 940 * TextSize.current.scale
            let openGoal =
                goals.first { $0.id == selected }
                ?? (wide ? listEntries(goals: goals).first?.goal : nil)
            if wide {
                HStack(alignment: .top, spacing: Spacing.l) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.m) {
                            list(goals: goals, selectedID: openGoal?.id, inRail: true)
                        }
                        .padding(.vertical, Spacing.xl)
                    }
                    .frame(width: 312 * TextSize.current.scale)
                    .environment(\.rowDensity, .compact)
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.m) {
                            if let openGoal {
                                detail(of: openGoal, goals: goals, showsBackButton: false).id(openGoal.id)
                            } else {
                                Text("Choose a goal to see its history, pace and reward, or add a new one.")
                                    .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).card(padding: Spacing.l)
                            }
                        }
                        .padding(.vertical, Spacing.xl)
                    }
                    .environment(\.rowDensity, .compact)
                    .id(openGoal?.id)
                }
                .screenColumn([])
                .onChange(of: openGoal?.id, initial: true) { _, id in
                    // Keep the initial choice stable if attention order changes after a sync.
                    if selected == nil { selected = id }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        if let openGoal { detail(of: openGoal, goals: goals).id(openGoal.id) } else { list(goals: goals, selectedID: nil) }
                    }
                    .screenColumn()
                }
                .id(openGoal?.id)
            }
        }
        .background(Palette.canvas)
        .sheet(item: $editing) { GoalEditor(goal: $0, accounts: accountRecords.map(\.account)) }
        .sheet(item: $retiring) { RetireSheet(goal: $0) }
        .fileImporter(
            isPresented: Binding(get: { photoFor != nil }, set: { if !$0 { photoFor = nil } }),
            allowedContentTypes: [.image]
        ) { result in
            if let id = photoFor, let url = try? result.get() { attachPhoto(url, to: id) }
            photoFor = nil
        }
        .onAppear {
            keptForVisit.formUnion(pendingCelebrations)
            // A goal row on the money overview opens that goal's page.
            if let id = navigator.goalToOpen {
                selected = id
                navigator.goalToOpen = nil
            }
            openDebugGoalIfRequested()
        }
        // A goal reached while the screen is open (a sync lands) is kept too, so
        // its row appears and plays the celebration. Adds only, never removes:
        // the celebration clears the flag as it starts.
        .onChange(of: navigator.newGoalRequest) { _, _ in
            editing = Goal(name: "", kind: .netWorth, target: 0)
        }
        .onChange(of: navigator.goalToOpen) { _, id in
            if let id { selected = id; navigator.goalToOpen = nil }
        }
        .onChange(of: pendingCelebrations) { _, pending in keptForVisit.formUnion(pending) }
        .onChange(of: goalRecords.count) { _, _ in openDebugGoalIfRequested() }
        // Retiring a goal from its own page returns to the list: the page has no
        // retired state to show, and the goal can't be opened from the list again.
        .onChange(of: selectedGoalIsRetired) { _, retired in if retired { selected = nil } }
    }

    private var selectedGoalIsRetired: Bool {
        goalRecords.first { $0.id == selected }?.statusRaw == "retired"
    }

    // MARK: The list

    @ViewBuilder
    private func list(goals: [Goal], selectedID: UUID?, inRail: Bool = false) -> some View {
        let drafts = goalRecords.filter { record in
            record.statusRaw == "achieved" && !record.successorDismissed
                && !goals.contains { $0.predecessorID == record.id }
        }
        let entries = listEntries(goals: goals)

        if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.failure) }

        ForEach(drafts) { record in
            SuccessorDraft(
                predecessor: record.goal,
                accept: { accept(GoalLifecycle.successor(of: record.goal)) },
                edit: { editing = GoalLifecycle.successor(of: record.goal) },
                dismiss: {
                    record.successorDismissed = true
                    SaveFailures.shared.attempt { try context.save() }
                })
        }

        if entries.isEmpty && drafts.isEmpty {
            Text("Set a goal for net worth, a group of accounts, or financial independence, and Compass tracks your pace toward it.")
                .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
        }

        if !entries.isEmpty {
            GoalList(
                entries: entries,
                accountNames: Dictionary(accountRecords.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
                today: cache.today,
                selectedID: selectedID,
                open: { selected = $0 },
                edit: { editing = $0 },
                retire: { retiring = $0 },
                celebrated: { id in
                    keptForVisit.insert(id)
                    goalRecords.first { $0.id == id }?.celebrated = true
                    SaveFailures.shared.attempt { try context.save() }
                }
            )
        }

        let reached = GoalLifecycle.milestones(in: goals)
        if !reached.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Reached").font(Typeface.section).foregroundStyle(Palette.ink).padding(.bottom, Spacing.xs)
                ForEach(reached.sorted { $0.day > $1.day }, id: \.id) { event in
                    MilestoneRow(
                        event: event,
                        photo: goalRecords.first { $0.id == event.goal.id }?.rewardPhoto,
                        compact: inRail,
                        action: { selected = event.goal.id },
                        onClaim: { claim(event.goal) },
                        onPhoto: { photoFor = event.goal.id })
                }
            }
            .card(padding: Spacing.l)
            .padding(.top, Spacing.m)
        }

        let retired = goals.filter { if case .retired = $0.status { true } else { false } }
        if !retired.isEmpty {
            DisclosureGroup(isExpanded: $retiredOpen) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(retired) { goal in
                        if case .retired(let reason) = goal.status {
                            Text("\(goal.name): \(reason)").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Spacing.s)
            } label: {
                Text("Retired (\(retired.count))").font(Typeface.section).foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    /// Goals reached whose celebration hasn't played yet.
    private var pendingCelebrations: Set<UUID> {
        Set(goalRecords.filter { $0.statusRaw == "achieved" && !$0.celebrated }.map(\.id))
    }

    /// Active goals in the order they need attention, then the goals reached
    /// since the last visit. Which achieved goals those are comes from
    /// `keptForVisit` alone; `celebrate` (whether the bar still has to play its
    /// once-only fill) is the only live read of `celebrated`, and a row reads it
    /// once, as it appears.
    private func listEntries(goals: [Goal]) -> [GoalListEntry] {
        let active = GoalAttention.order(goals, progress: cache.goalProgress)
        let kept = goals.filter { goal in
            if case .achieved = goal.status { return keptForVisit.contains(goal.id) }
            return false
        }
        return (active + kept).map { goal in
            let record = goalRecords.first { $0.id == goal.id }
            return GoalListEntry(
                goal: goal, progress: cache.goalProgress[goal.id],
                celebrate: record.map { $0.statusRaw == "achieved" && !$0.celebrated } ?? false)
        }
    }

    // MARK: A goal's page

    private func detail(of goal: Goal, goals: [Goal], showsBackButton: Bool = true) -> some View {
        GoalDetailView(
            goal: goal,
            progress: cache.goalProgress[goal.id],
            goals: goals,
            accountNames: Dictionary(accountRecords.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            photo: goalRecords.first { $0.id == goal.id }?.rewardPhoto,
            today: cache.today,
            showsBackButton: showsBackButton,
            back: { selected = nil },
            edit: { editing = goal },
            retire: { retiring = goal },
            claim: { claim(goal) },
            addPhoto: { photoFor = goal.id }
        )
    }

    // MARK: Actions

    private func accept(_ draft: Goal) {
        do { try CompassStore(context: context).save(draft) } catch { self.error = error.localizedDescription }
    }

    private func attachPhoto(_ url: URL, to goalID: UUID) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: url), let data = RewardPhoto.jpeg(from: image),
            let record = goalRecords.first(where: { $0.id == goalID })
        else { error = "That file couldn't be read as a photo."; return }
        record.rewardPhoto = data
        SaveFailures.shared.attempt { try context.save() }
    }

    private func claim(_ goal: Goal) {
        var claimed = goal
        claimed.reward?.claimedOn = Day(.now, in: .current)
        accept(claimed)
    }

    /// Debug builds only: `--open-goal "<name>"` opens that goal's page, so a
    /// snapshot can render it.
    private func openDebugGoalIfRequested() {
        #if DEBUG
            guard !openedDebugGoal, let name = DebugSupport.openGoalName,
                let record = goalRecords.first(where: { $0.name == name })
            else { return }
            openedDebugGoal = true
            selected = record.id
        #endif
    }
}

private struct SuccessorDraft: View {
    let predecessor: Goal
    let accept: () -> Void
    let edit: () -> Void
    let dismiss: () -> Void
    @Environment(\.rowDensity) private var density

    var body: some View {
        let next = GoalLifecycle.successor(of: predecessor)
        let text = VStack(alignment: .leading, spacing: 2) {
            Text("You reached \(predecessor.name). Next: \(next.name)?")
                .font(Typeface.body).foregroundStyle(Palette.ink)
            Text("A suggestion only. Nothing is created until you add it.")
                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
        }
        let buttons = ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.m) {
                Button("Dismiss", action: dismiss).linkButton()
                Button("Edit", action: edit)
                Button("Add \(next.name)", action: accept).buttonStyle(.borderedProminent)
            }
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.m) {
                    Button("Dismiss", action: dismiss).linkButton()
                    Button("Edit", action: edit)
                }
                Button("Add \(next.name)", action: accept).buttonStyle(.borderedProminent)
            }
        }
        Group {
            if density == .regular {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    text
                    Spacer()
                    buttons
                }
            } else {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    text
                    buttons
                }
            }
        }
        .banner()
    }
}

struct RetireSheet: View {
    let goal: Goal
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""

    var body: some View {
        Form {
            Text("Retiring keeps \(goal.name) in your history, greyed out, with the reason you give.")
                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
            TextField("Reason", text: $reason)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Retire Goal") {
                    try? CompassStore(context: context).save(GoalLifecycle.retire(goal, reason: reason))
                    dismiss()
                }
                .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

enum RewardPhoto {
    /// A JPEG no larger than 1024 px on its longest side.
    static func jpeg(from image: NSImage, longestSide: CGFloat = 1024) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, longestSide / CGFloat(max(source.width, source.height)))
        let width = Int(CGFloat(source.width) * scale), height = Int(CGFloat(source.height) * scale)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
