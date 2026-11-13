import AppKit
import Core
import SwiftUI

/// One goal's page: where it stands, its history against the target, the
/// figures behind its pace, its chain of earlier goals, and its reward.
/// Shown beside the list, or as its own page in narrow windows.
struct GoalDetailView: View {
    let goal: Goal
    let progress: GoalProgress?
    let goals: [Goal]
    let accountNames: [UUID: String]
    let photo: Data?
    let today: Day
    var showsBackButton = true
    let back: () -> Void
    let edit: () -> Void
    let retire: () -> Void
    let claim: () -> Void
    let addPhoto: () -> Void

    @Environment(NetWorthCache.self) private var cache
    @Environment(\.modelContext) private var context
    @Environment(\.rowDensity) private var density
    @AppStorage("goals.detail.range") private var storedRange = TimeRange.oneYear
    /// nil while it loads.
    @State private var series: [DailyTotal]?
    /// What the goal paid for (seam 44), newest first, and what's still to move.
    @State private var paidFor: [Core.Transaction] = []
    @State private var toMove: Decimal = 0

    /// The ranges the page offers. A goal that was reached long ago only
    /// offers ranges long enough to include the day it was reached.
    private var ranges: [TimeRange] {
        let all: [TimeRange] = [.oneYear, .fiveYears, .all]
        guard case .achieved(let day, _) = goal.status else { return all }
        return all.filter { range in range.start(endingOn: today).map { $0 <= day } ?? true }
    }

    private var range: TimeRange { ranges.contains(storedRange) ? storedRange : ranges.first ?? .all }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if showsBackButton { backButton }
            if let progress {
                let reading = GoalReading(goal: goal, progress: progress, today: today)
                VStack(alignment: .leading, spacing: Spacing.m) {
                    header(reading)
                    figure(reading)
                }
                .card(padding: Spacing.l)
                chartCard(progress)
                figuresCard(reading)
                paidForCard
                stepsCard
                rewardCard
            } else {
                header(nil)
                HStack(spacing: Spacing.m) {
                    ProgressView().controlSize(TextSize.current.scale > 1 ? .regular : .small)
                    Text("Working out progress for \(goal.name)…").font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                }
                rewardCard
            }
        }
        // What the goal measures can change under the page (an edit, a refresh), so reload with it.
        .task(id: SeriesKey(goal: goal, latest: cache.breakdown.last?.total, days: cache.breakdown.count)) {
            series = await cache.series(for: goal)
            let ledger = (try? CompassStore(context: context).goalLedger()) ?? GoalFunding.Ledger()
            paidFor = ledger.paid(by: goal.id).reversed()
            toMove = ledger.toMove(goal.id, on: today)
        }
    }

    private struct SeriesKey: Hashable {
        let goal: Goal
        let latest: Decimal?
        let days: Int
    }

    // MARK: Header

    private var backButton: some View {
        HStack {
            Button(action: back) { Label("Goals", systemImage: "chevron.left") }
                .linkButton()
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to Goals (⌘[)")
            // Esc goes back too, whatever has focus.
            Button("Back", action: back)
                .keyboardShortcut(.cancelAction)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }

    private func header(_ reading: GoalReading?) -> some View {
        let status = reading.map { StatusLabel(text: $0.status.text, symbol: $0.status.symbol, tone: $0.status.tone) }
        let menu = RowActionsMenu(label: "Actions for \(goal.name)") {
            Button("Edit Goal…", action: edit)
            if goal.status == .active { Button("Retire Goal…", action: retire) }
        }
        return Group {
            if density == .regular {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    titleBlock(reading)
                    Spacer(minLength: Spacing.m)
                    if let status { status }
                    menu
                }
            } else {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(alignment: .firstTextBaseline) {
                        if let status { status }
                        Spacer()
                        menu
                    }
                    titleBlock(reading)
                }
            }
        }
    }

    private func titleBlock(_ reading: GoalReading?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(goal.name).font(Typeface.title).foregroundStyle(Palette.ink)
            if let reading {
                let caption = Text(reading.measure(accountNames: accountNames))
                    .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                if reading.isFIRE { caption.privateAmount() } else { caption }
            }
            if !goal.note.isEmpty {
                Text(goal.note).font(Typeface.body).italic().foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    // MARK: The figure

    private func figure(_ reading: GoalReading) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(reading.figure.wholeDollars)
                .font(Typeface.figure).monospacedDigit().foregroundStyle(Palette.ink).privateAmount()
            Text(reading.toGoLine)
                .font(Typeface.body).monospacedDigit().foregroundStyle(Palette.inkSecondary).privateAmount()
        }
        .padding(.vertical, Spacing.xs)
    }

    // MARK: History

    private func chartCard(_ progress: GoalProgress) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Text("History").font(Typeface.section).foregroundStyle(Palette.ink)
                Spacer()
                HStack(spacing: Spacing.xs) {
                    ForEach(ranges, id: \.self) { option in
                        Button(option.rawValue) { withAnimation(Motion.change) { storedRange = option } }
                            .buttonStyle(RangeButtonStyle(selected: option == range))
                    }
                }
            }
            let drawn = series.map { NetWorthSeries.averaged(NetWorthSeries.trim($0, to: range, endingOn: today), toAtMost: 240) }
            Group {
                if let drawn {
                    if drawn.count > 1 {
                        GoalHistoryChart(series: drawn, goal: goal, progress: progress, today: today)
                    } else {
                        Text("There's no balance history for this goal yet.")
                            .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    Text("Loading…").font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 260 * TextSize.current.scale)
            // What the lines mean, on hover rather than as a paragraph under the chart.
            .help(drawn.flatMap { $0.count > 1 ? chartNote(progress, start: $0.first?.day) : nil } ?? "")
        }
        .card(padding: Spacing.l)
    }

    /// What the chart's lines mean, for the ones that carry no label of their own.
    private func chartNote(_ progress: GoalProgress, start: Day?) -> String? {
        var parts: [String] = []
        if !GoalReading(goal: goal, progress: progress, today: today).isReached, progress.projectionLine(today: today) != nil {
            parts.append("The dashed line carries your 3-month pace forward to the target.")
        }
        if let start, GoalHistoryChart.drawsTargetDate(goal: goal, progress: progress, today: today, start: start) {
            parts.append("The dotted vertical line marks the target date.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Figures

    private func figuresCard(_ reading: GoalReading) -> some View {
        let rows: [(String, String)] = [
            reading.needsSentence.map { ("Needs", $0) },
            reading.paceSentence.map { ("Pace", $0) },
            reading.getsThereSentence.map { ("Gets there", $0) },
            reading.spendingSentence.map { ("Annual spending", $0) }
        ].compactMap { $0 }
        return Group {
            // A goal that's reached has nothing left to need, pace or reach.
            if !rows.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.s) {
                    ForEach(rows, id: \.0) { label, value in
                        GridRow {
                            Text(label).font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                            Text(value).font(Typeface.body).monospacedDigit().foregroundStyle(Palette.ink).privateAmount()
                                .gridColumnAlignment(.leading)
                        }
                    }
                }
                .card(padding: Spacing.l)
            }
        }
    }

    // MARK: Paid for

    private var fundAccounts: [String] {
        guard case .accountTotal(let ids) = goal.kind else { return [] }
        return ids.compactMap { accountNames[$0] }.sorted()
    }

    /// Spending the goal paid for, out of the budget, and what's still to
    /// move out of its accounts (progress already leaves that out).
    @ViewBuilder
    private var paidForCard: some View {
        if !paidFor.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Paid for").font(Typeface.section).foregroundStyle(Palette.ink)
                if toMove > 0 {
                    let from = fundAccounts.isEmpty ? "the goal's account" : fundAccounts.joined(separator: " or ")
                    Text("\(toMove.dollars) still to move out of \(from) to cover it. Progress already leaves it out.")
                        .font(Typeface.detail).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
                        .privateAmount()
                }
                ForEach(paidFor.prefix(8)) { charge in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                        Text(charge.day.startDate(in: .current).formatted(.dateTime.month(.abbreviated).day()))
                            .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                            .frame(width: 56 * TextSize.current.scale, alignment: .leading)
                        Text(charge.merchant).font(Typeface.body).foregroundStyle(Palette.ink).lineLimit(1)
                        Spacer(minLength: Spacing.m)
                        Text(charge.paidByGoal.dollars).font(Typeface.body).monospacedDigit().foregroundStyle(Palette.ink).privateAmount()
                    }
                }
                if paidFor.count > 8 {
                    Text("And \(paidFor.count - 8) more").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                }
            }
            .card(padding: Spacing.l)
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepsCard: some View {
        let chain = GoalLifecycle.chain(endingWith: goal, in: goals)
        if chain.count > 1 {
            let events = Dictionary(
                uniqueKeysWithValues: GoalLifecycle.milestones(in: goals)
                    .filter { $0.kind == .reached }.map { ($0.goal.id, $0) })
            VStack(alignment: .leading, spacing: 0) {
                Text("Steps").font(Typeface.section).foregroundStyle(Palette.ink).padding(.bottom, Spacing.xs)
                ForEach(chain) { step in
                    if let event = events[step.id] {
                        MilestoneRow(event: event)
                    } else {
                        pendingStep(step)
                    }
                }
            }
            .card(padding: Spacing.l)
        }
    }

    /// A step in the chain that hasn't been reached yet: this goal, or one retired along the way.
    private func pendingStep(_ step: Goal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.l) {
            Text(step.id == goal.id ? "Working on it" : "—")
                .font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
                .frame(width: 96 * TextSize.current.scale, alignment: .leading)
            Circle().strokeBorder(Palette.inkSecondary, lineWidth: 1.5).frame(width: 8, height: 8)
            Text(step.name).font(Typeface.body).foregroundStyle(Palette.ink)
        }
        .padding(.vertical, Spacing.s + Spacing.xs)
    }

    // MARK: Reward

    @ViewBuilder
    private var rewardCard: some View {
        if let reward = goal.reward {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Reward").font(Typeface.section).foregroundStyle(Palette.ink)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(reward.name).font(Typeface.body).foregroundStyle(Palette.ink)
                    if let cost = reward.cost {
                        Text(cost.wholeDollars).font(Typeface.body).monospacedDigit().foregroundStyle(Palette.inkSecondary).privateAmount()
                    }
                }
                rewardState(reward)
            }
            .card(padding: Spacing.l)
        }
    }

    @ViewBuilder
    private func rewardState(_ reward: Reward) -> some View {
        let isAchieved: Bool = { if case .achieved = goal.status { true } else { false } }()
        if let claimed = reward.claimedOn {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.s) {
                    StatusLabel(
                        text: "Claimed \(claimed.startDate(in: .current).formatted(date: .abbreviated, time: .omitted))",
                        symbol: "checkmark", tone: .good)
                    Button(photo == nil ? "Add Photo" : "Change Photo", action: addPhoto)
                        .linkButton().font(Typeface.detail)
                }
                if let photo, let image = NSImage(data: photo) {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: 160 * TextSize.current.scale, height: 110 * TextSize.current.scale).clipShape(.rect(cornerRadius: 8))
                        .accessibilityLabel("Photo of \(reward.name)")
                }
            }
        } else if isAchieved {
            HStack(spacing: Spacing.s) {
                Text("Unlocked").font(Typeface.detail).foregroundStyle(Palette.ink)
                Button("Mark Claimed", action: claim).linkButton().font(Typeface.detail)
            }
        } else {
            Text("Unlocks when you reach the goal.").font(Typeface.detail).foregroundStyle(Palette.inkSecondary)
        }
    }
}
